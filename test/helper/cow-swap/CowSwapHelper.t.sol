// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { Vm } from "@forge-std/Vm.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";

import { CowSwapHelper } from "src/helper/cow-swap/CowSwapHelper.sol";
import { CowSwapOrderLib } from "src/libraries/CowSwapOrderLib.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { IGPv2Settlement } from "src/interfaces/IGPv2Settlement.sol";

/// @notice Minimal mintable ERC20 with configurable decimals.
contract MockERC20 is ERC20 {

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s, d) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

}

/// @notice Rate provider whose returned rate (and revert behaviour) the test controls.
contract MockRateProvider is IRateProvider {

    uint256 internal rate;
    bool internal reverting;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setReverting(bool _reverting) external {
        reverting = _reverting;
    }

    function getRate() external view returns (uint256) {
        require(!reverting, "MockRateProvider: reverting");
        return rate;
    }

}

/// @notice Stand-in for CoW's settlement: records pre-signatures and exposes the two immutables the helper caches.
contract MockSettlement is IGPv2Settlement {

    address public immutable vaultRelayer;
    bytes32 public immutable domainSeparator;

    mapping(bytes => bool) public isSigned;

    event PreSignatureSet(bytes orderUid, bool signed);

    constructor(address _vaultRelayer, bytes32 _domainSeparator) {
        vaultRelayer = _vaultRelayer;
        domainSeparator = _domainSeparator;
    }

    function setPreSignature(bytes calldata orderUid, bool signed) external {
        // Mirrors GPv2Signing: the owner packed into the UID (bytes [32:52] of digest ‖ owner ‖ validTo) must be
        // the caller. This is the invariant that forces the helper to be the order owner, so tests exercise it.
        require(orderUid.length == 56, "MockSettlement: bad uid length");
        address uidOwner = address(bytes20(orderUid[32:52]));
        require(uidOwner == msg.sender, "GPv2: caller does not own order");
        isSigned[orderUid] = signed;
        emit PreSignatureSet(orderUid, signed);
    }

}

