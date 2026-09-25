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

/// @notice Extended settlement view used only in tests: the public `preSignature` mapping getter, which the
///         minimal `IGPv2Settlement` interface omits. A non-zero value means the UID is pre-signed.
interface IGPv2SettlementExt {

    function preSignature(bytes calldata orderUid) external view returns (uint256);

}

/// @notice Concrete decoder exposing only the CowSwap surface for this test.
contract CowSwapForkDecoderAndSanitizer is CowSwapHelperDecoderAndSanitizer {

    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

}

/// @notice Fork tests exercising the full strategist path - ManagerWithMerkleVerification -> BoringVault ->
///         CowSwapHelper -> the REAL CoW settlement - against a mainnet fork.
/// @dev Only the rate provider is mocked (an external oracle dependency); the settlement, its cached domain
///      separator and vault relayer, the pre-signature bookkeeping, and the ERC20s are all real. This is the
///      coverage the fork-free `CowSwapHelperIntegration.t.sol` cannot provide: that the helper's reconstructed
///      UID is actually accepted and recorded by CoW's own settlement contract. Requires `MAINNET_RPC_URL`. The
///      roles wiring, merkle tree construction, and order-UID reconstruction live in CowSwapHelperTestBase.
contract CowSwapHelperForkTest is CowSwapHelperTestBase {

    // Real CoW Protocol GPv2Settlement on Ethereum mainnet.
    address internal constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    ERC20 internal constant WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ERC20 internal constant USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    uint256 internal constant FORK_BLOCK = 19_826_676;

    function setUp() external {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);

        boringVault = new BoringVault(address(this), "Boring Vault", "BV", 18);
        manager = new ManagerWithMerkleVerification(address(this), address(boringVault), address(0));
        decoder = new CowSwapForkDecoderAndSanitizer(address(boringVault));
        rateProvider = new FixedRateProvider(RATE_18);
        helper = new CowSwapHelper(address(this), address(boringVault), COW_SETTLEMENT, MAX_ORDER_VALIDITY);

        _wireRolesAuthority();
        _buildAndSetRoot(false);
    }

    function _sellToken() internal view override returns (address) {
        return address(WETH);
    }

    function _buyToken() internal view override returns (address) {
        return address(USDC);
    }

    function _settlement() internal view override returns (address) {
        return COW_SETTLEMENT;
    }

    // ------------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------------

    /// @dev Approve + placeOrder in one merkle-verified batch, then check the real settlement pre-signed the UID
    ///      and the sell token moved from the vault into the helper (which custodies it, not a proxy).
    function test_placeOrder_presignsOnRealSettlement() external {
        deal(address(WETH), address(boringVault), SELL_AMOUNT);

        CowSwapHelper.OrderParams memory p = _params(BUY_AMOUNT, false);
        bytes memory uid = _expectedUid(p);
        _approveAndPlace(p);

        assertTrue(IGPv2SettlementExt(COW_SETTLEMENT).preSignature(uid) != 0, "order pre-signed on real settlement");
        assertEq(WETH.balanceOf(address(helper)), SELL_AMOUNT, "helper custodies the sell token");
        assertEq(WETH.balanceOf(address(boringVault)), 0, "vault moved the sell token out");
        assertEq(
            WETH.allowance(address(helper), IGPv2Settlement(COW_SETTLEMENT).vaultRelayer()),
            type(uint256).max,
            "real relayer approved to pull from the helper"
        );
    }

    /// @dev A cancel batch clears the pre-signature on the real settlement; a following sweepToken batch returns
    ///      the unfilled collateral from the helper to the vault.
    function test_cancelOrder_clearsPresignatureOnRealSettlement() external {
        deal(address(WETH), address(boringVault), SELL_AMOUNT);
        CowSwapHelper.OrderParams memory p = _params(BUY_AMOUNT, false);
        bytes memory uid = _expectedUid(p);
        _approveAndPlace(p);
        assertTrue(IGPv2SettlementExt(COW_SETTLEMENT).preSignature(uid) != 0, "precondition: signed");

        _manageSingle(cancelLeaf, address(helper), abi.encodeWithSelector(CowSwapHelper.cancelOrder.selector, uid));
        assertEq(IGPv2SettlementExt(COW_SETTLEMENT).preSignature(uid), 0, "pre-signature cleared on real settlement");

        _manageSingle(
            sweepLeaf,
            address(helper),
            abi.encodeWithSelector(CowSwapHelper.sweepToken.selector, address(WETH), SELL_AMOUNT)
        );
        assertEq(WETH.balanceOf(address(helper)), 0, "helper swept");
        assertEq(WETH.balanceOf(address(boringVault)), SELL_AMOUNT, "vault made whole on sweep");
    }

    // ------------------------------------------------------------------------
    // Flow helpers
    // ------------------------------------------------------------------------

    /// @dev Runs the approve + placeOrder pair through the manager in one verified batch.
    function _approveAndPlace(CowSwapHelper.OrderParams memory p) internal {
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = _proof(approveLeaf);
        proofs[1] = _proof(_placeLeaf(p.partiallyFillable));

        address[] memory decoders = new address[](2);
        decoders[0] = address(decoder);
        decoders[1] = address(decoder);

        address[] memory targets = new address[](2);
        targets[0] = address(WETH);
        targets[1] = address(helper);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, address(helper), SELL_AMOUNT);
        data[1] = abi.encodeWithSelector(CowSwapHelper.placeOrder.selector, p);

        uint256[] memory values = new uint256[](2);

        vm.prank(strategist);
        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
    }

    /// @dev Runs a single authorized call through the manager.
    function _manageSingle(bytes32 leaf, address target, bytes memory callData) internal {
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = _proof(leaf);
        address[] memory decoders = new address[](1);
        decoders[0] = address(decoder);
        address[] memory targets = new address[](1);
        targets[0] = target;
        bytes[] memory data = new bytes[](1);
        data[0] = callData;
        uint256[] memory values = new uint256[](1);

        vm.prank(strategist);
        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
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
            sellToken: WETH,
            buyToken: USDC,
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
