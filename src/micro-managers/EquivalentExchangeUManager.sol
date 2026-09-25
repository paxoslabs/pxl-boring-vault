// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { UManager, ERC20 } from "src/micro-managers/UManager.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { BalancerVault } from "src/interfaces/BalancerVault.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title EquivalentExchangeUManager
 * @notice UManager that executes a batch of merkle-verified BoringVault actions
 *         and enforces that the aggregate value of a stored basket of tokens,
 *         measured in a common reference asset, does not decrease.
 * @dev Basket tokens are valued in a single reference asset and carried internally as 18-decimal fixed
 *      point (`NORMALIZED_DECIMALS`), where `NORMALIZED_ONE` represents one whole unit of the reference
 *      asset. Most tokens are expected to be worth one reference unit per whole token and are treated as
 *      1:1 after decimal normalization, requiring no oracle. A token may instead be flagged as
 *      oracle-priced, in which case its per-whole-token price in the reference asset is read from an
 *      `IRateProvider` at execution time and applied to its balance. The same conversion is used when
 *      paying the subsidy in an oracle-priced token.
 *
 *      Which basket tokens are oracle-priced is recorded as a bitmap (`oracleFlags`): bit `i` is set iff
 *      the basket token at index `i` (in `basketTokens` order) is oracle-priced. A basket of only 1:1
 *      tokens (such as USD stablecoins) therefore requires no oracle lookups.
 *
 *      Scope: this manager only guarantees the aggregate reference-asset value of the BASKET tokens does not
 *      decrease across a batch. Tokens the vault holds that are not in the basket are outside the value
 *      invariant and the per-token delta bounds entirely -- their safety rests solely on the merkle root not
 *      authorizing a call that moves or approves them. Every value-bearing token the vault may hold or route
 *      through should therefore be a basket token. (The dangling-approval check is the one place non-basket
 *      tokens are inspected, and only for leftover allowances.)
 *
 *      Fee-on-transfer basket tokens are unsupported: _coverShortfall credits the subsidy at the amount it
 *      sends, not the smaller amount the vault actually receives, so a transfer fee on the subsidy token would
 *      let the value invariant pass while leaving the vault short.
 *
 *      Subsidy, if required, is pulled from an approval-based subsidy payer. The subsidy payer must
 *      pre-approve the UManager to spend the subsidy token; if the approved/available amount is
 *      insufficient, the call reverts.
 *
 *      Oracle security assumptions:
 *      - The whole basket must be denominated in a single, consistent reference asset: every 1:1 token
 *        must actually be worth one reference unit per whole token, and every oracle must return its
 *        token's price in that same reference asset. The reference asset is whatever unit the operator
 *        standardizes on -- USD, ETH, or anything else -- and is never named on-chain. Mixing units --
 *        e.g. treating USD-pegged tokens as 1:1 while an oracle returns an ETH-denominated price --
 *        compares unlike quantities and corrupts the value invariant.
 *      - Each oracle is an `IRateProvider` returning the token's whole-token price in the reference asset,
 *        scaled to the `rateDecimals` recorded for it (the contract rescales that to `NORMALIZED_DECIMALS`).
 *        The owner must record the correct `rateDecimals` -- `IRateProvider` exposes no `decimals()` to
 *        read -- and must configure oracles that return a single positive `uint256` price, perform their
 *        own staleness and sanity checks, and cannot be manipulated within a block. A raw Chainlink feed
 *        does not satisfy this (a signed tuple, no staleness guard); wrap it in an adapter such as
 *        `EthPerTokenRateProvider`.
 *      - A reverting or zero-returning oracle causes `execute` to revert, which is preferable to
 *        valuing a basket token incorrectly.
 */
