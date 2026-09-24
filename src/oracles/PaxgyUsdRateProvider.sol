// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IRateProvider } from "./../interfaces/IRateProvider.sol";
import { IPriceFeed } from "./../interfaces/IPriceFeed.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @notice Reports the USD price of one PAXGy share, at 18 decimals.
 * @dev Composes two independent legs:
 *          PAXGy/USD = (PAXGy/XAU from the vault Accountant) x (XAU/USD from Chainlink)
 */
contract PaxgyUsdRateProvider is IRateProvider {

    using SafeCast for int256;

    /// @notice Output precision. PAXGy/USD is always returned at 18 decimals.
    uint8 public constant RATE_DECIMALS = 18;

    /// @notice The vault Accountant supplying the PAXGy/XAU exchange rate (in `base` units, where base stands in for
    ///         XAU).
    AccountantWithRateProviders public immutable ACCOUNTANT;

    /// @notice The Chainlink XAU/USD price feed supplying the gold leg.
    IPriceFeed public immutable XAU_USD_FEED;

    /// @notice This provider's own asset pair.
    string public constant DESCRIPTION = "PAXGy/USD";

    /// @notice Seconds since the feed's last update beyond which it is treated as stale.
    uint256 public immutable MAX_TIME_FROM_LAST_UPDATE;

    /// @notice Cached `ACCOUNTANT.decimals()`: precision of the PAXGy/XAU exchange rate.
    uint8 public immutable ACCOUNTANT_DECIMALS;

    /// @notice Chainlink USD price feeds report 8 decimals; the XAU/USD feed is required to match at construction.
    uint8 public constant CHAINLINK_DECIMALS = 8;

    error MaxTimeFromLastUpdatePassed(uint256 blockTimestamp, uint256 lastUpdated);
    error InvalidDescription();
    error InvalidPrice(int256 answer);
    error InvalidPriceFeedDecimals(uint8 priceFeedDecimals);

    /**
     * @param _description The XAU/USD feed's expected asset-pair label, e.g. "XAU/USD".
     * @param _accountant The vault Accountant reporting PAXGy priced in the XAU-standin base.
     * @param _xauUsdFeed The Chainlink XAU/USD price feed.
     * @param _maxTimeFromLastUpdate Staleness threshold, in seconds, for the XAU/USD feed.
     */
    constructor(
        string memory _description,
        AccountantWithRateProviders _accountant,
        IPriceFeed _xauUsdFeed,
        uint256 _maxTimeFromLastUpdate
    ) {
        if (!_isEqual(_description, _xauUsdFeed.description())) revert InvalidDescription();

        uint8 feedDecimals = _xauUsdFeed.decimals();
        if (feedDecimals != CHAINLINK_DECIMALS) revert InvalidPriceFeedDecimals(feedDecimals);

        ACCOUNTANT = _accountant;
        XAU_USD_FEED = _xauUsdFeed;
        MAX_TIME_FROM_LAST_UPDATE = _maxTimeFromLastUpdate;
        ACCOUNTANT_DECIMALS = _accountant.decimals();
    }

    /**
     * @notice The USD price of one PAXGy share, at {RATE_DECIMALS} (18) decimals.
     * @dev Reverts if the Accountant is paused (via `getRateSafe`), if the XAU/USD feed is stale, or
     *      if the feed answer is non-positive.
     * @return paxgyUsd USD per 1 PAXGy, scaled to 18 decimals.
     */
    function getRate() public view returns (uint256 paxgyUsd) {
        _validityCheck();

        // Vault leg: PAXGy priced in the XAU-standin base.
        uint256 paxgyPerXau = ACCOUNTANT.getRateSafe();

        // Gold leg: XAU/USD from Chainlink, with a staleness guard.
        (, int256 answer,, uint256 lastUpdatedAt,) = XAU_USD_FEED.latestRoundData();
        if (block.timestamp - lastUpdatedAt > MAX_TIME_FROM_LAST_UPDATE) {
            revert MaxTimeFromLastUpdatePassed(block.timestamp, lastUpdatedAt);
        }
        if (answer <= 0) revert InvalidPrice(answer);
        uint256 xauUsd = answer.toUint256();

        // PAXGy/USD(18) = paxgyPerXau(ACCOUNTANT_DECIMALS) * xauUsd(CHAINLINK_DECIMALS) * 1e18
        //                 / (10^ACCOUNTANT_DECIMALS * 10^CHAINLINK_DECIMALS)
        // Multiply-before-divide; magnitudes (rate ~1e18, price ~1e11) stay far below 2^256.
        paxgyUsd =
            (paxgyPerXau * xauUsd * (10 ** RATE_DECIMALS)) / (10 ** ACCOUNTANT_DECIMALS * 10 ** CHAINLINK_DECIMALS);
    }

    /**
     * @dev Hook for custom checks such as sequencer liveness; empty here, override to extend.
     */
    // solhint-disable-next-line no-empty-blocks
    function _validityCheck() internal view virtual { }

    function _isEqual(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

}
