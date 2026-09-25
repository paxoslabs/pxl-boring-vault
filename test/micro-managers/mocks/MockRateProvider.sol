// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IRateProvider } from "src/interfaces/IRateProvider.sol";

/// @notice Minimal rate provider whose USD price is settable, for exercising oracle-priced basket tokens.
/// @dev The rate is USD per whole token scaled to 18 decimals (1e18 == $1.00), matching what
///      EquivalentExchangeUManager expects. A rate of 0 lets tests exercise the zero-rate revert path.
contract MockRateProvider is IRateProvider {

    uint256 public rate;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

}
