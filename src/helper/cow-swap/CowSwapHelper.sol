// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { IGPv2Settlement } from "src/interfaces/IGPv2Settlement.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { CowSwapOrderLib } from "src/libraries/CowSwapOrderLib.sol";

/**
 * @title CowSwapHelper
 * @notice A helper contract that becomes the CoW Protocol order owner on the vault's behalf. The
 *         BoringVault calls `placeOrder` via `ManagerWithMerkleVerification`; the helper pulls the sell
 *         token in, becomes the order owner, and pre-signs the order directly. Proceeds are routed straight
 *         back to the vault via the order's `receiver`.
 * @dev Custody model: because `setPreSignature` requires `owner == msg.sender`, and the helper is the
 *      caller, the helper must be the order `owner`. The relayer therefore pulls the sell token from the
 *      *helper*, so the vault must move the sell token into the helper before settlement. The helper holds
 *      that balance for the order's whole lifetime.
 *
 *      Pricing safety: CoW settles asynchronously, so there is no post-trade balance invariant to lean on.
 *      The order's `buyAmount` is the only on-chain protection against a bad fill, validated here against a
 *      floor derived from an `IRateProvider` oracle: `buyAmount >= fairRate * sellAmount * (1 - maxSlippageBps)`.
 *
 *      Oracle security assumptions (the rate provider, its decimals, and the slippage are all caller-supplied,
 *      so this is load-bearing):
 *      - `rateProvider`, `rateDecimals`, and `maxSlippageBps` are constrained OUTSIDE this contract, by the
 *        decoder/sanitizer and merkle root that gate the vault's `placeOrder` call: the merkle tree only
 *        authorizes calls matching a vetted leaf. The decoder for `placeOrder` MUST pin the `rateProvider`,
 *        `sellToken`, and `buyToken` addresses AND the `rateDecimals` and `maxSlippageBps` values. Otherwise a
 *        strategist could pass a near-zero-rate provider, an oversized `rateDecimals` (inflating the divisor so
 *        the fair amount collapses to zero), or a 100% `maxSlippageBps` - each drives the floor to zero - and
 *        drain the sell token. NOTE the asymmetry: an address-sanitizing decoder pins the addresses by default,
 *        but `rateDecimals` and `maxSlippageBps` are numeric fields the decoder must be written to include
 *        explicitly. This contract only defends in depth (rejecting a zero rate, requiring
 *        `maxSlippageBps <= 100%`); it does NOT itself cap how loose the floor may be.
 *      - `getRate()` must return the fair price of one whole `sellToken` denominated in whole `buyToken`,
 *        scaled to `rateDecimals` fixed-point decimals, as a single positive `uint256`; `rateDecimals` must
 *        match the provider's actual scale. It must perform its own staleness and sanity checks and be
 *        unmanipulable within a block (wrap raw Chainlink feeds in an adapter such as `EthPerTokenRateProvider`).
 *        A reverting or zero-returning provider reverts the order, which is preferable to mispricing it.
 *
 *      Token assumptions: only standard, fixed-balance ERC20s are supported. Fee-on-transfer and rebasing
 *      tokens break the helper's `sellAmount`-based accounting and must be excluded via the pinned tokens.
 */
