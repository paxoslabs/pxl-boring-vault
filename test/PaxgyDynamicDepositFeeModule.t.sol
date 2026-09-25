// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PaxgyDynamicDepositFeeModule } from "src/helper/PaxgyDynamicDepositFeeModule.sol";
import { PaxgXauRateProvider } from "src/oracles/PaxgXauRateProvider.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { IPriceFeed } from "src/interfaces/IPriceFeed.sol";
import { MockPriceFeed } from "test/mocks/MockPriceFeed.sol";
import { MockToken } from "test/mocks/MockToken.sol";

contract PaxgyDynamicDepositFeeModuleTest is Test {

    uint8 internal constant FEED_DECIMALS = 8;
    uint256 internal constant PEG_PRICE = 1e18;
    uint256 internal constant MAX_STALE = 1 days;
    uint256 internal constant NOW = 1_753_000_000;

    MockPriceFeed internal paxgUsdFeed;
    MockPriceFeed internal xauUsdFeed;
    MockToken internal paxg;
    MockToken internal shares;
    PaxgXauRateProvider internal oracle;
    PaxgyDynamicDepositFeeModule internal module;

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

        module = new PaxgyDynamicDepositFeeModule(
            IRateProvider(address(oracle)), IERC20(address(paxg)), IERC20(address(shares))
        );
    }

    /// @dev Sets the PAXG:XAU market price by moving the PAXG/USD feed, holding XAU/USD at $3400.
    /// @param price PAXG:XAU price in 18-decimal fixed point (PEG_PRICE = 1.0).
    function _setPaxgXauPrice(uint256 price) internal {
        // p = paxgUsd / xauUsd  =>  paxgUsd = p * xauUsd
        paxgUsdFeed.setAnswer(int256(price * uint256(3400e8) / PEG_PRICE));
    }

    function _fee(uint256 amount) internal view returns (uint256) {
        return module.calculateOfferFees(amount, IERC20(address(paxg)), IERC20(address(shares)), address(0xBEEF));
    }

    function testConstructorRejectsZeroOracle() external {
        vm.expectRevert(PaxgyDynamicDepositFeeModule.ZeroAddress.selector);
        new PaxgyDynamicDepositFeeModule(IRateProvider(address(0)), IERC20(address(paxg)), IERC20(address(shares)));
    }

    function testConstructorRejectsZeroPaxg() external {
        vm.expectRevert(PaxgyDynamicDepositFeeModule.ZeroAddress.selector);
        new PaxgyDynamicDepositFeeModule(IRateProvider(address(oracle)), IERC20(address(0)), IERC20(address(shares)));
    }

    function testConstructorRejectsZeroShares() external {
        vm.expectRevert(PaxgyDynamicDepositFeeModule.ZeroAddress.selector);
        new PaxgyDynamicDepositFeeModule(IRateProvider(address(oracle)), IERC20(address(paxg)), IERC20(address(0)));
    }

    /// @notice PEG_PRICE must equal 10**(rate provider decimals); the fee math assumes the oracle's
    /// precision, so a mismatch would silently mis-scale every fee. Decimals are read from the provider.
    function testPegPriceMatchesRateProviderDecimals() external view {
        assertEq(module.PEG_PRICE(), 10 ** uint256(oracle.RATE_DECIMALS()));
    }

    /// @notice The constructor rejects a provider whose rate precision does not match PEG_PRICE, since the
    /// fee math compares getRate() directly against the 1e18 peg.
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
        vm.expectRevert(abi.encodeWithSelector(PaxgyDynamicDepositFeeModule.InvalidRateProviderDecimals.selector, 6));
        new PaxgyDynamicDepositFeeModule(
            IRateProvider(address(badOracle)), IERC20(address(paxg)), IERC20(address(shares))
        );
    }

    /// @notice A non-PAXG offer asset reverts rather than being priced.
    function testRevertsOnNonPaxgOfferAsset() external {
        MockToken other = new MockToken("Other", "OTH", 18);
        vm.expectRevert(abi.encodeWithSelector(PaxgyDynamicDepositFeeModule.InvalidOfferAsset.selector, address(other)));
        module.calculateOfferFees(1e18, IERC20(address(other)), IERC20(address(shares)), address(0xBEEF));
    }

    /// @notice A want asset other than the bound share token reverts, keeping the module to its one vault.
    function testRevertsOnNonSharesWantAsset() external {
        MockToken other = new MockToken("Other", "OTH", 18);
        vm.expectRevert(abi.encodeWithSelector(PaxgyDynamicDepositFeeModule.InvalidWantAsset.selector, address(other)));
        module.calculateOfferFees(1e18, IERC20(address(paxg)), IERC20(address(other)), address(0xBEEF));
    }

    /// @notice At peg (p = 1) the deposit fee is zero.
    function testNoFeeAtPeg() external {
        _setPaxgXauPrice(PEG_PRICE);
        assertEq(_fee(100e18), 0);
    }

    /// @notice Above peg (p > 1) the deposit fee is still zero — pegged valuation already favors the vault.
    function testNoFeeAbovePeg() external {
        _setPaxgXauPrice(1.05e18);
        assertEq(_fee(100e18), 0);
    }

    /// @notice Below peg the fee is the shortfall (1 - p), taken in PAXG, so the depositor is credited min(1, p).
    function testFeeBelowPeg() external {
        // p = 0.98  =>  fee fraction = 2%
        _setPaxgXauPrice(0.98e18);
        // 100 PAXG * (1 - 0.98) = 2 PAXG
        assertEq(_fee(100e18), 2e18);
    }

    /// @notice The residual always rounds in the vault's favor (fee rounds up).
    function testFeeRoundsUpInVaultFavor() external {
        // Pick a price just below peg so the exact fee on a tiny amount is a sub-wei fraction.
        _setPaxgXauPrice(0.999999999999999999e18);

        // _setPaxgXauPrice moves the underlying PAXG/USD feed, and the oracle floors when deriving the
        // cross-rate, so the reported price is not the value passed above. Read it back rather than
        // restating hand arithmetic: here getRate() returns 0.999999999997058823e18, i.e. a shortfall of
        // 2_941_177 wei below peg.
        uint256 shortfall = PEG_PRICE - oracle.getRate();

        // amount = 3 wei: 3 * shortfall = 8_823_531 < 1e18, so the exact fee floors to 0 and mulDivUp
        // rounds the nonzero remainder up to 1.
        assertEq((3 * shortfall) / PEG_PRICE, 0);
        assertEq(_fee(3), 1);
    }

    /// @notice A stale oracle blocks pricing (revert propagates from the rate provider).
    function testStaleOracleReverts() external {
        _setPaxgXauPrice(0.98e18);
        xauUsdFeed.setUpdatedAt(NOW - MAX_STALE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(PaxgXauRateProvider.MaxTimeFromLastUpdatePassed.selector, NOW, NOW - MAX_STALE - 1)
        );
        _fee(100e18);
    }

    /// @notice Deep depeg drives the fee toward 100%, which the depositor path treats as blocking.
    function testDeepDepegApproachesFullFee() external {
        _setPaxgXauPrice(0.1e18); // PAXG worth ~0.1 XAU
        // fee fraction = 90%
        assertEq(_fee(100e18), 90e18);
    }

    /// @notice Fee is monotonic and never exceeds the deposit amount for any in-range price.
    /// @dev The lower bound is 0.01e18 (1% of peg), not near-zero: _setPaxgXauPrice derives the PAXG/USD
    /// feed answer as price * 3400e8 / 1e18, which floors to 0 for price < ~2.94e6, and the oracle now
    /// rejects a non-positive answer with InvalidPrice. 0.01e18 stays well clear of that floor while still
    /// exercising deep sub-peg depegs.
    function testFuzzFeeBounds(uint256 amount, uint256 price) external {
        amount = bound(amount, 1, 1e30);
        price = bound(price, 0.01e18, 3e18); // PAXG:XAU in [0.01, 3]
        _setPaxgXauPrice(price);

        uint256 fee = _fee(amount);
        assertLe(fee, amount);
        if (price >= PEG_PRICE) {
            assertEq(fee, 0);
        }
    }

}
