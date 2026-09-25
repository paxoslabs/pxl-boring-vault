// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PaxgyDynamicWithdrawalFeeModule } from "src/helper/PaxgyDynamicWithdrawalFeeModule.sol";
import { PaxgXauRateProvider } from "src/oracles/PaxgXauRateProvider.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { IPriceFeed } from "src/interfaces/IPriceFeed.sol";
import { MockPriceFeed } from "test/mocks/MockPriceFeed.sol";
import { MockToken } from "test/mocks/MockToken.sol";

contract PaxgyDynamicWithdrawalFeeModuleTest is Test {

    uint8 internal constant FEED_DECIMALS = 8;
    uint256 internal constant PEG_PRICE = 1e18;
    uint256 internal constant FIXED_FEE_BPS = 10; // 0.10%
    uint256 internal constant BPS_DIVISOR = 10_000;
    uint256 internal constant MAX_STALE = 1 days;
    uint256 internal constant NOW = 1_753_000_000;

    MockPriceFeed internal paxgUsdFeed;
    MockPriceFeed internal xauUsdFeed;
    MockToken internal paxg;
    MockToken internal shares;
    PaxgXauRateProvider internal oracle;
    PaxgyDynamicWithdrawalFeeModule internal module;

    function setUp() external {
        vm.warp(NOW);

        paxgUsdFeed = new MockPriceFeed(FEED_DECIMALS, "PAXG / USD", int256(3400e8), NOW);
        xauUsdFeed = new MockPriceFeed(FEED_DECIMALS, "XAU / USD", int256(3400e8), NOW);
        paxg = new MockToken("PAX Gold", "PAXG", 18);
        shares = new MockToken("PAXGy", "PAXGy", 18);

        oracle = new PaxgXauRateProvider(
            "PAXG / USD",
            "XAU / USD",
            ERC20(address(paxg)),
            IPriceFeed(address(paxgUsdFeed)),
            IPriceFeed(address(xauUsdFeed)),
            MAX_STALE
        );

        module = new PaxgyDynamicWithdrawalFeeModule(
            IRateProvider(address(oracle)), IERC20(address(paxg)), IERC20(address(shares)), FIXED_FEE_BPS
        );
    }

    /// @dev Sets the PAXG:XAU market price by moving the PAXG/USD feed, holding XAU/USD at $3400.
    /// @param price PAXG:XAU price in 18-decimal fixed point (PEG_PRICE = 1.0).
    function _setPaxgXauPrice(uint256 price) internal {
        // p = paxgUsd / xauUsd  =>  paxgUsd = p * xauUsd
        paxgUsdFeed.setAnswer(int256(price * uint256(3400e8) / PEG_PRICE));
    }

    /// @dev offerAsset = shares, wantAsset = PAXG (the withdrawal target).
    function _fee(uint256 amount) internal view returns (uint256) {
        return module.calculateOfferFees(amount, IERC20(address(shares)), IERC20(address(paxg)), address(0xBEEF));
    }

    /// @dev Independent reference implementation of the fee (plain division + explicit round-up), used to
    /// cross-check the module's solmate mulDivUp without reusing its code path. The fixed bps fee is taken
    /// first and the dynamic depeg fee is levied only on the remainder, so the total is inherently <= amount
    /// and needs no cap.
    function _expectedFee(uint256 amount, uint256 price) internal pure returns (uint256) {
        // Fixed component, taken first: FIXED_FEE_BPS of the amount, rounded up.
        uint256 fnum = amount * FIXED_FEE_BPS;
        uint256 fixedFee = fnum / BPS_DIVISOR;
        if (fnum % BPS_DIVISOR != 0) fixedFee++;

        uint256 remaining = amount - fixedFee;

        // Dynamic depeg component: (p - 1)/p of the remainder, rounded up, zero at or below peg.
        uint256 dynamicFee = 0;
        if (price > PEG_PRICE) {
            uint256 num = remaining * (price - PEG_PRICE);
            dynamicFee = num / price;
            if (num % price != 0) dynamicFee++;
        }

        return fixedFee + dynamicFee;
    }

    function testConstructorRejectsZeroRateProvider() external {
        vm.expectRevert(PaxgyDynamicWithdrawalFeeModule.ZeroAddress.selector);
        new PaxgyDynamicWithdrawalFeeModule(
            IRateProvider(address(0)), IERC20(address(paxg)), IERC20(address(shares)), FIXED_FEE_BPS
        );
    }

    function testConstructorRejectsZeroPaxg() external {
        vm.expectRevert(PaxgyDynamicWithdrawalFeeModule.ZeroAddress.selector);
        new PaxgyDynamicWithdrawalFeeModule(
            IRateProvider(address(oracle)), IERC20(address(0)), IERC20(address(shares)), FIXED_FEE_BPS
        );
    }

    function testConstructorRejectsZeroShares() external {
        vm.expectRevert(PaxgyDynamicWithdrawalFeeModule.ZeroAddress.selector);
        new PaxgyDynamicWithdrawalFeeModule(
            IRateProvider(address(oracle)), IERC20(address(paxg)), IERC20(address(0)), FIXED_FEE_BPS
        );
    }

    /// @notice A fixed fee above 100% (BPS_DIVISOR) is rejected at construction.
    function testConstructorRejectsFixedFeeBpsAboveMax() external {
        vm.expectRevert(
            abi.encodeWithSelector(PaxgyDynamicWithdrawalFeeModule.InvalidFixedFeeBps.selector, BPS_DIVISOR + 1)
        );
        new PaxgyDynamicWithdrawalFeeModule(
            IRateProvider(address(oracle)), IERC20(address(paxg)), IERC20(address(shares)), BPS_DIVISOR + 1
        );
    }

    /// @notice A fixed fee of exactly 100% (BPS_DIVISOR) is allowed (boundary).
    function testConstructorAcceptsFixedFeeBpsAtMax() external {
        PaxgyDynamicWithdrawalFeeModule m = new PaxgyDynamicWithdrawalFeeModule(
            IRateProvider(address(oracle)), IERC20(address(paxg)), IERC20(address(shares)), BPS_DIVISOR
        );
        assertEq(m.FIXED_FEE_BPS(), BPS_DIVISOR);
    }

    /// @notice The fixed fee bps is stored and exposed as set at construction.
    function testFixedFeeBpsIsSet() external view {
        assertEq(module.FIXED_FEE_BPS(), FIXED_FEE_BPS);
    }

    /// @notice A different bps scales the fixed fee accordingly (e.g. 100 bps => 1%).
    function testNonDefaultFixedFeeBps() external {
        PaxgyDynamicWithdrawalFeeModule m = new PaxgyDynamicWithdrawalFeeModule(
            IRateProvider(address(oracle)), IERC20(address(paxg)), IERC20(address(shares)), 100
        );
        _setPaxgXauPrice(PEG_PRICE);
        // At peg only the fixed fee applies: 100e18 * 100 / 10_000 = 1e18 (100 bps = 1%).
        assertEq(m.calculateOfferFees(100e18, IERC20(address(shares)), IERC20(address(paxg)), address(0xBEEF)), 1e18);
    }

    /// @notice PEG_PRICE must equal 10**(rate provider decimals); a mismatch would silently mis-scale fees.
    function testPegPriceMatchesRateProviderDecimals() external view {
        assertEq(module.PEG_PRICE(), 10 ** uint256(oracle.RATE_DECIMALS()));
    }

    /// @notice The constructor rejects a provider whose rate precision does not match PEG_PRICE, since the
    /// dynamic depeg fee compares getRate() directly against the 1e18 peg.
    function testConstructorRejectsRateProviderDecimalsMismatch() external {
        // A 6-decimal PAXG makes the provider report RATE_DECIMALS = 6, so 10**6 != PEG_PRICE.
        MockToken paxg6 = new MockToken("PAX Gold", "PAXG", 6);
        PaxgXauRateProvider badOracle = new PaxgXauRateProvider(
            "PAXG / USD",
            "XAU / USD",
            ERC20(address(paxg6)),
            IPriceFeed(address(paxgUsdFeed)),
            IPriceFeed(address(xauUsdFeed)),
            MAX_STALE
        );
        vm.expectRevert(abi.encodeWithSelector(PaxgyDynamicWithdrawalFeeModule.InvalidRateProviderDecimals.selector, 6));
        new PaxgyDynamicWithdrawalFeeModule(
            IRateProvider(address(badOracle)), IERC20(address(paxg)), IERC20(address(shares)), FIXED_FEE_BPS
        );
    }

    /// @notice A non-PAXG want asset reverts rather than being priced.
    function testRevertsOnNonPaxgWantAsset() external {
        MockToken other = new MockToken("Other", "OTH", 18);
        vm.expectRevert(
            abi.encodeWithSelector(PaxgyDynamicWithdrawalFeeModule.InvalidWantAsset.selector, address(other))
        );
        module.calculateOfferFees(1e18, IERC20(address(shares)), IERC20(address(other)), address(0xBEEF));
    }

    /// @notice An offer asset other than the bound share token reverts, keeping the module to its one vault.
    function testRevertsOnNonSharesOfferAsset() external {
        MockToken other = new MockToken("Other", "OTH", 18);
        vm.expectRevert(
            abi.encodeWithSelector(PaxgyDynamicWithdrawalFeeModule.InvalidOfferAsset.selector, address(other))
        );
        module.calculateOfferFees(1e18, IERC20(address(other)), IERC20(address(paxg)), address(0xBEEF));
    }

    /// @notice At peg (p = 1) the dynamic component is zero, so only the fixed 10 bps fee applies.
    function testOnlyFixedFeeAtPeg() external {
        _setPaxgXauPrice(PEG_PRICE);
        // 100 shares * 10 / 10_000 = 0.1 shares
        assertEq(_fee(100e18), 0.1e18);
    }

    /// @notice Below peg (p < 1) the dynamic component is zero, so only the fixed 10 bps fee applies.
    function testOnlyFixedFeeBelowPeg() external {
        _setPaxgXauPrice(0.95e18);
        assertEq(_fee(100e18), 0.1e18);
    }

    /// @notice Above peg the fee is the fixed 10 bps taken first, then the dynamic (p - 1)/p on the
    /// remainder, taken in shares.
    function testFeeAbovePeg() external {
        // p = 2.0  =>  dynamic fraction = (2 - 1)/2 = 50%
        _setPaxgXauPrice(2e18);
        // fixed: 100 * 10/10_000 = 0.1 shares; remaining = 99.9; dynamic: 99.9 * 0.5 = 49.95 shares
        assertEq(_fee(100e18), 50.05e18);
    }

    /// @notice A small premium charges the exact (p - 1)/p fraction (cross-checked against a reference impl).
    function testFeeSmallPremium() external {
        _setPaxgXauPrice(1.02e18); // ~1.9608%
        assertEq(_fee(100e18), _expectedFee(100e18, 1.02e18));
    }

    /// @notice The residual always rounds in the vault's favor (both fee components round up).
    function testFeeRoundsUpInVaultFavor() external {
        // amount = 3 wei, p = 2.0: fixed = ceil(3 * 10 / 10_000) = 1; remaining = 2; dynamic = ceil(2 * 1e18 /
        // 2e18) = ceil(1) = 1; sum = 2.
        _setPaxgXauPrice(2e18);
        assertEq(_fee(3), 2);
    }

    /// @notice A larger order shows the dynamic round-up alongside a nonzero fixed fee.
    function testFeeWithNonzeroFixedComponent() external {
        // amount = 3000 wei, p = 2.0: fixed = ceil(3000 * 10 / 10_000) = 3; remaining = 2997; dynamic =
        // ceil(2997 * 1e18 / 2e18) = ceil(1498.5) = 1499; sum = 1502 < amount.
        _setPaxgXauPrice(2e18);
        assertEq(_fee(3000), 1502);
    }

    /// @notice A stale oracle reverts the fee calculation (which reverts the whole processOrders batch).
    function testStaleOracleReverts() external {
        _setPaxgXauPrice(1.02e18);
        xauUsdFeed.setUpdatedAt(NOW - MAX_STALE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(PaxgXauRateProvider.MaxTimeFromLastUpdatePassed.selector, NOW, NOW - MAX_STALE - 1)
        );
        _fee(100e18);
    }

    /// @notice For a normal-sized order, even an extreme premium leaves the fee strictly below the amount.
    function testFeeBelowAmountAtExtremePremium() external {
        _setPaxgXauPrice(100e18); // PAXG priced at 100 XAU (absurd, for bound-checking)
        uint256 fee = _fee(100e18);
        // fixed = 0.1e18; remaining = 99.9e18; dynamic = 99.9e18 * 99/100 = 98.901e18  =>  99.001e18, still
        // below the 100e18 amount.
        assertEq(fee, _expectedFee(100e18, 100e18));
        assertEq(fee, 99.001e18);
        assertLt(fee, 100e18);
    }

    /// @notice Because the fixed fee is taken first and the dynamic fee is levied only on the remainder, the
    /// total stays strictly below the amount at any finite premium — the fixed fee always carves out a slice
    /// the dynamic fee can never reach. This is the invariant that lets the module omit an explicit cap.
    function testFeeBelowAmountAtHugePremium() external {
        // p = 1000: fixed = 0.1e18; remaining = 99.9e18; dynamic = 99.9e18 * 999/1000 = 99.8001e18;
        // sum = 99.9001e18 < 100e18.
        _setPaxgXauPrice(1000e18);
        uint256 fee = _fee(100e18);
        assertEq(fee, 99.9001e18);
        assertLt(fee, 100e18);
    }

    /// @notice On dust orders the fixed fee's round-up can consume most or all of the amount, but because the
    /// dynamic fee is levied only on the remainder the total never exceeds the amount without any cap.
    /// WithdrawQueue.minimumOrderSize rejects such orders on submission, so this is unreachable in a real
    /// deployment; it is pinned here purely to document the sequential-fee and rounding math.
    function testDustOrderFeeBoundedByAmount() external {
        _setPaxgXauPrice(2e18); // dynamic fraction 0.5
        // amount = 1 wei: fixed ceil(1 * 10 / 10_000) = 1, remaining = 0, dynamic = 0, sum = 1 == amount.
        assertEq(_fee(1), 1);
        // amount = 2 wei: fixed ceil(2 * 10 / 10_000) = 1, remaining = 1, dynamic ceil(1e18/2e18) = 1, sum = 2
        // == amount.
        assertEq(_fee(2), 2);
    }

    /// @notice Fee never exceeds the order amount for any in-range price, is always positive (the fixed fee
    /// guarantees it), and collapses to just the fixed component at/below peg.
    /// @dev The lower bound is 0.01e18 (1% of peg), not near-zero: _setPaxgXauPrice derives the PAXG/USD
    /// feed answer as price * 3400e8 / 1e18, which floors to 0 for price < ~2.94e6, and the oracle now
    /// rejects a non-positive answer with InvalidPrice. 0.01e18 stays well clear of that floor while still
    /// exercising the at/below-peg (fixed-fee-only) branch.
    function testFuzzFeeBounds(uint256 amount, uint256 price) external {
        amount = bound(amount, 1, 1e30);
        price = bound(price, 0.01e18, 1000e18); // PAXG:XAU in [0.01, 1000]
        _setPaxgXauPrice(price);

        // The mock derives paxgUsd = price * 3400e8 / 1e18, which floors; recover the actual on-chain price
        // the oracle reports so the reference impl matches exactly.
        uint256 onchainPrice = module.RATE_PROVIDER().getRate();

        uint256 fee = _fee(amount);
        assertEq(fee, _expectedFee(amount, onchainPrice));
        // <= not <: rounding up plus the fixed fee can lift the fee to exactly the amount (or the cap binds).
        assertLe(fee, amount);
        // The fixed fee (bps > 0) makes the fee strictly positive for any order of at least 1 wei.
        assertGt(fee, 0);
        if (onchainPrice <= PEG_PRICE) {
            // Dynamic component is zero, so the fee is exactly the (capped) fixed fee.
            uint256 fnum = amount * FIXED_FEE_BPS;
            uint256 expectedFixed = fnum / BPS_DIVISOR + (fnum % BPS_DIVISOR == 0 ? 0 : 1);
            if (expectedFixed > amount) expectedFixed = amount;
            assertEq(fee, expectedFixed);
        }
    }

}