contract CowSwapHelper is Auth {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /// @notice Basis-point denominator for the slippage bound.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice The BoringVault this helper serves: the source of sell tokens and the `receiver` of proceeds.
    address public immutable boringVault;

    /// @notice CoW settlement contract this helper authorizes orders on.
    IGPv2Settlement internal immutable settlement;

    /// @notice Relayer that pulls sell tokens at settlement; the spender the helper must approve.
    address internal immutable vaultRelayer;

    /// @notice Cached EIP-712 domain separator of `settlement`, read once at deploy.
    bytes32 internal immutable domainSeparator;

    /// @notice Maximum number of seconds past `block.timestamp` that an order's `validTo` may be set to. Bounds
    /// how long a pre-signed order (and the sell-token custody it entails) can stay live, capping the window in
    /// which a stale price can still be filled. Set at deploy and adjustable by an authorized admin via
    /// `setMaxOrderValidity`; always non-zero.
    uint32 public maxOrderValidity;

    /// @notice Status of every order UID this helper has pre-signed, keyed by the packed 56-byte UID. Used for
    /// replay protection: a UID can be pre-signed at most once and cancelled at most once. See {OrderStatus}.
    mapping(bytes => OrderStatus) internal orderStatus;

    /**
     * @notice Raw order fields supplied by the strategist (via the vault). Some safety-critical fields
     *         (`receiver`, `kind`, balance kinds) are forced to safe constants when deriving order UID
     *         and so are absent here.
     * @param sellToken Token to sell.
     * @param buyToken Token to buy; proceeds are always sent to the BoringVault.
     * @param sellAmount Amount of `sellToken` to offer.
     * @param buyAmount Minimum buy amount; must satisfy the oracle-derived floor for the given provider.
     * @param validTo Order expiry (unix timestamp); must be in the future and no later than
     * `block.timestamp + maxOrderValidity`. A stale order can also be cancelled at will via `cancelOrder`.
     * @param partiallyFillable Whether the order may be filled in multiple parts. CoW enforces the same
     * `buyAmount / sellAmount` limit price on every partial fill (rounding the executed buy amount up, in the
     * vault's favor), so the oracle floor validated here protects each fill regardless of this flag; residual
     * sell tokens from an incomplete order are pulled back to the vault via `sweepToken`.
     * @param rateProvider Oracle returning the `buyToken`-per-`sellToken` rate, scaled to `rateDecimals`
     * decimals.
     * @param rateDecimals Fixed-point decimals the oracle's rate is expressed in; used as the divisor when
     * mapping the sell amount through the rate.
     * @param maxSlippageBps Tolerated slippage below the oracle's fair rate, in basis points.
     */
    struct OrderParams {
        ERC20 sellToken;
        ERC20 buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bool partiallyFillable;
        IRateProvider rateProvider;
        uint8 rateDecimals;
        uint256 maxSlippageBps;
    }

    /**
     * @notice Lifecycle state of an order UID this helper has pre-signed.
     * @param None Never placed (default).
     * @param Active Pre-signed and not yet cancelled.
     * @param Closed Cancelled.
     */
    enum OrderStatus {
        None,
        Active,
        Closed
    }

    /**
     * @notice Emitted when `placeOrder` pre-signs a new order.
     * @param sellToken Token the order sells.
     * @param buyToken Token the order buys.
     * @param sellAmount Amount of `sellToken` the order sells.
     * @param buyAmount Minimum amount of `buyToken` the order buys.
     * @param orderUid UID of the pre-signed order.
     */
    event OrderPlaced(
        address indexed sellToken, address indexed buyToken, uint256 sellAmount, uint256 buyAmount, bytes orderUid
    );

    /**
     * @notice Emitted when `cancelOrder` revokes a previously pre-signed order.
     * @param orderUid UID of the cancelled order.
     */
    event OrderCancelled(bytes orderUid);

    /**
     * @notice Emitted when `sweepToken` returns a non-zero amount of a token from the helper to the BoringVault.
     * @param token Token returned to the vault.
     * @param amount Amount of `token` returned.
     */
    event FundsReturned(address indexed token, uint256 amount);

    /**
     * @notice Emitted when the maximum order validity is set, by the constructor or `setMaxOrderValidity`.
     * @param maxOrderValidity New upper bound, in seconds past the `block.timestamp` at which an order is placed, for
     * that order's `validTo`.
     */
    event MaxOrderValiditySet(uint32 maxOrderValidity);

    error PriceTooLow(uint256 buyAmountNormalized, uint256 minBuyAmountNormalized);
    error ZeroAmount();
    error OrderExpired();
    error OrderValidityTooLong();
    error InvalidMaxOrderValidity();
    error DanglingApproval(address token);
    error InvalidRate(address rateProvider);
    error InvalidSlippage();
    error ZeroAddress();
    error NotBoringVault();
    error DuplicateOrder(bytes orderUid);
    error UnknownOrder(bytes orderUid);

    /// @notice Restricts a function to the BoringVault, i.e. calls routed through
    /// `ManagerWithMerkleVerification`.
    modifier onlyBoringVault() {
        if (msg.sender != boringVault) revert NotBoringVault();
        _;
    }

    /**
     * @notice Deploys the helper and caches the settlement immutables.
     * @param _owner The contract admin
     * @param _boringVault The BoringVault whose funds this helper trades and returns to, and the only
     * permitted caller of the order functions.
     * @param _settlement The CoW settlement contract.
     * @param _maxOrderValidity Maximum seconds past `block.timestamp` an order's `validTo` may reach; must be
     * non-zero (else every order, whose `validTo` must be strictly in the future, would revert).
     */
    constructor(
        address _owner,
        address _boringVault,
        address _settlement,
        uint32 _maxOrderValidity
    )
        Auth(_owner, Authority(address(0)))
    {
        if (_owner == address(0)) revert ZeroAddress();
        if (_boringVault == address(0)) revert ZeroAddress();
        if (_settlement == address(0)) revert ZeroAddress();

        boringVault = _boringVault;
        _setMaxOrderValidity(_maxOrderValidity);
        settlement = IGPv2Settlement(_settlement);
        vaultRelayer = IGPv2Settlement(_settlement).vaultRelayer();
        // Safe to cache: although the domain separator encodes chainId, the settlement computes it once in its
        // own constructor and stores it as an immutable - it is never recomputed, even across a chain split - so
        // for a fixed settlement address the value is frozen and always matches what `setPreSignature` checks.
        domainSeparator = IGPv2Settlement(_settlement).domainSeparator();
    }

    /**
     * @notice Pulls the sell token from the vault, approves the relayer, and pre-signs the order with the
     *         helper as owner and the vault as receiver.
     * @dev Intended to be called by the BoringVault through `ManagerWithMerkleVerification`. The vault must
     *      have granted this helper an allowance of exactly `sellAmount` for `sellToken`; any residual
     *      allowance after the pull reverts. The relayer is granted an unlimited allowance (set once per sell
     *      token), so multiple live orders for the same token draw from the helper's shared balance rather than
     *      each order clobbering the previous one's approval - the collateral is the balance, which every
     *      `placeOrder` tops up by `sellAmount`. Callable only by the BoringVault.
     *      Each UID is pre-signed at most once. A UID already seen (`Active` or `Closed`)
     *      reverts with `DuplicateOrder`.
     * @param params Raw order fields; see `OrderParams`.
     * @return orderUid The pre-signed order UID.
     */
    function placeOrder(OrderParams calldata params) external onlyBoringVault returns (bytes memory orderUid) {
        orderUid = _buildAndValidateOrderUid(params);

        if (orderStatus[orderUid] != OrderStatus.None) revert DuplicateOrder(orderUid);

        orderStatus[orderUid] = OrderStatus.Active;

        // Move the sell token from the vault into this helper.
        params.sellToken.safeTransferFrom(boringVault, address(this), params.sellAmount);
        if (params.sellToken.allowance(boringVault, address(this)) != 0) {
            revert DanglingApproval(address(params.sellToken));
        }

        // Approve the relayer to pull the sell token at settlement. An unlimited approval, (re)set only when the
        // current allowance can't cover this order, lets concurrent orders for the same token settle from the
        // helper's shared balance without one order's approval overwriting another's. In practice this sets the
        // allowance once per token (0 -> max) and is skipped thereafter.
        if (params.sellToken.allowance(address(this), vaultRelayer) < params.sellAmount) {
            params.sellToken.safeApprove(vaultRelayer, type(uint256).max);
        }

        settlement.setPreSignature(orderUid, true);

        emit OrderPlaced(
            address(params.sellToken), address(params.buyToken), params.sellAmount, params.buyAmount, orderUid
        );
    }

    /**
     * @notice Cancels a previously pre-signed order.
     * @dev Marks the UID `Closed`, clearing its pre-signed status and preventing it from being pre-signed or
     *      cancelled again. Does not move any tokens: the helper keeps no fill accounting, so the sell tokens
     *      must be pulled back to the vault separately via `sweepToken`. Reverts `UnknownOrder` if the UID was
     *      never placed or is already cancelled. Callable only by the BoringVault.
     * @param orderUid The UID to revoke.
     */
    function cancelOrder(bytes calldata orderUid) external onlyBoringVault {
        if (orderStatus[orderUid] != OrderStatus.Active) revert UnknownOrder(orderUid);

        orderStatus[orderUid] = OrderStatus.Closed;
        settlement.setPreSignature(orderUid, false);

        emit OrderCancelled(orderUid);
    }

    /**
     * @notice Sweeps `amount` of `token` from the helper back to the BoringVault.
     * @dev The strategist's path for returning sell tokens (an order's unfilled remainder, or an expired order's
     *      whole balance) to the vault. The refund always routes to the vault, so the caller may sweep any amount
     *      up to the helper's balance; the only hazard is undercollateralizing live orders that share the helper's
     *      balance for `token`. Callable only by the BoringVault.
     * @param token Token to return to the vault.
     * @param amount Amount of `token` to return to the vault.
     */
    function sweepToken(ERC20 token, uint256 amount) external onlyBoringVault {
        if (amount != 0) {
            token.safeTransfer(boringVault, amount);
            emit FundsReturned(address(token), amount);
        }
    }

    /**
     * @notice Updates the maximum seconds past `block.timestamp` an order's `validTo` may reach.
     * @dev Gated by `requiresAuth`, so callable only by the `owner` or an address the `authority` permits - NOT
     *      the merkle-verified vault path. `maxOrderValidity` is checked only when `placeOrder` runs, so this has
     *      no retroactive effect.
     * @param _maxOrderValidity Upper bound for the order expiry timestamp.
     */
    function setMaxOrderValidity(uint32 _maxOrderValidity) external requiresAuth {
        _setMaxOrderValidity(_maxOrderValidity);
    }

    /**
     * @dev Shared by the constructor and `setMaxOrderValidity` so both enforce non-zero value and emit the same event.
     *      Only the zero case needs checking here - the upper bound is carried by the `uint32` parameter type.
     *      A zero value would make every order revert, since `validTo` must be strictly in the future.
     */
    function _setMaxOrderValidity(uint32 _maxOrderValidity) internal {
        if (_maxOrderValidity == 0) revert InvalidMaxOrderValidity();
        maxOrderValidity = _maxOrderValidity;
        emit MaxOrderValiditySet(_maxOrderValidity);
    }

    /**
     * @notice Validates `params` against the oracle-derived price floor, then builds the canonical order
     *         (forcing all safety-critical fields) and returns its UID.
     * @dev Every field folded into the digest is either validated or forced to a safe constant, so nothing
     *      reaches the signed order unchecked.
     * @param params Raw order fields.
     * @return orderUid The reconstructed UID.
     */
    function _buildAndValidateOrderUid(OrderParams calldata params) internal view returns (bytes memory orderUid) {
        if (params.sellAmount == 0 || params.buyAmount == 0) revert ZeroAmount();
        if (params.validTo <= block.timestamp) revert OrderExpired();
        if (params.validTo > block.timestamp + maxOrderValidity) revert OrderValidityTooLong();
        if (params.maxSlippageBps > BPS_DENOMINATOR) revert InvalidSlippage();

        uint256 rate = params.rateProvider.getRate();
        if (rate == 0) revert InvalidRate(address(params.rateProvider));

        // Normalize both amounts to 18 decimals so the whole-token `rate` can bridge them. Rounding is
        // directional and always conservative for the vault: the sell amount rounds UP (a larger effective sell
        // raises the floor) and the buy amount rounds DOWN (a smaller effective buy makes the floor harder to
        // clear). Scaling UP (<= 18 decimals) is exact, so rounding only bites for tokens with > 18 decimals.
        uint256 sellNormalized =
            _normalize({ amount: params.sellAmount, decimals: params.sellToken.decimals(), roundUp: true });
        uint256 buyNormalized =
            _normalize({ amount: params.buyAmount, decimals: params.buyToken.decimals(), roundUp: false });

        // `rate` is buyToken-per-sellToken in `rateDecimals` fixed-point, so dividing the 18-decimal sell amount
        // by 10 ** rateDecimals yields the fair buy amount back in 18-decimal terms, comparable to buyNormalized.
        uint256 fairBuyNormalized = sellNormalized.mulDivUp(rate, 10 ** params.rateDecimals);
        uint256 minBuyNormalized = fairBuyNormalized.mulDivUp(BPS_DENOMINATOR - params.maxSlippageBps, BPS_DENOMINATOR);
        if (buyNormalized < minBuyNormalized) revert PriceTooLow(buyNormalized, minBuyNormalized);

        CowSwapOrderLib.Data memory order = CowSwapOrderLib.Data({
            sellToken: address(params.sellToken),
            buyToken: address(params.buyToken),
            receiver: boringVault,
            sellAmount: params.sellAmount,
            buyAmount: params.buyAmount,
            validTo: params.validTo,
            // Empty appData: cannot encode settlement hooks, so no arbitrary calls ride along.
            appData: bytes32(0),
            // feeAmount is a legacy field: CoW now charges fees inside the settlement clearing prices, so
            // signed orders always carry a zero fee.
            feeAmount: 0,
            kind: CowSwapOrderLib.KIND_SELL,
            partiallyFillable: params.partiallyFillable,
            sellTokenBalance: CowSwapOrderLib.BALANCE_ERC20,
            buyTokenBalance: CowSwapOrderLib.BALANCE_ERC20
        });

        bytes32 digest = CowSwapOrderLib.hash(order, domainSeparator);
        // Owner is always this helper: `setPreSignature` requires `owner == msg.sender`, and the helper is the
        // caller, so it must own the order.
        orderUid = CowSwapOrderLib.packOrderUid(digest, address(this), params.validTo);
    }

    /**
     * @notice Rescales a native token amount to 18 decimals so amounts in different token decimals can be
     *         compared against the whole-token oracle rate.
     * @dev Scaling up (`decimals <= 18`) is an exact multiply. Scaling down (`decimals > 18`) loses precision,
     *      so the caller chooses the rounding direction that stays conservative for the vault: the sell amount
     *      rounds up and the buy amount rounds down (see `_buildAndValidateOrderUid`). Rounding is therefore
     *      only reachable for the exotic case of tokens with more than 18 decimals.
     * @param amount Amount in the token's native units.
     * @param decimals The token's decimals.
     * @param roundUp When scaling down, round up if true, down if false. Ignored when scaling up (exact).
     * @return The amount rescaled to 18 decimals.
     */
    function _normalize(uint256 amount, uint8 decimals, bool roundUp) internal pure returns (uint256) {
        if (decimals <= 18) {
            return amount * (10 ** (18 - decimals));
        }
        uint256 divisor = 10 ** (decimals - 18);
        return roundUp ? amount.mulDivUp(1, divisor) : amount / divisor;
    }

}
