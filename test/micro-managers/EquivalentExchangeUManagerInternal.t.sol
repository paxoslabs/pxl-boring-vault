// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { EquivalentExchangeUManager } from "src/micro-managers/EquivalentExchangeUManager.sol";
import { BalancerVault } from "src/interfaces/BalancerVault.sol";
import { MockManagerWithVault } from "./mocks/MockManagerWithVault.sol";

/// @notice ERC20 stub whose allowance() returns a fixed value, for exercising the dangling-approval check
///         without a full token/merkle setup.
contract MockFixedAllowanceToken {

    uint256 internal immutable value;

    constructor(uint256 _value) {
        value = _value;
    }

    function allowance(address, address) external view returns (uint256) {
        return value;
    }

}

/// @notice Exposes EquivalentExchangeUManager's internal pure valuation helpers for direct testing.
contract EquivalentExchangeUManagerExternal is EquivalentExchangeUManager {

    // The UManager constructor only wires up Auth and reads manager.vault(); the pure valuation helpers
    // depend on neither, so a mock manager returning a dummy vault is sufficient.
    constructor() EquivalentExchangeUManager(address(this), address(new MockManagerWithVault(address(0)))) { }

    // Compose _unitRate with the value helpers exactly as the contract does, so the (decimals, rate) inputs
    // stay intuitive in tests while exercising the real per-unit-rate helpers. `rate` is an 18-decimal
    // price here, so its rateDecimals is NORMALIZED_DECIMALS.
    function referenceValue(uint256 balance, uint8 decimals, uint256 rate) external pure returns (uint256) {
        return _tokenAmountToReferenceValue(balance, _unitRate(rate, uint8(NORMALIZED_DECIMALS), decimals));
    }

    function referenceValueToTokenAmount(uint256 value, uint8 decimals, uint256 rate) external pure returns (uint256) {
        return _referenceValueToTokenAmount(value, _unitRate(rate, uint8(NORMALIZED_DECIMALS), decimals));
    }

    // Exposes `_unitRate` with an explicit `rateDecimals` so a test can drive it past its valid domain
    // (rateDecimals + tokenDecimals > 2 * NORMALIZED_DECIMALS) and assert it reverts.
    function unitRate(uint256 rate, uint8 rateDecimals, uint8 tokenDecimals) external pure returns (uint256) {
        return _unitRate(rate, rateDecimals, tokenDecimals);
    }

    /// @notice Exposes the internal batch calldata checks for direct testing.
    function enforceCalldataChecks(ManageCalls calldata calls) external view {
        _enforceCalldataChecks(calls);
    }

}