contract EquivalentExchangeUManager is UManager {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeCast for uint256;

    /// @notice Fixed-point decimal scale used for normalizing token amounts and expressing value in
    /// the reference asset.
    uint256 internal constant NORMALIZED_DECIMALS = 18;

    /// @notice One whole unit of normalized value, i.e. 10**NORMALIZED_DECIMALS. Equal to one
    /// whole unit of the reference asset and to one whole token of a normalized balance.
    uint256 internal constant NORMALIZED_ONE = 10 ** NORMALIZED_DECIMALS;

    /// @notice Maximum number of basket tokens. Bounded by the width of `oracleFlags` (256 bits), so every
    /// basket index maps to a distinct flag bit.
    uint256 internal constant MAX_BASKET_TOKENS = 256;

    /// @notice Selector for increaseAllowance(address,uint256).
    bytes4 internal constant INCREASE_ALLOWANCE_SELECTOR = 0x39509351;

    /// @notice Selector for increaseApproval(address,uint256), a non-standard allowance-raising variant some
    /// older tokens expose instead of increaseAllowance. Same (spender, amount) layout.
    bytes4 internal constant INCREASE_APPROVAL_SELECTOR = 0xd73dd623;

    /// @notice Basket tokens whose aggregate reference-asset value this UManager preserves across an
    /// `execute` batch.
    EnumerableSet.AddressSet internal basketTokens;

    /// @notice Bitmap of which basket tokens are oracle-priced: bit `i` is set iff the token at index `i`
    /// in `basketTokens` is priced through an oracle rather than treated as a 1:1 token.
    /// @dev Indices align with `basketTokens.values()`; `setBasketTokens` rebuilds both together.
    bytes32 internal oracleFlags;

    /// @notice Maps a basket token to its oracle configuration: the rate provider used to convert its
    /// balance to the reference asset, together with the number of decimals that provider's `getRate()`
    /// output carries (the provider itself exposes no `decimals()`). Both fields share one storage slot.
    /// @dev `oracleFlags`, not this mapping, is the source of truth for whether a token is oracle-priced.
    /// Entries are read only when a token's flag bit is set, so 1:1 tokens never hit the mapping, and it is
    /// allowed to be "dirty": stale entries left behind when the basket changes are never read.
    mapping(address => RateProviderConfig) internal tokenOracles;

    error EmptyBasket();
    error BasketTooLarge();
    error DuplicateToken(address token);
    error TokenNotInBasket();
    error InvalidRateProviderConfig(address token);
    error InvalidRate(address token);
    error InsufficientSubsidy();
    error InvalidSubsidyPayer();
    error DanglingApproval();
    error FlashLoanInBatch();
    error TokenDeltaLengthMismatch();
    error TokenDeltaViolation(
        address token, uint256 balanceBefore, uint256 balanceAfter, int256 balanceDelta, int256 allowedBalanceDelta
    );

    event BasketTokensUpdated(BasketToken[] tokens);
    event Executed(
        address indexed caller,
        ERC20 indexed subsidyToken,
        uint256 totalBeforeNormalized,
        uint256 totalAfterNormalized,
        uint256 subsidyAmount,
        uint256 subsidyAmountNormalized
    );

    /**
     * @notice A basket token's price source. Packs into one storage slot (8 + 160 + 8 bits).
     * @dev `setBasketTokens` enforces consistency between `isPeggedToken` and the other fields, so a
     * forgotten oracle can never be silently read as 1:1.
     * @param isPeggedToken True for a 1:1 token (no oracle); false when a `rateProvider` and `rateDecimals` are
     * supplied.
     * @param rateProvider Provider returning the token's whole-token price in the reference asset; zero for a
     * pegged token.
     * @param rateDecimals Decimals of `rateProvider`'s `getRate()` output; zero for a pegged token.
     */
    struct RateProviderConfig {
        bool isPeggedToken;
        IRateProvider rateProvider;
        uint8 rateDecimals;
    }

    /**
     * @notice A basket token together with its reference-asset price source.
     * @param token The basket token.
     * @param config Price source for `token`; see `RateProviderConfig`.
     */
    struct BasketToken {
        ERC20 token;
        RateProviderConfig config;
    }

    /**
     * @notice A batch of merkle-verified BoringVault actions, as parallel arrays.
     * @dev The downstream manager enforces that all five arrays are the same length, so this contract skips those
     * checks.
     * @param manageProofs Merkle proof for each action.
     * @param decodersAndSanitizers Decoder/sanitizer to extract each action's gated addresses.
     * @param targets Contract each action calls.
     * @param targetData Calldata for each action.
     * @param values ETH value for each action.
     */
    struct ManageCalls {
        bytes32[][] manageProofs;
        address[] decodersAndSanitizers;
        address[] targets;
        bytes[] targetData;
        uint256[] values;
    }

    constructor(address _owner, address _manager) UManager(_owner, _manager) { }

    /**
     * @notice Sets the basket of tokens used for accounting, along with each token's reference-asset price source.
     * @dev The basket is exactly the set of tokens whose balance changes `execute` checks, and defines the
     * order `allowableTokenDelta` (and the `oracleFlags` bitmap) bind to. A token whose config declares
     * `isPeggedToken` is treated as a 1:1 token; otherwise it is priced through its `rateProvider`. Duplicate
     * token addresses are rejected so the stored basket is an exact, order-preserving image of the input.
     * @param tokens Basket tokens and their price sources. At most `MAX_BASKET_TOKENS` entries.
     * @custom:access OWNER_ROLE / MULTISIG_ROLE should be granted authority.
     */
    function setBasketTokens(BasketToken[] calldata tokens) external requiresAuth {
        // Remove all existing tokens by popping from the end. Length shrinks on each removal, so we must
        // iterate backwards to avoid out-of-bounds reads. Stale `tokenOracles` entries are intentionally
        // left in place; they are never read once their flag bit is cleared below.
        uint256 existingLength = basketTokens.length();
        for (uint256 i = existingLength; i > 0; --i) {
            basketTokens.remove(basketTokens.at(i - 1));
        }

        uint256 newLength = tokens.length;
        // Each basket index must map to a distinct bit of `oracleFlags`.
        if (newLength > MAX_BASKET_TOKENS) revert BasketTooLarge();

        // Add new tokens, building the oracle bitmap in lockstep so bit `i` describes the token at index
        // `i`. Duplicates revert so the stored basket is an exact, order-preserving image of the input.
        bytes32 flags;
        for (uint256 i; i < newLength; ++i) {
            address token = address(tokens[i].token);
            // add() returns false when the token is already present in the set.
            if (!basketTokens.add(token)) revert DuplicateToken(token);

            RateProviderConfig calldata config = tokens[i].config;
            IRateProvider rateProvider = config.rateProvider;
            bool isPegged = config.isPeggedToken;

            // `isPeggedToken` must agree with both oracle fields: "pegged", "no rate provider", and "no rate
            // decimals" must all hold together or all be false together. Requiring the flag to be explicit
            // means a forgotten oracle can never be silently treated as a 1:1 token.
            if ((isPegged != (address(rateProvider) == address(0))) || (isPegged != (config.rateDecimals == 0))) {
                revert InvalidRateProviderConfig(token);
            }

            if (!isPegged) {
                // Direct calldata -> storage copy of all packed fields.
                tokenOracles[token] = config;
                flags = _withOracleFlag(flags, i);
            }
        }
        oracleFlags = flags;

        // Duplicates revert above, so the stored set matches the input exactly. Emit the calldata
        // directly rather than reading the set back out of storage.
        emit BasketTokensUpdated(tokens);
    }

    /**
     * @notice Returns the basket tokens, each with its reference-asset price source, in stored order.
     */
    function getBasketTokens() external view returns (BasketToken[] memory tokens) {
        address[] memory values = basketTokens.values();
        bytes32 flags = oracleFlags;
        uint256 length = values.length;
        tokens = new BasketToken[](length);
        for (uint256 i; i < length; ++i) {
            RateProviderConfig memory config = _hasOracleFlag(flags, i)
                ? tokenOracles[values[i]]
                : RateProviderConfig(true, IRateProvider(address(0)), 0);
            tokens[i] = BasketToken({ token: ERC20(values[i]), config: config });
        }
    }

    /**
     * @notice Returns whether a token is part of the basket.
     */
    function isBasketToken(ERC20 token) external view returns (bool) {
        return basketTokens.contains(address(token));
    }

    /**
     * @notice Executes a batch of merkle-verified BoringVault actions, enforces a per-token bound on
     *         each basket token's balance change over the batch, and enforces that the vault's aggregate
     *         basket value (in the reference asset) does not decrease (topping up any shortfall from the
     *         subsidy payer).
     * @dev `allowableTokenDelta` must be exactly as long as the basket, so every basket token is bounded. Movement is
     *      measured over the batch ONLY; the subsidy pulled afterwards is not counted against any bound.
     *
     *      Each token's value is its decimal-normalized balance for 1:1 tokens, or that balance priced
     *      through the token's oracle for oracle-priced tokens. A token's oracle rate is read once and
     *      applied to both the before and after balances, so the two totals cannot disagree on price.
     *
     *      Subsidy, if needed, is pulled from the indicated subsidy payer using ERC20 transferFrom; the
     *      payer must have approved the UManager. The amount pulled is the aggregate shortfall (in the
     *      reference asset), converted to the subsidy token (through its oracle when oracle-priced) and
     *      rounded up.
     * @param calls Batch of merkle-verified BoringVault actions to execute.
     * @param subsidyPayer Address that provides the subsidy tokens via approval.
     * @param subsidyToken Token to use as subsidy. Must be a basket token.
     * @param allowableTokenDelta Minimum signed balance change tolerated for each basket token, in native units,
     * parallel to `getBasketTokens()`. `execute` reverts if a token's actual change (balanceAfter - balanceBefore)
     * is less than its entry. For example, -100 lets the balance fall by up to 100, +100 requires it to rise by at
     * least 100, and 0 requires it not to fall.
     * @return subsidyAmount Subsidy pulled from `subsidyPayer`, in `subsidyToken`'s native units. This is the
     * amount actually transferred, inclusive of the conversion round-up.
     * @custom:access STRATEGIST_ROLE should be granted authority - confined to calls the merkle root already
     * allows, and cannot lower the basket's total value. Note `allowableTokenDelta` is supplied by the caller, so it
     * guards against a bad route, not against a bad strategist.
     */
    function execute(
        ManageCalls calldata calls,
        address subsidyPayer,
        ERC20 subsidyToken,
        int256[] calldata allowableTokenDelta
    )
        external
        requiresAuth
        returns (uint256 subsidyAmount)
    {
        // Read the basket once into memory. The loops index tokens, allowableTokenDelta and oracleFlags by
        // the same i, so any configuration that could update the basket or its oracles mid-execution would be
        // invalid.
        address[] memory tokens = basketTokens.values();
        uint256 basketLength = tokens.length;

        if (basketLength == 0) revert EmptyBasket();
        if (!basketTokens.contains(address(subsidyToken))) revert TokenNotInBasket();
        if (allowableTokenDelta.length != basketLength) revert TokenDeltaLengthMismatch();
        // The subsidy must be new value from outside the vault. If the payer were the vault itself, the
        // transferFrom in _coverShortfall would be a self-transfer that leaves the balance unchanged while
        // the accounting credits it to totalAfter, letting the value invariant pass without any real subsidy.
        if (subsidyPayer == boringVault) revert InvalidSubsidyPayer();

        // Snapshot the pre-batch balances the delta bounds are measured against. Normalizing/pricing is
        // deferred to the post-batch loop, which reads each token's decimals and oracle anyway.
        uint256[] memory beforeBalances = new uint256[](basketLength);

        for (uint256 i; i < basketLength; ++i) {
            beforeBalances[i] = ERC20(tokens[i]).balanceOf(boringVault);
        }

        // Execute the merkle-verified action batch directly from BoringVault.
        _manageVaultWithMerkleVerification(calls);

        // Bounds constrain what the batch did, so they are checked before any subsidy is pulled. The
        // per-token loop is factored out to keep `execute` under the stack limit. It also reports the rate
        // the subsidy token was valued at, so the subsidy is priced identically to the shortfall.
        (uint256 totalBefore, uint256 totalAfter, uint256 subsidyRate) =
            _checkAndValueBasket(tokens, beforeBalances, allowableTokenDelta, address(subsidyToken));

        // Cover any aggregate shortfall using the indicated subsidy token. The subsidy inflow is
        // intentionally not counted against subsidyToken's delta bound.
        uint256 subsidyAmountNormalized;
        if (totalAfter < totalBefore) {
            uint256 shortfall = totalBefore - totalAfter;
            (subsidyAmount, subsidyAmountNormalized) =
                _coverShortfall(shortfall, subsidyPayer, subsidyToken, subsidyRate);
            totalAfter += subsidyAmountNormalized;
        }

        // Final invariant check. _coverShortfall either covers the shortfall or
        // reverts; this assert is a self-documenting guard against future
        // changes to subsidy behavior.
        assert(totalAfter >= totalBefore);

        // Calldata checks over the executed batch: reject any flashLoan call and any leftover approval.
        _enforceCalldataChecks(calls);

        emit Executed(msg.sender, subsidyToken, totalBefore, totalAfter, subsidyAmount, subsidyAmountNormalized);
    }

    /**
     * @notice Checks each basket token's balance delta and totals the vault's basket value, in the
     *         reference asset, both before and after the batch.
     * @dev Factored out of `execute` purely to stay under the stack limit. Each oracle-priced token (per
     * the `oracleFlags` bitmap) has its rate read once and applied to both balances, so the two totals
     * cannot disagree on price.
     * @param tokens Basket token addresses snapshotted at the start of `execute`.
     * @param beforeBalances Pre-batch vault balances, parallel to `tokens`.
     * @param allowableTokenDelta Minimum signed balance change tolerated for each token, parallel to `tokens`.
     * @param subsidyToken The token a subsidy would be paid in, whose rate is captured for `_coverShortfall`.
     * @return totalBefore Aggregate reference-asset value of the basket before the batch.
     * @return totalAfter Aggregate reference-asset value of the basket after the batch.
     * @return subsidyRate The per-native-unit rate `subsidyToken` was valued at (its decimals already
     * applied), so `_coverShortfall` prices the subsidy identically to the shortfall.
     */
    function _checkAndValueBasket(
        address[] memory tokens,
        uint256[] memory beforeBalances,
        int256[] calldata allowableTokenDelta,
        address subsidyToken
    )
        internal
        view
        returns (uint256 totalBefore, uint256 totalAfter, uint256 subsidyRate)
    {
        bytes32 flags = oracleFlags;
        uint256 basketLength = tokens.length;
        for (uint256 i; i < basketLength; ++i) {
            address token = tokens[i];
            uint256 balanceBefore = beforeBalances[i];
            uint256 balanceAfter = ERC20(token).balanceOf(boringVault);

            _checkTokenDelta(token, balanceBefore, balanceAfter, allowableTokenDelta[i]);

            // A 1:1 token is worth one reference unit per whole token, i.e. NORMALIZED_ONE at
            // NORMALIZED_DECIMALS. An oracle-priced token (its flag bit set) uses one getRate() reading,
            // scaled to whatever decimals the provider was configured with.
            uint256 baseRate = NORMALIZED_ONE;
            uint8 rateDecimals = uint8(NORMALIZED_DECIMALS);
            if (_hasOracleFlag(flags, i)) {
                RateProviderConfig storage config = tokenOracles[token];
                rateDecimals = config.rateDecimals;
                baseRate = config.rateProvider.getRate();
                // A zero rate cannot value the token, so reject it rather than mispricing the basket.
                if (baseRate == 0) revert InvalidRate(token);
            }
            uint8 tokenDecimals = ERC20(token).decimals();
            // Reject any config _unitRate can't rescale losslessly: when rateDecimals + tokenDecimals exceeds
            // 2 * NORMALIZED_DECIMALS, its exponent would go negative (a lossy divide), which is not
            // conservative across a mixed basket. Realistic configs (<= 18-dec oracle, <= 18-dec token) never
            // hit this, and with baseRate > 0 the resulting rate is then always > 0.
            if (uint256(rateDecimals) + tokenDecimals > 2 * NORMALIZED_DECIMALS) revert InvalidRate(token);

            // Fold the oracle's own precision and the token's decimals into one per-native-unit rate, so
            // nothing downstream needs either. Applying the one rate to both balances keeps the two totals
            // from disagreeing on price or scale.
            uint256 rate = _unitRate(baseRate, rateDecimals, tokenDecimals);

            // Capture the subsidy token's per-unit rate as it is valued, so `_coverShortfall` can reuse it.
            if (token == subsidyToken) subsidyRate = rate;

            totalBefore += _tokenAmountToReferenceValue(balanceBefore, rate);
            totalAfter += _tokenAmountToReferenceValue(balanceAfter, rate);
        }
    }

    /**
     * @notice Covers a normalized (reference-asset) shortfall by transferring subsidy from the
     *         subsidy payer to the vault.
     * @dev The subsidy token must be a basket token. The payer must have a
     *      sufficient balance and approval to cover the shortfall.
     * @param shortfall Shortfall in normalized (reference-asset) units.
     * @param subsidyPayer Address that provides the subsidy tokens via approval.
     * @param subsidyToken Token to use as subsidy.
     * @param rate Per-native-unit reference-asset rate for `subsidyToken` (its decimals already applied).
     * @return subsidyAmount Amount of subsidy transferred, in the subsidy token's native units.
     * @return subsidyAmountNormalized Total normalized (reference-asset) value of subsidy transferred.
     */
    function _coverShortfall(
        uint256 shortfall,
        address subsidyPayer,
        ERC20 subsidyToken,
        uint256 rate
    )
        internal
        returns (uint256 subsidyAmount, uint256 subsidyAmountNormalized)
    {
        uint256 balance = subsidyToken.balanceOf(subsidyPayer);
        uint256 allowance = subsidyToken.allowance(subsidyPayer, address(this));
        uint256 available = balance < allowance ? balance : allowance;

        // Guard in reference-asset terms. Because the guard uses the same flooring conversion as pricing
        // and `_referenceValueToTokenAmount` rounds up, `available`'s reference-asset value >= shortfall
        // implies the converted subsidyAmount <= available. So the transfer below can never pull more than
        // is available.
        if (_tokenAmountToReferenceValue(available, rate) < shortfall) revert InsufficientSubsidy();

        subsidyAmount = _referenceValueToTokenAmount(shortfall, rate);

        subsidyToken.safeTransferFrom(subsidyPayer, boringVault, subsidyAmount);

        // Re-value the actual amount transferred for accounting. The round-up in
        // `_referenceValueToTokenAmount` guarantees this is >= shortfall, so the value invariant holds.
        subsidyAmountNormalized = _tokenAmountToReferenceValue(subsidyAmount, rate);
    }

    /**
     * @notice Reverts if a basket token's balance change over the batch is below the caller's minimum.
     * @dev toInt256() reverts rather than wrapping to a negative if a balance ever exceeds 2**255 - 1, e.g. a
     *      token that flash-mints an enormous supply into the vault mid-batch.
     * @param token Basket token being checked.
     * @param balanceBefore Vault balance before the batch.
     * @param balanceAfter Vault balance after the batch.
     * @param allowedBalanceDelta Minimum signed change the caller will accept for this token.
     */
    function _checkTokenDelta(
        address token,
        uint256 balanceBefore,
        uint256 balanceAfter,
        int256 allowedBalanceDelta
    )
        internal
        pure
    {
        int256 delta = balanceAfter.toInt256() - balanceBefore.toInt256();
        if (delta < allowedBalanceDelta) {
            revert TokenDeltaViolation(token, balanceBefore, balanceAfter, delta, allowedBalanceDelta);
        }
    }

    /**
     * @notice Scans the batch's calldata and reverts in the following cases:
     *
     * - A flashLoan call. It would run a second, separately merkle-verified batch inside the callback
     *   (manager.flashLoan -> Balancer -> manager.receiveFlashLoan), which this contract's value invariant,
     *   delta bounds and approval check never see. Rejecting the selector keeps every batch to one inspected
     *   layer.
     * - A leftover allowance. Any approve whose allowance is still non-zero after the batch is a standing
     *   drain vector, on basket and non-basket tokens alike.
     *
     * @param calls Batch of merkle-verified BoringVault actions.
     */
    function _enforceCalldataChecks(ManageCalls calldata calls) internal view {
        uint256 callsLength = calls.targets.length;

        for (uint256 i; i < callsLength; ++i) {
            address target = calls.targets[i];
            bytes calldata targetData = calls.targetData[i];

            // Length check is >= 68 because some token contracts (e.g., compiled
            // with older Solidity versions) may tolerate trailing calldata on
            // low-level calls rather than reverting. approve, increaseAllowance
            // and increaseApproval all take (address,uint256), so they require
            // 4 + 32 + 32 = 68 bytes at minimum. Flash loan calls are also not
            // affected by this check because they require 132+ bytes.
            if (targetData.length < 68) continue;

            bytes4 selector = bytes4(targetData[0:4]);

            // Reject flashLoan calls: they open a nested, uninspected manage layer that may contain unchecked
            // approvals.
            if (selector == BalancerVault.flashLoan.selector) revert FlashLoanInBatch();

            if (
                selector != ERC20.approve.selector && selector != INCREASE_ALLOWANCE_SELECTOR
                    && selector != INCREASE_APPROVAL_SELECTOR
            ) continue;

            // Spender is the first argument (offset 4, zero-padded address), amount the second; this layout
            // is identical for approve, increaseAllowance and increaseApproval.
            (address spender, uint256 amount) = abi.decode(targetData[4:68], (address, uint256));
            // A zero-amount approval cannot create a dangling allowance. This only skips the current call;
            // any other non-zero approval to the same token and spender is still checked.
            if (amount == 0) continue;

            if (ERC20(target).allowance(boringVault, spender) != 0) {
                revert DanglingApproval();
            }
        }
    }

    /**
     * @notice Forwards a batch to ManagerWithMerkleVerification.
     * @dev Kept separate only to keep `execute` under the stack limit; inlining it is "stack too deep".
     * @param calls Batch of merkle-verified BoringVault actions.
     */
    function _manageVaultWithMerkleVerification(ManageCalls calldata calls) internal {
        manager.manageVaultWithMerkleVerification(
            calls.manageProofs, calls.decodersAndSanitizers, calls.targets, calls.targetData, calls.values
        );
    }

    /**
     * @notice Converts an oracle rate into a per-native-unit rate, accounting for both the oracle's output
     *         precision and the token's decimals in a single power-of-ten rescale.
     * @dev A whole token costs `rate` at `rateDecimals` and is `10 ** tokenDecimals` native units, so one
     * native unit is worth `rate / 10 ** (rateDecimals + tokenDecimals)` reference units. That is scaled up
     * by `10 ** (2 * NORMALIZED_DECIMALS)` -- once to reach NORMALIZED_DECIMALS, once more to pre-cancel the
     * NORMALIZED_ONE that `_tokenAmountToReferenceValue` later divides by -- giving the net multiply below.
     * `_checkAndValueBasket` keeps `rateDecimals + tokenDecimals <= 2 * NORMALIZED_DECIMALS`, so the exponent
     * stays non-negative: the rescale is a multiply, not the flooring divide a negative exponent would force.
     * A larger sum underflows that subtraction and reverts.
     * @param rate Whole-token price from the oracle, scaled to `rateDecimals` (NORMALIZED_ONE with
     * `rateDecimals == NORMALIZED_DECIMALS` for a 1:1 token).
     * @param rateDecimals Decimals of `rate`.
     * @param tokenDecimals Token decimals.
     * @return Reference-asset value of one native token unit, scaled to NORMALIZED_DECIMALS.
     */
    function _unitRate(uint256 rate, uint8 rateDecimals, uint8 tokenDecimals) internal pure returns (uint256) {
        return rate * (10 ** (2 * NORMALIZED_DECIMALS - uint256(rateDecimals) - tokenDecimals));
    }

    /**
     * @notice Values a token balance in normalized (reference-asset) units.
     * @dev `rate` is the reference-asset value of one native token unit (its decimals already applied by
     * `_unitRate`), so the balance is worth `balance * rate / NORMALIZED_ONE`, multiplying before dividing
     * and flooring.
     * @param balance Token balance in native units.
     * @param rate Reference-asset value of one native token unit, scaled to NORMALIZED_DECIMALS.
     * @return Reference-asset value scaled to NORMALIZED_DECIMALS.
     */
    function _tokenAmountToReferenceValue(uint256 balance, uint256 rate) internal pure returns (uint256) {
        return balance.mulDivDown(rate, NORMALIZED_ONE);
    }

    /**
     * @notice Converts a normalized (reference-asset) value to a token's native units, rounding up so the
     *         result is never worth less than the input value.
     * @dev Inverse of `_tokenAmountToReferenceValue`: `amount = ceil(referenceValue * NORMALIZED_ONE / rate)`. Rounding
     * up guarantees re-pricing the result covers at least `referenceValue`, so the subsidy can never
     * under-cover.
     * @param referenceValue Value in normalized (reference-asset) units.
     * @param rate Reference-asset value of one native token unit, scaled to NORMALIZED_DECIMALS.
     * @return Token amount in native units.
     */
    function _referenceValueToTokenAmount(uint256 referenceValue, uint256 rate) internal pure returns (uint256) {
        return referenceValue.mulDivUp(NORMALIZED_ONE, rate);
    }

    /**
     * @notice Returns whether the basket token at `index` is oracle-priced, per an `oracleFlags` snapshot.
     */
    function _hasOracleFlag(bytes32 flags, uint256 index) internal pure returns (bool) {
        return ((uint256(flags) >> index) & 1) == 1;
    }

    /**
     * @notice Returns a copy of `flags` with the oracle-priced bit for `index` turned on.
     * @dev Pure bitmap transform returning a new value; performs no storage write. `index` is always
     * < MAX_BASKET_TOKENS (256), so the shift stays in range.
     */
    function _withOracleFlag(bytes32 flags, uint256 index) internal pure returns (bytes32) {
        return bytes32(uint256(flags) | (uint256(1) << index));
    }

}
