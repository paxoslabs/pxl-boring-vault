// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";

import { Pausable } from "src/helper/Pausable.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";

/**
 * @title PaxgyStablecoinDepositor
 * @notice Order helper attached to a dedicated offer-receiver {BoringVault}. Accepts user stablecoin deposits against a
 *         backend-signed {Quote} pending an off-chain conversion, then delivers PAXGy (BoringVault shares) to the
 *         quote's receiver on the depositor's behalf.
 * @dev This contract owns the order bookkeeping for the PAXGy stablecoin deposit flow but does NOT custody any funds:
 *      on submission the stablecoins are transferred immediately into the {offerReceiver}, a dedicated {BoringVault}
 *      that holds funds in flight to Paxos. A permissioned strategist converts the staged stablecoins to PAXGy
 *      off-chain (via Paxos); to fill an order, the calling vault provides both the fill's PAXGy and the unfilled
 *      offer asset, which this contract pulls straight to the receiver. Orders are independent: each is acted on by
 *      its id, so a single failing order never blocks the others.
 *
 *      Signed-quote model (mirrors {TransitStation}):
 *        - Order terms are priced off-chain and EIP-712 signed by the trusted {quoteSigner}. A {Quote} is a bearer
 *          instrument: whoever submits it funds the offer, and the eventual PAXGy (or a refund) goes to the quote's
 *          `receiver`.
 *        - An order's uuid is the EIP-712 digest of its quote, used directly as the order id, so it is fully
 *          determined by the signed terms and identical no matter who submits it. The `salt` field gives
 *          otherwise-identical quotes distinct uuids.
 *        - {usedUuids} is a permanent ledger: a uuid is marked used on submission and never cleared, so a given quote
 *          can be submitted at most once — even after its order record is deleted on fulfillment/refund.
 *        - Two on-chain checks limit a compromised signer: {isStablecoinSupported} only accepts approved
 *          stablecoins, and a price floor (via {paxgyUsdRateProvider}) rejects any order that sells PAXGy below
 *          its oracle price.
 *
 *      The transfer of staged stablecoins to the fixed Paxos deposit address is performed OUTSIDE this contract,
 *      while the order is live, by the strategist via the {offerReceiver} vault's {ManagerWithMerkleVerification}
 *      (which enforces the permitted destination via its merkle root).
 *
 *      Roles are enforced by the configured {Authority}. The intended wiring is:
 *        - submitter        -> {submitOrder}/{submitOrderWithPermit}.
 *        - STRATEGIST role  -> {settleOrder}.
 *        - PAUSER role      -> {pause}; ADMIN role/owner -> {unpause}.
 *        - ADMIN role/owner -> all config setters.
 *      The owner is always authorized (see solmate {Auth}).
 * @custom:security-contact security@paxoslabs.com
 */