/// @notice Unit tests for CowSwapHelper using mocked settlement, rate provider, and tokens (no fork).
contract CowSwapHelperTest is Test {

    using FixedPointMathLib for uint256;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    CowSwapHelper internal helper;
    MockSettlement internal settlement;
    MockRateProvider internal rateProvider;
    MockERC20 internal sellToken; // 18 decimals
    MockERC20 internal buyToken; // 6 decimals

    address internal owner = makeAddr("owner");
    address internal boringVault = makeAddr("boringVault");
    address internal relayer = makeAddr("relayer");
    bytes32 internal domainSeparator = keccak256("test-domain-separator");

    // 3000 buyToken per 1 sellToken, expressed as an 18-decimal (WAD) rate.
    uint256 internal constant RATE_18 = 3000e18;

    // Cap on how far ahead an order's validTo may be set. `uint32` to match the helper's constructor.
    uint32 internal constant MAX_ORDER_VALIDITY = 1 days;

    // Mirror of the helper's events for expectEmit.
    event OrderPlaced(
        address indexed sellToken, address indexed buyToken, uint256 sellAmount, uint256 buyAmount, bytes orderUid
    );
    event OrderCancelled(bytes orderUid);
    event FundsReturned(address indexed token, uint256 amount);
    event MaxOrderValiditySet(uint32 maxOrderValidity);

    function setUp() external {
        settlement = new MockSettlement(relayer, domainSeparator);
        rateProvider = new MockRateProvider(RATE_18);
        sellToken = new MockERC20("Sell", "SELL", 18);
        buyToken = new MockERC20("Buy", "BUY", 6);
        helper = new CowSwapHelper(owner, boringVault, address(settlement), MAX_ORDER_VALIDITY);
    }

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    function test_constructor_revertsOnZeroOwner() external {
        vm.expectRevert(CowSwapHelper.ZeroAddress.selector);
        new CowSwapHelper(address(0), boringVault, address(settlement), MAX_ORDER_VALIDITY);
    }

    function test_constructor_revertsOnZeroBoringVault() external {
        vm.expectRevert(CowSwapHelper.ZeroAddress.selector);
        new CowSwapHelper(owner, address(0), address(settlement), MAX_ORDER_VALIDITY);
    }

    function test_constructor_revertsOnZeroSettlement() external {
        vm.expectRevert(CowSwapHelper.ZeroAddress.selector);
        new CowSwapHelper(owner, boringVault, address(0), MAX_ORDER_VALIDITY);
    }

    function test_constructor_revertsOnZeroMaxOrderValidity() external {
        vm.expectRevert(CowSwapHelper.InvalidMaxOrderValidity.selector);
        new CowSwapHelper(owner, boringVault, address(settlement), 0);
    }

    /// @dev The upper bound on the cap is carried by the `uint32` parameter type rather than a runtime check, so
    ///      an out-of-range argument is rejected while the constructor decodes the creation code. Deployed here
    ///      through raw `create` because the typed `new` expression would not compile with such an argument -
    ///      which is itself the point: callers cannot express an over-wide cap.
    function test_constructor_revertsOnMaxOrderValidityAboveUint32() external {
        bytes memory creationCode = abi.encodePacked(
            type(CowSwapHelper).creationCode,
            abi.encode(owner, boringVault, address(settlement), uint256(type(uint32).max) + 1)
        );

        address deployed;
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }

        assertEq(deployed, address(0), "an out-of-range cap reverts the deployment");
    }

    /// @dev Auth is wired at construction: owner is set and the authority starts unset.
    function test_constructor_setsOwnerAndUnsetAuthority() external view {
        assertEq(helper.owner(), owner, "owner set to constructor arg");
        assertEq(address(helper.authority()), address(0), "authority starts unset");
    }

    /// @dev The relayer approval target and the UID's domain separator prove the constructor cached both
    ///      settlement immutables correctly.
    function test_constructor_cachesRelayerAndDomainSeparator() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        _fundAndApprove(p.sellAmount);

        vm.prank(boringVault);
        bytes memory uid = helper.placeOrder(p);

        assertEq(
            sellToken.allowance(address(helper), relayer),
            type(uint256).max,
            "relayer approval uses cached vaultRelayer"
        );
        assertEq(uid, _expectedUid(p), "UID uses cached domain separator");
    }

    // ------------------------------------------------------------------------
    // placeOrder — access control & validation
    // ------------------------------------------------------------------------

    function test_placeOrder_revertsForNonBoringVault() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        vm.expectRevert(CowSwapHelper.NotBoringVault.selector);
        helper.placeOrder(p); // msg.sender == this, not the vault
    }

    function test_placeOrder_revertsOnZeroSellAmount() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.sellAmount = 0;
        vm.prank(boringVault);
        vm.expectRevert(CowSwapHelper.ZeroAmount.selector);
        helper.placeOrder(p);
    }

    function test_placeOrder_revertsOnZeroBuyAmount() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.buyAmount = 0;
        vm.prank(boringVault);
        vm.expectRevert(CowSwapHelper.ZeroAmount.selector);
        helper.placeOrder(p);
    }

    function test_placeOrder_revertsWhenExpired() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.validTo = uint32(block.timestamp); // not strictly in the future
        vm.prank(boringVault);
        vm.expectRevert(CowSwapHelper.OrderExpired.selector);
        helper.placeOrder(p);
    }

    function test_placeOrder_revertsWhenValidityTooLong() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.validTo = uint32(block.timestamp + MAX_ORDER_VALIDITY + 1); // one second past the cap
        vm.prank(boringVault);
        vm.expectRevert(CowSwapHelper.OrderValidityTooLong.selector);
        helper.placeOrder(p);
    }

    function test_placeOrder_succeedsAtMaxValidity() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.validTo = uint32(block.timestamp + MAX_ORDER_VALIDITY); // exactly at the cap
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        helper.placeOrder(p); // must not revert
    }

    function test_placeOrder_revertsOnSlippageAboveDenominator() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.maxSlippageBps = BPS_DENOMINATOR + 1;
        vm.prank(boringVault);
        vm.expectRevert(CowSwapHelper.InvalidSlippage.selector);
        helper.placeOrder(p);
    }

    function test_placeOrder_revertsOnZeroRate() external {
        rateProvider.setRate(0);
        CowSwapHelper.OrderParams memory p = _defaultParams();
        vm.prank(boringVault);
        vm.expectRevert(abi.encodeWithSelector(CowSwapHelper.InvalidRate.selector, address(rateProvider)));
        helper.placeOrder(p);
    }

    function test_placeOrder_bubblesRateProviderRevert() external {
        rateProvider.setReverting(true);
        CowSwapHelper.OrderParams memory p = _defaultParams();
        vm.prank(boringVault);
        vm.expectRevert(bytes("MockRateProvider: reverting"));
        helper.placeOrder(p);
    }

    function test_placeOrder_revertsWhenBelowFloor() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        // Floor at zero slippage is exactly 3000e6; one unit below must be rejected.
        p.buyAmount = 3000e6 - 1;
        _fundAndApprove(p.sellAmount);
        _expectPriceTooLow(p);
        vm.prank(boringVault);
        helper.placeOrder(p);
    }

    function test_placeOrder_succeedsExactlyAtFloor() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.buyAmount = 3000e6; // exactly the floor
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        helper.placeOrder(p);
        assertTrue(settlement.isSigned(_expectedUid(p)), "order at floor should be signed");
    }

    function test_placeOrder_revertsOnDanglingApproval() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        sellToken.mint(boringVault, p.sellAmount);
        // Approve more than sellAmount so a residual allowance remains after the pull.
        vm.prank(boringVault);
        sellToken.approve(address(helper), p.sellAmount + 1);

        vm.prank(boringVault);
        vm.expectRevert(abi.encodeWithSelector(CowSwapHelper.DanglingApproval.selector, address(sellToken)));
        helper.placeOrder(p);
    }

    // ------------------------------------------------------------------------
    // placeOrder — happy path & effects
    // ------------------------------------------------------------------------

    function test_placeOrder_happyPath() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        _fundAndApprove(p.sellAmount);
        bytes memory expectedUid = _expectedUid(p);

        vm.expectEmit(address(helper));
        emit OrderPlaced(address(sellToken), address(buyToken), p.sellAmount, p.buyAmount, expectedUid);

        vm.prank(boringVault);
        bytes memory uid = helper.placeOrder(p);

        assertEq(uid, expectedUid, "returned UID");
        assertEq(sellToken.balanceOf(address(helper)), p.sellAmount, "helper holds the sell token");
        assertEq(sellToken.balanceOf(boringVault), 0, "vault emptied of sell token");
        assertEq(sellToken.allowance(boringVault, address(helper)), 0, "vault->helper allowance consumed");
        assertEq(sellToken.allowance(address(helper), relayer), type(uint256).max, "relayer granted unlimited approval");
        assertTrue(settlement.isSigned(expectedUid), "order pre-signed on settlement");
    }

    /// @dev Re-placing an identical order (same fields + validTo => same UID) reverts instead of pulling the
    ///      sell amount in a second time. The revert fires after the sell token is funded/approved again, proving
    ///      the guard is on the UID, not on balances.
    function test_placeOrder_revertsOnDuplicateUid() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        bytes memory uid = helper.placeOrder(p);

        _fundAndApprove(p.sellAmount); // fund again so only the duplicate guard can stop the second call
        vm.prank(boringVault);
        vm.expectRevert(abi.encodeWithSelector(CowSwapHelper.DuplicateOrder.selector, uid));
        helper.placeOrder(p);
    }

    /// @dev Even after cancellation the UID stays Closed, so it can never be re-placed (prevents double-counting
    ///      against CoW's cumulative filledAmount).
    function test_placeOrder_revertsOnReplacingCancelledUid() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        bytes memory uid = helper.placeOrder(p);
        vm.prank(boringVault);
        helper.cancelOrder(uid);

        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        vm.expectRevert(abi.encodeWithSelector(CowSwapHelper.DuplicateOrder.selector, uid));
        helper.placeOrder(p);
    }

    /// @dev Two live orders for the same sell token: the unlimited approval is not clobbered by the second
    ///      placeOrder, and the helper's balance accumulates to cover both — the fix for the one-order-at-a-time
    ///      hazard the exact-approval model had.
    function test_placeOrder_concurrentOrdersShareApproval() external {
        CowSwapHelper.OrderParams memory a = _defaultParams();
        a.sellAmount = 1e18;
        a.buyAmount = 3000e6;
        _fundAndApprove(a.sellAmount);
        vm.prank(boringVault);
        bytes memory uidA = helper.placeOrder(a);

        CowSwapHelper.OrderParams memory b = _defaultParams();
        b.sellAmount = 5e18;
        b.buyAmount = 15_000e6;
        _fundAndApprove(b.sellAmount);
        vm.prank(boringVault);
        bytes memory uidB = helper.placeOrder(b);

        assertTrue(settlement.isSigned(uidA), "order A still authorized");
        assertTrue(settlement.isSigned(uidB), "order B authorized");
        assertEq(sellToken.balanceOf(address(helper)), 6e18, "balance covers both orders");
        assertEq(
            sellToken.allowance(address(helper), relayer), type(uint256).max, "approval not clobbered by 2nd order"
        );
    }

    function test_placeOrder_slippageLowersFloor() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.maxSlippageBps = 100; // 1%
        // Floor becomes ceil(3000e6 * 9900 / 10000) = 2970e6; a buyAmount at that level clears.
        p.buyAmount = 2970e6;
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        helper.placeOrder(p);
        assertTrue(settlement.isSigned(_expectedUid(p)), "order within slippage should be signed");

        // One unit below the slackened floor must still be rejected.
        p.buyAmount = 2970e6 - 1;
        _expectPriceTooLow(p);
        vm.prank(boringVault);
        helper.placeOrder(p);
    }

    // ------------------------------------------------------------------------
    // placeOrder — rateDecimals
    // ------------------------------------------------------------------------

    /// @dev The same real price expressed at a different `rateDecimals` scale must produce the same floor.
    function test_placeOrder_rateDecimalsScaleInvariant() external {
        rateProvider.setRate(3000e6); // 3000 buy per sell, now expressed with 6-decimal scale
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.rateDecimals = 6;
        p.buyAmount = 3000e6; // still exactly the floor
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        helper.placeOrder(p);
        assertTrue(settlement.isSigned(_expectedUid(p)), "6-decimal rate yields the same floor as 18-decimal");

        p.buyAmount = 3000e6 - 1;
        _expectPriceTooLow(p);
        vm.prank(boringVault);
        helper.placeOrder(p);
    }

    /// @dev Documents the drain risk that makes `rateDecimals` a load-bearing, decoder-pinned field: an
    ///      oversized value (here 30 vs the rate's true 18) inflates the divisor so the floor collapses and a
    ///      near-zero `buyAmount` is accepted. This is WHY the decoder must pin `rateDecimals`.
    function test_placeOrder_oversizedRateDecimalsCollapsesFloor() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.rateDecimals = 30; // rate is really 18-decimal; claiming 30 divides the floor by 1e12
        p.buyAmount = 1; // 1 unit of a 6-decimal token — economically ~zero
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        helper.placeOrder(p);
        assertTrue(
            settlement.isSigned(_expectedUid(p)),
            "mismatched rateDecimals lets a near-zero buyAmount pass; the decoder MUST pin it"
        );
    }

    // ------------------------------------------------------------------------
    // placeOrder — partiallyFillable & decimals
    // ------------------------------------------------------------------------

    /// @dev The flag is folded into the signed digest, so flipping it yields a different UID.
    function test_placeOrder_partiallyFillableChangesUid() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();

        p.partiallyFillable = false;
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        bytes memory fillOrKillUid = helper.placeOrder(p);
        assertEq(fillOrKillUid, _expectedUid(p), "fill-or-kill UID matches reconstruction");

        p.partiallyFillable = true;
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        bytes memory partialUid = helper.placeOrder(p);
        assertEq(partialUid, _expectedUid(p), "partial-fill UID matches reconstruction");

        assertTrue(keccak256(fillOrKillUid) != keccak256(partialUid), "flag must change the UID");
    }

    /// @dev Sell token with 6 decimals, buy token with 18 — exercises the other side of `normalize`.
    function test_placeOrder_handlesInvertedDecimals() external {
        MockERC20 sell6 = new MockERC20("Sell6", "S6", 6);
        MockERC20 buy18 = new MockERC20("Buy18", "B18", 18);

        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.sellToken = ERC20(address(sell6));
        p.buyToken = ERC20(address(buy18));
        p.sellAmount = 1e6; // 1 whole sell token
        p.buyAmount = 3000e18; // exactly the floor: 3000 whole buy tokens

        sell6.mint(boringVault, p.sellAmount);
        vm.prank(boringVault);
        sell6.approve(address(helper), p.sellAmount);

        vm.prank(boringVault);
        helper.placeOrder(p);
        assertTrue(settlement.isSigned(_expectedUid(p)), "inverted-decimal order priced correctly");
    }

    // ------------------------------------------------------------------------
    // placeOrder — >18-decimal rounding (directional, conservative for the vault)
    // ------------------------------------------------------------------------

    /// @dev Sell token with 19 decimals: the sell amount must round UP, tightening the floor. With sellAmount
    ///      = 15 (divisor 10), sellNormalized rounds 1.5 -> 2, so a 1-unit buy is rejected where a round-DOWN
    ///      implementation (the old truncating one) would have accepted it. This is the truncation fix.
    function test_placeOrder_sellSideRoundsUp() external {
        MockERC20 sell19 = new MockERC20("Sell19", "S19", 19);
        MockERC20 buy18 = new MockERC20("Buy18", "B18", 18);
        rateProvider.setRate(1e18); // 1:1 in whole tokens

        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.sellToken = ERC20(address(sell19));
        p.buyToken = ERC20(address(buy18));
        p.sellAmount = 15; // normalizes to ceil(15 / 10) = 2 (round up)

        // buyAmount = 1 -> buyNormalized 1 < floor 2 -> rejected (would pass under the old round-down).
        p.buyAmount = 1;
        _fundAndApproveToken(sell19, p.sellAmount);
        _expectPriceTooLow(p);
        vm.prank(boringVault);
        helper.placeOrder(p);

        // buyAmount = 2 -> buyNormalized 2 >= floor 2 -> accepted.
        p.buyAmount = 2;
        _fundAndApproveToken(sell19, p.sellAmount);
        vm.prank(boringVault);
        helper.placeOrder(p);
        assertTrue(settlement.isSigned(_expectedUid(p)), "order at the rounded-up floor clears");
    }

    /// @dev Buy token with 19 decimals: the buy amount must round DOWN, keeping the floor conservative. With a
    ///      floor of 1e18 normalized, buyAmount = 1e19 - 5 rounds down to 1e18 - 1 and is rejected, whereas a
    ///      round-UP implementation would have accepted it.
    function test_placeOrder_buySideRoundsDown() external {
        MockERC20 sell18 = new MockERC20("Sell18", "S18", 18);
        MockERC20 buy19 = new MockERC20("Buy19", "B19", 19);
        rateProvider.setRate(1e18); // 1:1 in whole tokens

        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.sellToken = ERC20(address(sell18));
        p.buyToken = ERC20(address(buy19));
        p.sellAmount = 1e18; // sellNormalized 1e18 -> floor 1e18

        // buyAmount = 1e19 - 5 -> buyNormalized floor((1e19 - 5) / 10) = 1e18 - 1 < floor -> rejected.
        p.buyAmount = 1e19 - 5;
        _fundAndApproveToken(sell18, p.sellAmount);
        _expectPriceTooLow(p);
        vm.prank(boringVault);
        helper.placeOrder(p);

        // buyAmount = 1e19 -> buyNormalized 1e18 >= floor 1e18 -> accepted.
        p.buyAmount = 1e19;
        _fundAndApproveToken(sell18, p.sellAmount);
        vm.prank(boringVault);
        helper.placeOrder(p);
        assertTrue(settlement.isSigned(_expectedUid(p)), "order at the rounded-down floor clears");
    }

    // ------------------------------------------------------------------------
    // cancelOrder
    // ------------------------------------------------------------------------

    /// @dev Cancellation clears the pre-signature and closes the UID, moving no tokens; the helper keeps its
    ///      balance, which is pulled back separately via sweepToken.
    function test_cancelOrder_clearsSignatureAndMovesNoTokens() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        bytes memory uid = helper.placeOrder(p);
        assertTrue(settlement.isSigned(uid), "precondition: order signed");
        assertEq(sellToken.balanceOf(address(helper)), p.sellAmount, "precondition: helper holds sell token");

        vm.expectEmit(address(helper));
        emit OrderCancelled(uid);
        vm.prank(boringVault);
        helper.cancelOrder(uid);

        assertFalse(settlement.isSigned(uid), "order signature cleared");
        assertEq(sellToken.balanceOf(address(helper)), p.sellAmount, "helper balance untouched by cancel");
        assertEq(sellToken.balanceOf(boringVault), 0, "cancel moves no tokens to the vault");
    }

    /// @dev The unfilled sell tokens left after a cancel are recovered by sweepToken, not by cancelOrder itself.
    function test_cancelOrder_thenSweepReturnsTokens() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        bytes memory uid = helper.placeOrder(p);

        vm.prank(boringVault);
        helper.cancelOrder(uid);

        vm.prank(boringVault);
        helper.sweepToken(ERC20(address(sellToken)), p.sellAmount);

        assertEq(sellToken.balanceOf(boringVault), p.sellAmount, "vault made whole via sweepToken after cancel");
        assertEq(sellToken.balanceOf(address(helper)), 0, "helper swept");
    }

    /// @dev An expired-but-uncancelled order is still Active, so it can be cancelled after expiry.
    function test_cancelOrder_expiredOrderIsCancellable() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        bytes memory uid = helper.placeOrder(p);

        // Warp past the order's validTo; the helper never auto-closes, so the record stays Active.
        vm.warp(uint256(p.validTo) + 1);

        vm.prank(boringVault);
        helper.cancelOrder(uid);
        assertFalse(settlement.isSigned(uid), "expired order can still be cancelled");
    }

    function test_cancelOrder_revertsOnUnknownUid() external {
        vm.prank(boringVault);
        vm.expectRevert(abi.encodeWithSelector(CowSwapHelper.UnknownOrder.selector, bytes(hex"1234")));
        helper.cancelOrder(hex"1234");
    }

    /// @dev Double cancellation reverts: the record is Closed after the first cancel.
    function test_cancelOrder_revertsOnDoubleCancel() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        bytes memory uid = helper.placeOrder(p);

        vm.prank(boringVault);
        helper.cancelOrder(uid);

        vm.prank(boringVault);
        vm.expectRevert(abi.encodeWithSelector(CowSwapHelper.UnknownOrder.selector, uid));
        helper.cancelOrder(uid);
    }

    function test_cancelOrder_revertsForNonBoringVault() external {
        vm.expectRevert(CowSwapHelper.NotBoringVault.selector);
        helper.cancelOrder(hex"1234");
    }

    // ------------------------------------------------------------------------
    // sweepToken
    // ------------------------------------------------------------------------

    /// @dev The strategist (the boringVault, via the merkle manager) sweeps, and the amount routes to the vault.
    function test_sweepToken_boringVaultSweepsAmountAndEmits() external {
        uint256 stranded = 5e18;
        sellToken.mint(address(helper), stranded);

        vm.expectEmit(address(helper));
        emit FundsReturned(address(sellToken), stranded);
        vm.prank(boringVault);
        helper.sweepToken(ERC20(address(sellToken)), stranded);

        assertEq(sellToken.balanceOf(address(helper)), 0, "helper swept");
        assertEq(sellToken.balanceOf(boringVault), stranded, "vault received residual");
    }

    /// @dev Only the requested amount is moved; the rest stays in the helper (e.g. collateral for a live order).
    function test_sweepToken_sweepsPartialAmount() external {
        uint256 stranded = 5e18;
        sellToken.mint(address(helper), stranded);

        uint256 amount = 2e18;
        vm.expectEmit(address(helper));
        emit FundsReturned(address(sellToken), amount);
        vm.prank(boringVault);
        helper.sweepToken(ERC20(address(sellToken)), amount);

        assertEq(sellToken.balanceOf(boringVault), amount, "vault received the requested amount");
        assertEq(sellToken.balanceOf(address(helper)), stranded - amount, "helper keeps the remainder");
    }

    function test_sweepToken_noopOnZeroAmount() external {
        sellToken.mint(address(helper), 5e18);
        vm.recordLogs();
        vm.prank(boringVault);
        helper.sweepToken(ERC20(address(sellToken)), 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no transfer or event on a zero amount");
        assertEq(sellToken.balanceOf(boringVault), 0, "nothing moved");
    }

    /// @dev Only the merkle-verified vault path may sweep; even the Auth owner is rejected.
    function test_sweepToken_revertsForNonBoringVault() external {
        vm.prank(owner);
        vm.expectRevert(CowSwapHelper.NotBoringVault.selector);
        helper.sweepToken(ERC20(address(sellToken)), 0);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(CowSwapHelper.NotBoringVault.selector);
        helper.sweepToken(ERC20(address(sellToken)), 0);
    }

    // ------------------------------------------------------------------------
    // setMaxOrderValidity
    // ------------------------------------------------------------------------

    /// @dev The constructor sets the value through the shared internal setter, so it emits the event too (T8).
    function test_constructor_emitsMaxOrderValidity() external {
        vm.expectEmit(false, false, false, true);
        emit MaxOrderValiditySet(MAX_ORDER_VALIDITY);
        new CowSwapHelper(owner, boringVault, address(settlement), MAX_ORDER_VALIDITY);
    }

    function test_setMaxOrderValidity_ownerUpdatesAndEmits() external {
        uint32 newValidity = 2 days;
        vm.expectEmit(address(helper));
        emit MaxOrderValiditySet(newValidity);
        vm.prank(owner);
        helper.setMaxOrderValidity(newValidity);

        // The new cap governs subsequent orders: an order one second past it is rejected...
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.validTo = uint32(block.timestamp + newValidity + 1);
        vm.prank(boringVault);
        vm.expectRevert(CowSwapHelper.OrderValidityTooLong.selector);
        helper.placeOrder(p);

        // ...while one exactly at the new cap (beyond the old 1-day cap) now succeeds.
        p.validTo = uint32(block.timestamp + newValidity);
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        helper.placeOrder(p);
        assertTrue(settlement.isSigned(_expectedUid(p)), "order under the raised cap is signed");
    }

    function test_setMaxOrderValidity_revertsForUnauthorized() external {
        // Neither the boringVault nor a random address is the owner or permitted by an (unset) authority.
        vm.prank(boringVault);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        helper.setMaxOrderValidity(2 days);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("UNAUTHORIZED"));
        helper.setMaxOrderValidity(2 days);
    }

    function test_setMaxOrderValidity_revertsOnZero() external {
        vm.prank(owner);
        vm.expectRevert(CowSwapHelper.InvalidMaxOrderValidity.selector);
        helper.setMaxOrderValidity(0);
    }

    /// @dev Counterpart to the constructor case: the `uint32` parameter type is the upper bound, so a hand-crafted
    ///      over-wide word is rejected by ABI decoding (a bare revert, no `InvalidMaxOrderValidity`) and the
    ///      stored cap is left untouched.
    function test_setMaxOrderValidity_revertsOnValueAboveUint32() external {
        vm.prank(owner);
        (bool success, bytes memory returnData) = address(helper)
            .call(abi.encodeWithSelector(CowSwapHelper.setMaxOrderValidity.selector, uint256(type(uint32).max) + 1));

        assertFalse(success, "an out-of-range cap is rejected");
        assertEq(returnData.length, 0, "rejected by the ABI decoder, so no custom error is returned");

        // The old cap still governs: an order one second past it is still refused.
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.validTo = uint32(block.timestamp + MAX_ORDER_VALIDITY + 1);
        vm.prank(boringVault);
        vm.expectRevert(CowSwapHelper.OrderValidityTooLong.selector);
        helper.placeOrder(p);
    }

    // ------------------------------------------------------------------------
    // Auth does not gate the order functions
    // ------------------------------------------------------------------------

    /// @dev The Auth owner is NOT the boringVault, so the order functions (`placeOrder`/`cancelOrder`) still
    ///      reject it: `Authority`/owner grants no access to order logic, which stays reachable only via the
    ///      merkle-verified vault path.
    function test_orderFunctions_rejectAuthOwner() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();

        vm.prank(owner);
        vm.expectRevert(CowSwapHelper.NotBoringVault.selector);
        helper.placeOrder(p);

        vm.prank(owner);
        vm.expectRevert(CowSwapHelper.NotBoringVault.selector);
        helper.cancelOrder(hex"1234");
    }

    // ------------------------------------------------------------------------
    // Fuzz: the floor boundary is exact
    // ------------------------------------------------------------------------

    /// @dev For any in-range inputs, a buyAmount at the computed floor clears and one unit below reverts.
    function testFuzz_floorBoundaryIsExact(uint256 sellAmount, uint256 rate, uint256 slippageBps) external {
        sellAmount = bound(sellAmount, 1, 1e30);
        rate = bound(rate, 1, 1e30);
        slippageBps = bound(slippageBps, 0, BPS_DENOMINATOR);

        rateProvider.setRate(rate);

        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.sellAmount = sellAmount;
        p.rateDecimals = 18;
        p.maxSlippageBps = slippageBps;

        // Reproduce the helper's floor math (both tokens: 18 and 6 decimals via normalize).
        uint256 sellNormalized = _normalize(sellAmount, 18, true);
        uint256 fairBuyNormalized = sellNormalized.mulDivUp(rate, 1e18);
        uint256 minBuyNormalized = fairBuyNormalized.mulDivUp(BPS_DENOMINATOR - slippageBps, BPS_DENOMINATOR);

        // Smallest 6-decimal buyAmount whose normalized value reaches the floor.
        uint256 buyAtFloor = minBuyNormalized.mulDivUp(1, 1e12);
        vm.assume(buyAtFloor > 0 && buyAtFloor < type(uint128).max);

        p.buyAmount = buyAtFloor;
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        helper.placeOrder(p); // must not revert

        // One 6-decimal unit below the floor must fail (its normalized value drops below minBuyNormalized).
        // Guard buyAtFloor > 1 so buyAmount stays >= 1 and we isolate the floor check from the ZeroAmount check.
        if (buyAtFloor > 1 && _normalize(buyAtFloor - 1, 6, false) < minBuyNormalized) {
            p.buyAmount = buyAtFloor - 1;
            _fundAndApprove(p.sellAmount);
            _expectPriceTooLow(p);
            vm.prank(boringVault);
            helper.placeOrder(p);
        }
    }

    /// @dev At 100% slippage the oracle floor collapses to zero, so only the `ZeroAmount` check constrains
    ///      `buyAmount`. This is the upper boundary of the inclusive `maxSlippageBps <= BPS_DENOMINATOR` bound and
    ///      is excluded from `testFuzz_floorBoundaryIsExact` (a zero floor makes `buyAtFloor` zero, which the
    ///      fuzz test's `vm.assume` discards). Accepted by design: the decoder pins `maxSlippageBps`. Pinned here
    ///      so a later tightening of the bound is caught.
    function test_placeOrder_fullSlippageCollapsesFloor() external {
        CowSwapHelper.OrderParams memory p = _defaultParams();
        p.maxSlippageBps = BPS_DENOMINATOR;
        p.buyAmount = 1; // smallest non-zero buy; clears because the floor is zero.
        _fundAndApprove(p.sellAmount);
        vm.prank(boringVault);
        helper.placeOrder(p);
        assertTrue(settlement.isSigned(_expectedUid(p)), "100% slippage removes the floor entirely");
    }

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------

    function _defaultParams() internal view returns (CowSwapHelper.OrderParams memory p) {
        p = CowSwapHelper.OrderParams({
            sellToken: ERC20(address(sellToken)),
            buyToken: ERC20(address(buyToken)),
            sellAmount: 1e18,
            buyAmount: 3000e6,
            validTo: uint32(block.timestamp + 1 hours),
            partiallyFillable: false,
            rateProvider: IRateProvider(address(rateProvider)),
            rateDecimals: 18,
            maxSlippageBps: 0
        });
    }

    /// @dev Recomputes the helper's normalized price floor for `p` (mirrors `_buildAndValidateOrderUid`): the
    ///      sell amount rounds up, the buy amount rounds down.
    function _floorNormalized(CowSwapHelper.OrderParams memory p) internal view returns (uint256) {
        uint256 rate = rateProvider.getRate();
        uint256 sellNormalized = _normalize(p.sellAmount, p.sellToken.decimals(), true);
        uint256 fairBuyNormalized = sellNormalized.mulDivUp(rate, 10 ** p.rateDecimals);
        return fairBuyNormalized.mulDivUp(BPS_DENOMINATOR - p.maxSlippageBps, BPS_DENOMINATOR);
    }

    /// @dev Arms an expectRevert for the exact `PriceTooLow(buyNormalized, minBuyNormalized)` `p` will trigger.
    ///      Values are computed before arming so no stray call consumes the cheatcode.
    function _expectPriceTooLow(CowSwapHelper.OrderParams memory p) internal {
        uint256 minBuyNormalized = _floorNormalized(p);
        uint256 buyNormalized = _normalize(p.buyAmount, p.buyToken.decimals(), false);
        vm.expectRevert(abi.encodeWithSelector(CowSwapHelper.PriceTooLow.selector, buyNormalized, minBuyNormalized));
    }

    /// @dev Test-local mirror of the helper's private `_normalize` (directional rounding to 18 decimals).
    function _normalize(uint256 amount, uint8 decimals, bool roundUp) internal pure returns (uint256) {
        if (decimals <= 18) {
            return amount * (10 ** (18 - decimals));
        }
        uint256 divisor = 10 ** (decimals - 18);
        return roundUp ? FixedPointMathLib.mulDivUp(amount, 1, divisor) : amount / divisor;
    }

    /// @dev Mints `amount` of the default sell token to the vault and approves exactly that to the helper.
    function _fundAndApprove(uint256 amount) internal {
        _fundAndApproveToken(sellToken, amount);
    }

    /// @dev Mints `amount` of `token` to the vault and approves exactly that to the helper.
    function _fundAndApproveToken(MockERC20 token, uint256 amount) internal {
        token.mint(boringVault, amount);
        vm.prank(boringVault);
        token.approve(address(helper), amount);
    }

    /// @dev Reconstructs the canonical order UID the helper should produce for `p`.
    function _expectedUid(CowSwapHelper.OrderParams memory p) internal view returns (bytes memory) {
        CowSwapOrderLib.Data memory order = CowSwapOrderLib.Data({
            sellToken: address(p.sellToken),
            buyToken: address(p.buyToken),
            receiver: boringVault,
            sellAmount: p.sellAmount,
            buyAmount: p.buyAmount,
            validTo: p.validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: CowSwapOrderLib.KIND_SELL,
            partiallyFillable: p.partiallyFillable,
            sellTokenBalance: CowSwapOrderLib.BALANCE_ERC20,
            buyTokenBalance: CowSwapOrderLib.BALANCE_ERC20
        });
        bytes32 digest = CowSwapOrderLib.hash(order, domainSeparator);
        return CowSwapOrderLib.packOrderUid(digest, address(helper), p.validTo);
    }

}