contract EquivalentExchangeUManagerInternal is Test {

    // Rate passed for a 1:1 token, i.e. one worth exactly one reference unit per whole token. Equal to
    // NORMALIZED_ONE (10**18).
    uint256 internal constant UNIT_RATE = 1e18;

    EquivalentExchangeUManagerExternal internal harness;

    function setUp() external {
        harness = new EquivalentExchangeUManagerExternal();
    }

    // ============================== _tokenAmountToReferenceValue: 1:1 tokens (rate == NORMALIZED_ONE)
    // ==============================

    // A 1:1 token is priced at rate == NORMALIZED_ONE, which reduces valuation to rescaling the balance to
    // 18 decimals.
    function test_ReferenceValue_UnitRateRescalesToEighteenDecimals() external view {
        assertEq(harness.referenceValue(1_000_000, 6, UNIT_RATE), 1e18);
        assertEq(harness.referenceValue(1, 6, UNIT_RATE), 1e12);
        assertEq(harness.referenceValue(1e18, 18, UNIT_RATE), 1e18);
        assertEq(harness.referenceValue(1, 18, UNIT_RATE), 1);
    }

    function test_ReferenceValue_ZeroBalanceIsZero() external view {
        assertEq(harness.referenceValue(0, 6, UNIT_RATE), 0);
        assertEq(harness.referenceValue(0, 8, 2000e18), 0);
    }

    // ============================== _tokenAmountToReferenceValue: oracle-priced tokens ==============================

    // A non-1:1 token is priced by its oracle rate (reference asset per whole token, 18-dec).
    function test_ReferenceValue_PricesByRate() external view {
        // 1 whole 8-decimal token at 2000 reference units -> 2000 units of value.
        assertEq(harness.referenceValue(1e8, 8, 2000e18), 2000e18);
        // 3 whole 18-decimal tokens at 0.50 reference units -> 1.50 units.
        assertEq(harness.referenceValue(3e18, 18, 0.5e18), 1.5e18);
        // A unit rate reproduces the 1:1-token result.
        assertEq(harness.referenceValue(1_000_000, 6, UNIT_RATE), 1e18);
    }

    // ============================== _referenceValueToTokenAmount: 1:1 tokens (rate == NORMALIZED_ONE)
    // ==============================

    // A 1:1 token (rate == NORMALIZED_ONE) rescales the value back to native units, rounding up.
    function test_ReferenceValueToTokenAmount_UnitRateRescales() external view {
        assertEq(harness.referenceValueToTokenAmount(1e18, 6, UNIT_RATE), 1_000_000);
        assertEq(harness.referenceValueToTokenAmount(1e18, 18, UNIT_RATE), 1e18);
    }

    // A non-zero value that does not divide evenly into whole native units must round up so the subsidy
    // never underestimates what is owed.
    function test_ReferenceValueToTokenAmount_UnitRateRoundsUp() external view {
        // 1.5 units of a 6-decimal token (1.5e12 normalized) must round up to 2 native units.
        assertEq(harness.referenceValueToTokenAmount(1_500_000_000_000, 6, UNIT_RATE), 2);
        // One wei above a whole unit rounds up to the next unit.
        assertEq(harness.referenceValueToTokenAmount(1e12 + 1, 6, UNIT_RATE), 2);
        // Non-zero normalized amounts below one unit round up.
        assertEq(harness.referenceValueToTokenAmount(999_999, 6, UNIT_RATE), 1);
        assertEq(harness.referenceValueToTokenAmount(100_000, 6, UNIT_RATE), 1);
        assertEq(harness.referenceValueToTokenAmount(1, 6, UNIT_RATE), 1);
    }

    // ============================== _referenceValueToTokenAmount: oracle-priced tokens ==============================

    // Converting a value to a non-1:1 token amount is the inverse of pricing, rounding up.
    function test_ReferenceValueToTokenAmount_ConvertsByRate() external view {
        // 2000 reference units at 2000/token -> 1 whole 8-decimal token.
        assertEq(harness.referenceValueToTokenAmount(2000e18, 8, 2000e18), 1e8);
        // 1.50 reference units at 0.50/token -> 3 whole 18-decimal tokens.
        assertEq(harness.referenceValueToTokenAmount(1.5e18, 18, 0.5e18), 3e18);
    }

    // Any value that does not divide evenly into whole native units must round up so the subsidy
    // never underestimates what is owed.
    function test_ReferenceValueToTokenAmount_RoundsUp() external view {
        // 1 reference unit at 3/token = 0.3333... tokens; an 18-dec token rounds the wei up.
        uint256 amount = harness.referenceValueToTokenAmount(1e18, 18, 3e18);
        assertEq(amount, 333_333_333_333_333_334); // ceil(1e36 / 3e18)
        // Re-pricing the rounded-up amount must cover at least the input value.
        assertGe(harness.referenceValue(amount, 18, 3e18), 1e18);
    }

    // ============================== round-trip property ==============================

    // Round-trip property the subsidy path relies on: converting a value to a token amount (round up) then
    // re-pricing it must never fall short of the original value, so the value invariant holds. The rate
    // range spans the 1:1 token (NORMALIZED_ONE) and sane oracle prices (0.0001 .. 1,000,000 reference units).
    function testFuzz_ReferenceValueToTokenAmount_NeverUnderCovers(
        uint256 value,
        uint8 decimals,
        uint256 rate
    )
        external
        view
    {
        decimals = uint8(bound(decimals, 0, 18));
        value = bound(value, 0, 1e30);
        rate = bound(rate, 1e14, 1e24);

        uint256 tokenAmount = harness.referenceValueToTokenAmount(value, decimals, rate);
        assertGe(harness.referenceValue(tokenAmount, decimals, rate), value);
    }

    // _unitRate is only defined for rateDecimals + tokenDecimals <= 2 * NORMALIZED_DECIMALS (36), the range
    // _checkAndValueBasket enforces. Past that the rescale exponent goes negative and the multiply underflows,
    // so there is no lossy divide path: _unitRate reverts instead of flooring.
    function test_UnitRate_RevertsAboveMaxDecimals() external {
        vm.expectRevert();
        harness.unitRate(1e18, 36, 36); // rateDecimals + tokenDecimals = 72 > 36
    }

    // ============================== _enforceCalldataChecks: flashLoan ==============================

    /// @dev Builds a single-call batch with the given target calldata; only targets/targetData are read by
    /// the checks, so the other parallel arrays are left empty.
    function _oneCall(bytes memory data) internal pure returns (EquivalentExchangeUManager.ManageCalls memory calls) {
        return _oneCallTo(address(0xBEEF), data);
    }

    /// @dev As `_oneCall`, but with an explicit target so the allowance read hits a chosen token.
    function _oneCallTo(
        address target,
        bytes memory data
    )
        internal
        pure
        returns (EquivalentExchangeUManager.ManageCalls memory calls)
    {
        calls.targets = new address[](1);
        calls.targets[0] = target;
        calls.targetData = new bytes[](1);
        calls.targetData[0] = data;
    }

    /// @notice A batch containing a Balancer flashLoan call is rejected, regardless of target, because it
    /// would open a nested manage layer the checks cannot see.
    function test_EnforceCalldataChecks_RevertsOnFlashLoan() external {
        bytes memory flashLoanData = abi.encodeWithSelector(
            BalancerVault.flashLoan.selector, address(0), new address[](0), new uint256[](0), bytes("")
        );

        vm.expectRevert(EquivalentExchangeUManager.FlashLoanInBatch.selector);
        harness.enforceCalldataChecks(_oneCall(flashLoanData));
    }

    /// @notice A benign call (neither flashLoan nor a nonzero approval) passes the checks.
    function test_EnforceCalldataChecks_AllowsBenignCall() external view {
        // transfer(address,uint256) — not flashLoan, not approve/increaseAllowance/increaseApproval.
        bytes memory data = abi.encodeWithSelector(bytes4(0xa9059cbb), address(0xCAFE), uint256(1));
        harness.enforceCalldataChecks(_oneCall(data));
    }

    /// @notice increaseApproval(address,uint256) shares approve's layout; a leftover allowance from it is
    /// caught just like approve/increaseAllowance.
    function test_EnforceCalldataChecks_RevertsOnDanglingIncreaseApproval() external {
        address token = address(new MockFixedAllowanceToken(1)); // nonzero remaining allowance => dangling
        bytes memory data = abi.encodeWithSelector(bytes4(0xd73dd623), address(0xBEEF), uint256(100));

        vm.expectRevert(EquivalentExchangeUManager.DanglingApproval.selector);
        harness.enforceCalldataChecks(_oneCallTo(token, data));
    }

    /// @notice An increaseApproval that ends at zero allowance passes.
    function test_EnforceCalldataChecks_AllowsResetIncreaseApproval() external {
        address token = address(new MockFixedAllowanceToken(0)); // allowance reset by end of batch
        bytes memory data = abi.encodeWithSelector(bytes4(0xd73dd623), address(0xBEEF), uint256(100));
        harness.enforceCalldataChecks(_oneCallTo(token, data));
    }

}