contract PaxgyStablecoinDepositor is Auth, Pausable {

    using SafeTransferLib for ERC20;
    using SafeCast for uint256;
    using FixedPointMathLib for uint256;

    // ========================================= TYPES =========================================

    /**
     * @notice Backend-priced deposit terms, EIP-712 signed by {quoteSigner}. Bearer instrument: anyone may submit a
     *         valid quote (they pay the offer amount; the eventual PAXGy goes to the quote's `receiver`). Amounts are
     *         in the offer asset's own decimals.
     * @param offerAsset The stablecoin to deposit.
     * @param offerAmount The stablecoin amount to stage for conversion.
     * @param wantAmount PAXGy wanted for a full fill. Together with `offerAmount` this sets the quote's
     *        stablecoin:PAXGy rate, which prices partial fills, and it is the PAXGy a full fill must deliver.
     * @param receiver Beneficiary of the order: recipient of the PAXGy (or of a refund).
     * @param deadline Unix timestamp after which the quote may no longer be submitted.
     * @param fillOrKill If true, the order rejects partial fills: {settleOrder} must either fill it in full or refund
     *        it in full.
     * @param salt Entropy so otherwise-identical quotes get distinct uuids.
     */
    struct Quote {
        ERC20 offerAsset;
        uint256 offerAmount;
        uint256 wantAmount;
        address receiver;
        uint256 deadline;
        bool fillOrKill;
        bytes32 salt;
    }

    /**
     * @notice A single live delayed stablecoin deposit order. Exists from submission until fulfilled or refunded, when
     *         it is deleted.
     * @param offerAmount Stablecoin amount staged for this order, in the stablecoin's own decimals. The unfilled
     *        portion is returned on settlement.
     * @param wantAmount PAXGy wanted for a full fill. With `offerAmount` it sets the stablecoin:PAXGy rate that
     *        prices partial fills in {settleOrder}.
     * @param offerAsset The stablecoin deposited for this order. A zero value marks a non-existent (never-created or
     *        already-resolved) order.
     * @param receiver The beneficiary from the signed quote: recipient of the PAXGy on fulfillment or the refunded
     *        stablecoin on refund.
     * @param fillOrKill If true, {settleOrder} rejects a partial fill: it must fully fill or fully refund the order.
     */
    struct Order {
        uint128 offerAmount;
        uint128 wantAmount;
        ERC20 offerAsset;
        address receiver;
        bool fillOrKill;
    }

    // ========================================= CONSTANTS =========================================

    // EIP-712 type hashes. The domain separator is hand-rolled (OZ's EIP712 base pulls in StorageSlot which needs
    // solc >=0.8.24, and this repo pins 0.8.21). Recomputed live in {_domainSeparator}, so it is fork-safe.
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(address offerAsset,uint256 offerAmount,uint256 wantAmount,address receiver,uint256 deadline,bool fillOrKill,bytes32 salt)"
    );

    /// @notice Basis-points denominator used for the price floor slippage calculation.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ========================================= IMMUTABLES =========================================

    /// @notice The dedicated offer-receiver that custodies deposited stablecoins.
    address public immutable offerReceiver;

    /// @notice The PAXGy token delivered to fill orders, pulled from the calling vault to the beneficiary.
    ERC20 public immutable paxgy;

    /// @notice Cached `paxgy.decimals()`, used to scale the oracle price floor without re-reading it per order.
    uint8 public immutable paxgyDecimals;

    /// @notice Oracle reporting the USD price of one PAXGy share; anchors the on-chain price floor.
    IRateProvider public immutable paxgyUsdRateProvider;

    /// @notice Decimal precision of {paxgyUsdRateProvider}'s reported USD-per-PAXGy rate. The price floor math depends
    ///         on it, so it must match the provider's actual output precision.
    uint8 public immutable RATE_PROVIDER_DECIMALS;

    // ========================================= STATE =========================================

    /// @notice Trusted backend key; every submitted {Quote} must carry its EIP-712 signature.
    address public quoteSigner;

    /// @notice Permanent replay ledger: whether a uuid (quote digest) has ever been submitted. Never cleared.
    mapping(uint256 => bool) public usedUuids;

    /// @notice Whether a stablecoin is accepted for new orders.
    mapping(ERC20 => bool) public isStablecoinSupported;

    /// @notice Live order data, keyed by order id: the uint256 of the quote's EIP-712 digest, which is also its uuid.
    ///         Deleted on settlement.
    mapping(uint256 => Order) public orders;

    /// @notice How far below oracle fair value an order may be priced, in basis points. Defaults to 0 (strict floor).
    uint256 public maxSlippageBps;

    // ========================================= EVENTS =========================================

    event OrderSubmitted(uint256 indexed orderId, address indexed depositor, address indexed receiver, Quote quote);

    /// @dev Emitted when an order is settled and deleted. `fillAmount` is the PAXGy delivered to the beneficiary and
    ///      `refundAmount` the offer asset returned for the unfilled portion; a pure fill or pure refund zeroes the
    ///      unused side.
    event OrderSettled(uint256 indexed orderId, address indexed beneficiary, uint256 fillAmount, uint256 refundAmount);

    event QuoteSignerSet(address indexed signer);
    event StablecoinSupportSet(ERC20 indexed stablecoin, bool supported);
    event ERC20Rescued(ERC20 indexed token, address indexed to, uint256 amount);
    event MaxSlippageSet(uint256 bps);

    // ========================================= ERRORS =========================================

    error ZeroAddress();
    error StablecoinNotSupported(ERC20 stablecoin);
    error QuoteExpired(uint256 deadline);
    error InvalidSigner(address recoveredSigner);
    error UuidAlreadyUsed(uint256 orderId);
    error OrderNotFound(uint256 orderId);
    error PermitFailedAndAllowanceTooLow();
    error ZeroWantAmount();
    error FillExceedsOrder(uint256 fillAmount, uint256 wantAmount);
    error RefundMismatch(uint256 expectedRefund, uint256 refundAmount);
    error PartialFillNotAllowed(uint256 fillAmount, uint256 wantAmount);
    error PriceBelowFloor(uint256 offerAmount, uint256 minOffer);
    error MaxSlippageTooHigh(uint256 bps, uint256 maxBps);
    error ArrayLengthMismatch(uint256 orderIdsLength, uint256 fillAmountsLength, uint256 refundAmountsLength);

    // ========================================= CONSTRUCTOR =========================================

    /**
     * @param _offerReceiver The dedicated offer-receiver vault (a {BoringVault}) that custodies staged stablecoins for
     *        this flow. Typed as `address` since only plain transfers are made to/from it.
     * @param _paxgy The PAXGy token delivered to fill orders.
     * @param _quoteSigner The trusted backend key that signs {Quote}s.
     * @param _paxgyUsdRateProvider Oracle reporting USD per PAXGy; anchors the on-chain price floor.
     * @param _rateProviderDecimals Decimal precision of `_paxgyUsdRateProvider`'s rate; must match its actual output.
     * @param _owner Initial owner (always authorized).
     */
    constructor(
        address _offerReceiver,
        ERC20 _paxgy,
        address _quoteSigner,
        IRateProvider _paxgyUsdRateProvider,
        uint8 _rateProviderDecimals,
        address _owner
    )
        Auth(_owner, Authority(address(0)))
    {
        if (_owner == address(0)) revert ZeroAddress();
        if (_offerReceiver == address(0)) revert ZeroAddress();
        if (address(_paxgy) == address(0)) revert ZeroAddress();
        if (_quoteSigner == address(0)) revert ZeroAddress();
        if (address(_paxgyUsdRateProvider) == address(0)) revert ZeroAddress();

        offerReceiver = _offerReceiver;
        paxgy = _paxgy;
        paxgyDecimals = _paxgy.decimals();
        quoteSigner = _quoteSigner;
        paxgyUsdRateProvider = _paxgyUsdRateProvider;
        RATE_PROVIDER_DECIMALS = _rateProviderDecimals;

        emit QuoteSignerSet(_quoteSigner);
    }

    // ========================================= ADMIN: CONFIG =========================================

    /**
     * @notice Rotate the trusted quote signer.
     * @dev Highest-stakes setter: the signer authorizes every order's terms. On-chain backstops still bound what a
     *      new (or compromised) signer can do.
     * @param signer New signer.
     */
    function setQuoteSigner(address signer) external requiresAuth {
        if (signer == address(0)) revert ZeroAddress();
        quoteSigner = signer;
        emit QuoteSignerSet(signer);
    }

    /**
     * @notice Enable or disable a supported stablecoin for new orders.
     * @dev Set `supported` to false to stop accepting new orders for the asset. Existing orders are unaffected and can
     *      still be fulfilled or refunded. This allowlist is an on-chain backstop on top of the signed quote.
     * @param stablecoin The stablecoin to configure.
     * @param supported Whether new orders may be submitted for it.
     */
    function setStablecoinSupported(ERC20 stablecoin, bool supported) external requiresAuth {
        if (address(stablecoin) == address(0)) revert ZeroAddress();
        isStablecoinSupported[stablecoin] = supported;
        emit StablecoinSupportSet(stablecoin, supported);
    }

    /**
     * @notice Set the max slippage below oracle fair value an order may be priced at, in basis points.
     * @dev 0 is a strict floor; the knob only ever loosens it, up to {BPS_DENOMINATOR} (100%, which disables it).
     * @param bps New max slippage in basis points.
     */
    function setMaxSlippageBps(uint256 bps) external requiresAuth {
        if (bps > BPS_DENOMINATOR) revert MaxSlippageTooHigh(bps, BPS_DENOMINATOR);
        maxSlippageBps = bps;
        emit MaxSlippageSet(bps);
    }

    /**
     * @notice Rescue tokens sent to or stuck in this contract. Admin-gated.
     * @dev Does not reconcile against outstanding orders; the admin is trusted not to remove funds owed to live
     *      orders. Staged stablecoins are held in {offerReceiver}, not here, so this cannot touch them.
     */
    function rescueERC20(ERC20 token, address to, uint256 amount) external requiresAuth {
        if (address(token) == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    // ========================================= EMERGENCY =========================================

    /**
     * @notice Emergency stop: halts new submissions ({submitOrder}, {submitOrderWithPermit}) and the fill leg of
     *         {settleOrder} so a compromised signer or strategist can be frozen before more orders land or fill.
     * @dev A refund-only settlement ({settleOrder} with `fillAmount == 0`) stays callable while paused so staged funds
     *      can always be unwound.
     */
    function pause() external requiresAuth {
        _pause();
    }

    /// @notice Resume submissions and fills after a pause.
    function unpause() external requiresAuth {
        _unpause();
    }

    // ========================================= EXTERNAL: USER =========================================

    /**
     * @notice Submit a backend-signed quote: moves the stablecoin into {offerReceiver} and records a live order whose
     *         beneficiary is the quote's `receiver`. The order id is the quote's EIP-712 digest (uuid).
     * @dev Gated by {requiresAuth} so access can be scoped at deploy, but the signed quote is the substantive
     *      gate. No on-chain fee is taken; any spread or fee is priced into the signed quote's rate.
     * @param quote Backend-priced deposit terms. See {Quote}.
     * @param signature EIP-712 signature over `quote` by {quoteSigner}.
     * @return orderId The id of the created order (also the quote uuid).
     */
    function submitOrder(
        Quote calldata quote,
        bytes calldata signature
    )
        external
        requiresAuth
        whenNotPaused
        returns (uint256 orderId)
    {
        orderId = _submitOrder(quote, signature);
    }

    /**
     * @notice Same as {submitOrder} but consumes an EIP-2612 permit first, so approve + submit happen in one tx.
     * @dev A failed permit (already approved / front-run) falls back to an allowance check rather than reverting.
     * @param quote Backend-priced deposit terms. See {Quote}.
     * @param signature EIP-712 signature over `quote` by {quoteSigner}.
     * @param permitDeadline Permit expiry.
     * @param v Permit signature component.
     * @param r Permit signature component.
     * @param s Permit signature component.
     * @return orderId The id of the created order (also the quote uuid).
     */
    function submitOrderWithPermit(
        Quote calldata quote,
        bytes calldata signature,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        requiresAuth
        whenNotPaused
        returns (uint256 orderId)
    {
        // solhint-disable-next-line no-empty-blocks
        try quote.offerAsset.permit(msg.sender, address(this), quote.offerAmount, permitDeadline, v, r, s) { }
        catch {
            if (quote.offerAsset.allowance(msg.sender, address(this)) < quote.offerAmount) {
                revert PermitFailedAndAllowanceTooLow();
            }
        }
        orderId = _submitOrder(quote, signature);
    }

    // ========================================= EXTERNAL: STRATEGIST =========================================

    /**
     * @notice Settle one or more orders in a single call: for each, fill part or all of it by delivering PAXGy to the
     *         beneficiary, refund the offer asset for whatever is unfilled, and delete the order.
     * @dev Strategist-gated. The three arrays are parallel: index `i` settles `orderIds[i]` with `fillAmounts[i]` and
     *      `refundAmounts[i]`. Settlement is atomic — any single entry that reverts (unknown order, bad refund,
     *      disallowed partial fill, or a fill while paused) reverts the whole call. Batching lets one manager batch's
     *      approvals cover every fill/refund at once.
     *
     *      Per order, the fill is priced at the quote's stablecoin:PAXGy rate (`offerAmount`:`wantAmount`), and the
     *      refund must be exactly the unfilled remainder:
     *
     *          offerAmountFilled = ceil(fillAmount * offerAmount / wantAmount)
     *          require: refundAmount == offerAmount - offerAmountFilled
     *
     *      The filled amount rounds up, so the refund rounds down by at most one unit and any dust stays in the vault.
     *      Both legs pull from the caller: `fillAmount` PAXGy on the fill and `refundAmount` of the offer asset on the
     *      refund, each straight to the beneficiary. The vault must have approved this contract for both in the same
     *      manager batch. While paused, only refunds are allowed (`fillAmount == 0`) so open orders can still be
     *      unwound.
     *
     *      If an order was submitted fill-or-kill, its `fillAmount` must be either `wantAmount` (full fill) or 0 (full
     *      refund); a partial fill reverts.
     * @param orderIds The orders to settle.
     * @param fillAmounts PAXGy to deliver per order; each must not exceed its order's `wantAmount`. 0 for a pure
     *        refund.
     * @param refundAmounts Offer asset to refund per order; each must equal that order's exact unfilled remainder.
     */
    function settleOrder(
        uint256[] calldata orderIds,
        uint256[] calldata fillAmounts,
        uint256[] calldata refundAmounts
    )
        external
        requiresAuth
    {
        if (orderIds.length != fillAmounts.length || orderIds.length != refundAmounts.length) {
            revert ArrayLengthMismatch(orderIds.length, fillAmounts.length, refundAmounts.length);
        }

        for (uint256 i = 0; i < orderIds.length; ++i) {
            uint256 orderId = orderIds[i];
            uint256 fillAmount = fillAmounts[i];
            uint256 refundAmount = refundAmounts[i];

            Order memory order = orders[orderId];
            if (address(order.offerAsset) == address(0)) revert OrderNotFound(orderId);

            // Fills are frozen while paused; refunds stay open so staged funds can always be unwound.
            if (fillAmount != 0 && paused()) revert EnforcedPause();

            // wantAmount is nonzero for any live order, so bounding fillAmount by it keeps the division below safe and
            // the refund subtraction from underflowing.
            if (fillAmount > order.wantAmount) revert FillExceedsOrder(fillAmount, order.wantAmount);

            if (order.fillOrKill && fillAmount != 0 && fillAmount != order.wantAmount) {
                revert PartialFillNotAllowed(fillAmount, order.wantAmount);
            }

            // Round the fill UP so any sub-unit dust stays in the vault instead of inflating the beneficiary's refund.
            uint256 offerAmountFilled = fillAmount.mulDivUp(order.offerAmount, order.wantAmount);
            uint256 expectedRefund = order.offerAmount - offerAmountFilled;
            if (refundAmount != expectedRefund) revert RefundMismatch(expectedRefund, refundAmount);

            address beneficiary = order.receiver;

            // Delete the record before the external transfers below, so a reentrant call sees no live order.
            delete orders[orderId];

            if (fillAmount != 0) {
                paxgy.safeTransferFrom(msg.sender, beneficiary, fillAmount);
            }
            if (refundAmount != 0) {
                order.offerAsset.safeTransferFrom(msg.sender, beneficiary, refundAmount);
            }

            emit OrderSettled(orderId, beneficiary, fillAmount, refundAmount);
        }
    }

    // ========================================= VIEW =========================================

    /**
     * @notice Return the live order struct for `orderId` (zeroed if it does not exist).
     * @param orderId The order id to look up.
     * @return The stored order, or a zeroed struct if none exists.
     */
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /**
     * @notice The order id (uuid) a given quote would produce: its EIP-712 digest as a uint256. Lets off-chain
     *         callers predict the id before submission.
     * @param quote The quote to derive the id for.
     * @return The order id (also the quote uuid).
     */
    function quoteOrderId(Quote calldata quote) external view returns (uint256) {
        return uint256(_hashTypedData(quote));
    }

    /**
     * @notice EIP-712 hashStruct of `quote`.
     * @param quote The quote to hash.
     * @return The EIP-712 hashStruct.
     */
    function hashQuote(Quote calldata quote) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                address(quote.offerAsset),
                quote.offerAmount,
                quote.wantAmount,
                quote.receiver,
                quote.deadline,
                quote.fillOrKill,
                quote.salt
            )
        );
    }

    // ========================================= INTERNAL =========================================

    /**
     * @dev Shared submit core. Verifies the signed quote and its on-chain backstops, derives the uuid from the quote
     *      digest, marks it used and records the live order (the replay-critical effects) before any external call,
     *      then stages the stablecoin in {offerReceiver}.
     */
    function _submitOrder(Quote calldata quote, bytes calldata signature) internal returns (uint256 orderId) {
        if (block.timestamp > quote.deadline) revert QuoteExpired(quote.deadline);

        // On-chain backstops (defense-in-depth against a compromised quoteSigner).
        if (!isStablecoinSupported[quote.offerAsset]) revert StablecoinNotSupported(quote.offerAsset);
        if (quote.receiver == address(0)) revert ZeroAddress();
        if (quote.wantAmount == 0) revert ZeroWantAmount(); // wantAmount sets the price, so it must be nonzero
        _enforcePriceFloor(quote.offerAsset, quote.offerAmount, quote.wantAmount);

        // Verify the quote is signed by the trusted backend; the digest doubles as the uuid / order id.
        bytes32 digest = _hashTypedData(quote);
        address signer = ECDSA.recover(digest, signature);
        if (signer != quoteSigner) revert InvalidSigner(signer);

        orderId = uint256(digest);
        // Replay guard: mark the uuid used forever. Checked before the order record so a resubmit reverts even after
        // the prior order was settled (and its record deleted).
        if (usedUuids[orderId]) revert UuidAlreadyUsed(orderId);
        usedUuids[orderId] = true;

        // Record the order before the external transfer below, so a reentrant call sees the live order.
        orders[orderId] = Order({
            offerAmount: quote.offerAmount.toUint128(),
            wantAmount: quote.wantAmount.toUint128(),
            offerAsset: quote.offerAsset,
            receiver: quote.receiver,
            fillOrKill: quote.fillOrKill
        });

        quote.offerAsset.safeTransferFrom(msg.sender, offerReceiver, quote.offerAmount);

        emit OrderSubmitted(orderId, msg.sender, quote.receiver, quote);
    }

    /**
     * @dev Reverts unless the order prices PAXGy within {maxSlippageBps} bps of its oracle-derived price.
     *      Offer stablecoins are treated as pegged to $1.
     */
    function _enforcePriceFloor(ERC20 offerAsset, uint256 offerAmount, uint256 wantAmount) internal view {
        uint256 paxgyUsd = paxgyUsdRateProvider.getRate(); // USD per 1 PAXGy, at RATE_PROVIDER_DECIMALS precision

        // Each step rounds UP so the required offer is never understated, making the floor harder to clear.
        uint256 stablePerPaxgy = paxgyUsd.mulDivUp(10 ** offerAsset.decimals(), 10 ** RATE_PROVIDER_DECIMALS);
        uint256 fairOffer = wantAmount.mulDivUp(stablePerPaxgy, 10 ** paxgyDecimals);
        uint256 minOffer = fairOffer.mulDivUp(BPS_DENOMINATOR - maxSlippageBps, BPS_DENOMINATOR);

        if (offerAmount < minOffer) revert PriceBelowFloor(offerAmount, minOffer);
    }

    /// @dev Full EIP-712 digest (`0x1901 || domainSeparator || hashStruct`) of `quote`.
    function _hashTypedData(Quote calldata quote) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(), hashQuote(quote)));
    }

    /// @dev EIP-712 domain separator, computed live (reads `block.chainid`) so it is fork-safe.
    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("PaxgyStablecoinDepositor")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

}
