// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IRateProvider } from "./../interfaces/IRateProvider.sol";
import { IPriceFeed } from "./../interfaces/IPriceFeed.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @notice Composite rate provider that reports the value of PAXG in terms of gold (XAU) by combining
 * two Chainlink USD price feeds: PAXG/USD and XAU/USD.
 *
 * @notice
 *  PAXG is a token backed 1:1 by one fine troy ounce of gold, and XAU/USD is the spot price of one
 *  troy ounce of gold. Neither Chainlink feed prices PAXG directly against gold, so this contract
 *  derives the cross-rate:
 *
 *      getRate() = XAU per PAXG = (PAXG/USD) / (XAU/USD)
 *
 *  The USD numeraire cancels, leaving the number of troy ounces of gold that one PAXG token is
 *  worth (nominally ~1.0). Because both underlying feeds report USD prices with the same precision,
 *  the multiplication that would naively combine them (PAXG/USD * XAU/USD) has no meaningful unit;
 *  the composite is a ratio, not a product.
 *
 * @dev Implements {IRateProvider} so it can be registered on an accountant via `setRateProviderData`.
 * Both feeds must be Chainlink-compatible (validated by `description()`) and report 8 decimals, which
 * is the Chainlink convention for USD-denominated feeds.
 * @custom:security-contact security@molecularlabs.io
 */
contract PaxgXauRateProvider is IRateProvider {

    using SafeCast for int256;

    error MaxTimeFromLastUpdatePassed(uint256 blockTimestamp, uint256 lastUpdated);
    error InvalidPriceFeedDecimals(uint8 priceFeedDecimals);
    error InvalidDescription();
    error InvalidPrice(int256 price);

    /**
     * @notice The description of the PAXG/USD price feed. ex) PAXG / USD
     */
    string public DESCRIPTION_PaxgUsdFeed;

    /**
     * @notice The description of the XAU/USD price feed. ex) XAU / USD
     */
    string public DESCRIPTION_XauUsdFeed;

    /**
     * @notice The Chainlink price feed that returns the value of PAXG in USD denomination.
     * @dev This is the numerator of the cross-rate.
     */
    IPriceFeed public immutable PAXG_USD_FEED;

    /**
     * @notice The Chainlink price feed that returns the value of gold (XAU) in USD denomination.
     * @dev This is the denominator of the cross-rate.
     */
    IPriceFeed public immutable XAU_USD_FEED;

    /**
     * @notice Number of seconds since last update to determine whether either price feed is stale.
     */
    uint256 public immutable MAX_TIME_FROM_LAST_UPDATE;

    /**
     * @notice The precision of the rate returned by this contract.
     * @dev Set to the decimals of the PAXG token this rate is denominated against (18), read from the
     * token at construction rather than parameterized so it cannot be misconfigured.
     */
    uint8 public immutable RATE_DECIMALS;

    /**
     * @notice Chainlink USD price feeds report 8 decimals.
     */
    uint8 public constant CHAINLINK_DECIMALS = 8;

    /**
     * @param _descriptionPaxgUsdFeed The PAXG/USD feed asset pair. ex) PAXG / USD
     * @param _descriptionXauUsdFeed The XAU/USD feed asset pair. ex) XAU / USD
     * @param _paxgToken The PAXG token whose decimals define the precision of the returned rate.
     * @param _paxgUsdFeed The Chainlink PAXG/USD price feed.
     * @param _xauUsdFeed The Chainlink XAU/USD price feed.
     * @param _maxTimeFromLastUpdate The staleness threshold applied to both feeds, in seconds.
     */
    constructor(
        string memory _descriptionPaxgUsdFeed,
        string memory _descriptionXauUsdFeed,
        ERC20 _paxgToken,
        IPriceFeed _paxgUsdFeed,
        IPriceFeed _xauUsdFeed,
        uint256 _maxTimeFromLastUpdate
    ) {
        if (!_isEqual(_descriptionPaxgUsdFeed, _paxgUsdFeed.description())) revert InvalidDescription();
        if (!_isEqual(_descriptionXauUsdFeed, _xauUsdFeed.description())) revert InvalidDescription();

        uint8 _priceFeedDecimals = _paxgUsdFeed.decimals();
        if (_priceFeedDecimals != CHAINLINK_DECIMALS) revert InvalidPriceFeedDecimals(_priceFeedDecimals);

        _priceFeedDecimals = _xauUsdFeed.decimals();
        if (_priceFeedDecimals != CHAINLINK_DECIMALS) revert InvalidPriceFeedDecimals(_priceFeedDecimals);

        DESCRIPTION_PaxgUsdFeed = _descriptionPaxgUsdFeed;
        DESCRIPTION_XauUsdFeed = _descriptionXauUsdFeed;
        PAXG_USD_FEED = _paxgUsdFeed;
        XAU_USD_FEED = _xauUsdFeed;
        MAX_TIME_FROM_LAST_UPDATE = _maxTimeFromLastUpdate;
        RATE_DECIMALS = _paxgToken.decimals();
    }

    /**
     * @notice Gets the value of PAXG in terms of gold (XAU per PAXG).
     * @return rate The number of troy ounces of gold one PAXG token is worth, scaled to RATE_DECIMALS.
     */
    function getRate() public view returns (uint256 rate) {
        _validityCheck();

        (, int256 _xauUsd,, uint256 lastUpdatedAtXau,) = XAU_USD_FEED.latestRoundData();
        if (block.timestamp - lastUpdatedAtXau > MAX_TIME_FROM_LAST_UPDATE) {
            revert MaxTimeFromLastUpdatePassed(block.timestamp, lastUpdatedAtXau);
        }
        // A non-positive answer is invalid data: the toUint256() cast below would reject a negative value,
        // and a zero denominator (xau leg) would divide by zero while a zero numerator (paxg leg) would
        // silently zero the rate. Reject both feeds explicitly before casting.
        if (_xauUsd <= 0) revert InvalidPrice(_xauUsd);

        (, int256 _paxgUsd,, uint256 lastUpdatedAtPaxg,) = PAXG_USD_FEED.latestRoundData();
        if (block.timestamp - lastUpdatedAtPaxg > MAX_TIME_FROM_LAST_UPDATE) {
            revert MaxTimeFromLastUpdatePassed(block.timestamp, lastUpdatedAtPaxg);
        }
        if (_paxgUsd <= 0) revert InvalidPrice(_paxgUsd);

        // Both feeds report USD prices with CHAINLINK_DECIMALS precision, so the USD numeraire and the
        // shared feed precision cancel. Multiply before dividing to preserve precision.
        // rate(RATE_DECIMALS) = paxgUsd(8) * 10^RATE_DECIMALS / xauUsd(8)
        rate = (_paxgUsd.toUint256() * (10 ** RATE_DECIMALS)) / _xauUsd.toUint256();
    }

    /**
     * @dev To revert upon custom checks such as sequencer liveness.
     */
    // solhint-disable-next-line no-empty-blocks
    function _validityCheck() internal view virtual { }

    function _isEqual(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

}
