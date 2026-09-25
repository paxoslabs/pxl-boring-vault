// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";

import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {
    CowSwapHelperDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/CowSwapHelperDecoderAndSanitizer.sol";
import { CowSwapHelper } from "src/helper/cow-swap/CowSwapHelper.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { IGPv2Settlement } from "src/interfaces/IGPv2Settlement.sol";

import { CowSwapHelperTestBase, FixedRateProvider } from "test/helper/cow-swap/CowSwapHelperTestBase.sol";

/// @notice Minimal mintable ERC20 with configurable decimals.
contract MockERC20 is ERC20 {

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s, d) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

}

/// @notice Stand-in for CoW's settlement: records pre-signatures and enforces the owner-is-caller rule the
///         helper relies on, and exposes the two immutables the helper caches at deploy.
contract MockSettlement is IGPv2Settlement {

    address public immutable vaultRelayer;
    bytes32 public immutable domainSeparator;

    mapping(bytes => bool) public isSigned;

    constructor(address _vaultRelayer, bytes32 _domainSeparator) {
        vaultRelayer = _vaultRelayer;
        domainSeparator = _domainSeparator;
    }

    function setPreSignature(bytes calldata orderUid, bool signed) external {
        // Mirrors GPv2Signing: the owner packed into the UID must be the caller. This is the invariant that
        // forces the helper (not the vault) to be the order owner.
        require(orderUid.length == 56, "MockSettlement: bad uid length");
        address uidOwner = address(bytes20(orderUid[32:52]));
        require(uidOwner == msg.sender, "GPv2: caller does not own order");
        isSigned[orderUid] = signed;
    }

}

/// @notice Concrete decoder exposing only the CowSwap surface for this test.
contract CowSwapTestDecoderAndSanitizer is CowSwapHelperDecoderAndSanitizer {

    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

}

