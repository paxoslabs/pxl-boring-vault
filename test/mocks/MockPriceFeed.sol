// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IPriceFeed } from "src/interfaces/IPriceFeed.sol";

/**
 * @notice Minimal configurable Chainlink-style price feed used to drive oracle-priced logic
 * deterministically, without relying on a live fork or RPC.
 */
contract MockPriceFeed is IPriceFeed {

    uint8 internal _decimals;
    string internal _description;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_, string memory description_, int256 answer_, uint256 updatedAt_) {
        _decimals = decimals_;
        _description = description_;
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _answer, 0, _updatedAt, 0);
    }

    function getDataFeedId() external pure returns (bytes32) {
        return bytes32(0);
    }

}