/// @notice Integration tests exercising the full strategist path - ManagerWithMerkleVerification -> BoringVault
///         -> CowSwapHelper -> settlement - against the current helper, which owns each order itself and holds
///         the sell-token collateral in its own balance (returned to the vault via `sweepToken`).
/// @dev The settlement, rate provider, and tokens are mocked so the suite runs without a mainnet fork; the
///      vault, manager, decoder, roles authority, and merkle verification are all the real contracts. The roles
///      wiring, merkle tree construction, and order-UID reconstruction live in CowSwapHelperTestBase.
contract CowSwapHelperIntegrationTest is CowSwapHelperTestBase {

    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("test-domain-separator");

    MockSettlement internal settlement;
    MockERC20 internal sellToken; // 18 decimals
    MockERC20 internal buyToken; // 6 decimals

    address internal relayer = makeAddr("relayer");

    function setUp() external {
        settlement = new MockSettlement(relayer, DOMAIN_SEPARATOR);
        rateProvider = new FixedRateProvider(RATE_18);
        sellToken = new MockERC20("Sell", "SELL", 18);
        buyToken = new MockERC20("Buy", "BUY", 6);

        boringVault = new BoringVault(address(this), "Boring Vault", "BV", 18);
        manager = new ManagerWithMerkleVerification(address(this), address(boringVault), address(0));
        decoder = new CowSwapTestDecoderAndSanitizer(address(boringVault));
        helper = new CowSwapHelper(address(this), address(boringVault), address(settlement), MAX_ORDER_VALIDITY);

        _wireRolesAuthority();
        _buildAndSetRoot(false);
    }

    function _sellToken() internal view override returns (address) {
        return address(sellToken);
    }

    function _buyToken() internal view override returns (address) {
        return address(buyToken);
    }

    function _settlement() internal view override returns (address) {
        return address(settlement);
    }

    // ------------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------------

    /// @dev Approve + placeOrder in one merkle-verified batch, then check the settlement pre-signed the UID and
    ///      the sell token moved from the vault into the helper (which custodies it, not a proxy).
    function test_placeOrder_presignsThroughMerklePath() external {
        sellToken.mint(address(boringVault), SELL_AMOUNT);

        CowSwapHelper.OrderParams memory p = _params(BUY_AMOUNT, false);
        bytes memory uid = _expectedUid(p);
        _approveAndPlace(p);

        assertTrue(settlement.isSigned(uid), "order pre-signed on settlement");
        assertEq(sellToken.balanceOf(address(helper)), SELL_AMOUNT, "helper custodies the sell token");
        assertEq(sellToken.balanceOf(address(boringVault)), 0, "vault moved the sell token out");
        assertEq(
            sellToken.allowance(address(helper), relayer), type(uint256).max, "relayer approved to pull from the helper"
        );
        assertEq(sellToken.allowance(address(boringVault), address(helper)), 0, "no dangling vault allowance");
    }

    /// @dev A cancel batch clears the settlement pre-signature; a following sweepToken batch returns the unfilled
    ///      collateral from the helper to the vault (the helper keeps no fill accounting, so the sweep is separate).
    function test_cancelOrder_thenSweep_returnsFundsToVault() external {
        sellToken.mint(address(boringVault), SELL_AMOUNT);
        CowSwapHelper.OrderParams memory p = _params(BUY_AMOUNT, false);
        bytes memory uid = _expectedUid(p);
        _approveAndPlace(p);
        assertTrue(settlement.isSigned(uid), "precondition: signed");

        _manageSingle(cancelLeaf, address(helper), abi.encodeWithSelector(CowSwapHelper.cancelOrder.selector, uid));
        assertFalse(settlement.isSigned(uid), "pre-signature cleared");
        assertEq(sellToken.balanceOf(address(helper)), SELL_AMOUNT, "collateral still with helper until swept");

        _manageSingle(
            sweepLeaf,
            address(helper),
            abi.encodeWithSelector(CowSwapHelper.sweepToken.selector, address(sellToken), SELL_AMOUNT)
        );
        assertEq(sellToken.balanceOf(address(helper)), 0, "helper swept");
        assertEq(sellToken.balanceOf(address(boringVault)), SELL_AMOUNT, "vault made whole on sweep");
    }

    /// @dev partiallyFillable = true is honored end-to-end: the resulting (distinct) UID is pre-signed.
    function test_placeOrder_partiallyFillable_presigns() external {
        sellToken.mint(address(boringVault), SELL_AMOUNT);
        CowSwapHelper.OrderParams memory p = _params(BUY_AMOUNT, true);
        bytes memory uid = _expectedUid(p);

        // Rebuild the tree with a partiallyFillable = true placeOrder leaf so it is authorized.
        _buildAndSetRoot(true);
        _approveAndPlace(p);

        assertTrue(settlement.isSigned(uid), "partial-fill order pre-signed");
    }

    /// @dev The merkle leaf pins the partial-fill flag: with the default root (partiallyFillable = false), a
    ///      placeOrder flipping the flag to true re-derives a different leaf and fails verification before ever
    ///      reaching the helper.
    function test_placeOrder_partiallyFillable_failsVerification() external {
        sellToken.mint(address(boringVault), SELL_AMOUNT);

        // Keep the default setUp root, which pins partiallyFillable = false, then submit a true order against it.
        CowSwapHelper.OrderParams memory p = _params(BUY_AMOUNT, true);
        bytes memory placeData = abi.encodeWithSelector(CowSwapHelper.placeOrder.selector, p);

        // Reuse the pinned (false) placeOrder proof; the true flag decodes to a different leaf that won't verify.
        (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        ) = _singleCall(placeLeaf, address(helper), placeData);

        vm.prank(strategist);
        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerWithMerkleVerification.ManagerWithMerkleVerification__FailedToVerifyManageProof.selector,
                address(helper),
                placeData,
                uint256(0)
            )
        );
        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
    }

    /// @dev The merkle leaf pins the rate provider: a placeOrder pointing at a different provider fails
    ///      verification before ever reaching the helper. This is the on-chain gate the helper relies on.
    function test_placeOrder_unpinnedRateProvider_failsVerification() external {
        sellToken.mint(address(boringVault), SELL_AMOUNT);
        FixedRateProvider rogueProvider = new FixedRateProvider(RATE_18);

        CowSwapHelper.OrderParams memory p = _params(BUY_AMOUNT, false);
        p.rateProvider = IRateProvider(address(rogueProvider)); // not the pinned provider

        bytes memory placeData = abi.encodeWithSelector(CowSwapHelper.placeOrder.selector, p);

        // Reuse the placeOrder proof; it will not verify against the rogue provider's decoded address.
        (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        ) = _singleCall(placeLeaf, address(helper), placeData);

        vm.prank(strategist);
        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerWithMerkleVerification.ManagerWithMerkleVerification__FailedToVerifyManageProof.selector,
                address(helper),
                placeData,
                uint256(0)
            )
        );
        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
    }

    /// @dev A buyAmount below the oracle-derived floor is rejected by the helper's own price check, bubbling up
    ///      through the merkle path (the leaf pins the oracle inputs but leaves the amounts free).
    function test_placeOrder_belowFloor_reverts() external {
        sellToken.mint(address(boringVault), SELL_AMOUNT);
        uint256 tooLow = BUY_AMOUNT - 1;

        (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        ) = _approveAndPlaceCalls(_params(tooLow, false));

        // The helper normalizes both amounts to 18 decimals before comparing to the floor. buyToken has 6
        // decimals, so the scale-up factor is 1e12. minBuyNormalized is BUY_AMOUNT * 1e12 = 29_700e18, the exact
        // 1% floor (10 sell * 3000 rate * 0.99); tooLow sits one buyToken atom below it.
        uint256 buyNormalized = tooLow * 1e12;
        uint256 minBuyNormalized = BUY_AMOUNT * 1e12;

        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(CowSwapHelper.PriceTooLow.selector, buyNormalized, minBuyNormalized));
        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
    }

    // ------------------------------------------------------------------------
    // Flow helpers
    // ------------------------------------------------------------------------

    /// @dev Runs the approve + placeOrder pair through the manager in one verified batch.
    function _approveAndPlace(CowSwapHelper.OrderParams memory p) internal {
        (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        ) = _approveAndPlaceCalls(p);

        vm.prank(strategist);
        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
    }

    /// @dev Builds the approve + placeOrder batch arguments (without executing) so callers can also assert reverts.
    function _approveAndPlaceCalls(CowSwapHelper.OrderParams memory p)
        internal
        view
        returns (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        )
    {
        proofs = new bytes32[][](2);
        proofs[0] = _proof(approveLeaf);
        proofs[1] = _proof(_placeLeaf(p.partiallyFillable));

        decoders = new address[](2);
        decoders[0] = address(decoder);
        decoders[1] = address(decoder);

        targets = new address[](2);
        targets[0] = address(sellToken);
        targets[1] = address(helper);

        data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, address(helper), SELL_AMOUNT);
        data[1] = abi.encodeWithSelector(CowSwapHelper.placeOrder.selector, p);

        values = new uint256[](2);
    }

    /// @dev Runs a single authorized call through the manager.
    function _manageSingle(bytes32 leaf, address target, bytes memory callData) internal {
        (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        ) = _singleCall(leaf, target, callData);

        vm.prank(strategist);
        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
    }

    /// @dev Builds single-call batch arguments for `leaf`/`target`/`callData`.
    function _singleCall(
        bytes32 leaf,
        address target,
        bytes memory callData
    )
        internal
        view
        returns (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        )
    {
        proofs = new bytes32[][](1);
        proofs[0] = _proof(leaf);
        decoders = new address[](1);
        decoders[0] = address(decoder);
        targets = new address[](1);
        targets[0] = target;
        data = new bytes[](1);
        data[0] = callData;
        values = new uint256[](1);
    }

    function _params(
        uint256 buyAmount,
        bool partiallyFillable
    )
        internal
        view
        returns (CowSwapHelper.OrderParams memory)
    {
        return CowSwapHelper.OrderParams({
            sellToken: sellToken,
            buyToken: buyToken,
            sellAmount: SELL_AMOUNT,
            buyAmount: buyAmount,
            validTo: uint32(block.timestamp + 1 hours),
            partiallyFillable: partiallyFillable,
            rateProvider: IRateProvider(address(rateProvider)),
            rateDecimals: RATE_DECIMALS,
            maxSlippageBps: MAX_SLIPPAGE_BPS
        });
    }

}
