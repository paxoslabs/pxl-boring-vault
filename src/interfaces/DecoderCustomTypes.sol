// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

contract DecoderCustomTypes {

    // ========================================= BALANCER =========================================
    struct JoinPoolRequest {
        address[] assets;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }

    struct ExitPoolRequest {
        address[] assets;
        uint256[] minAmountsOut;
        bytes userData;
        bool toInternalBalance;
    }

    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address recipient;
        bool toInternalBalance;
    }

    // ========================================= VELODROME =========================================
    struct VelodromeMintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    struct VelodromeV2Route {
        address from;
        address to;
        bool stable;
    }

    // ========================================= UNISWAP V3 =========================================

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    // ========================================= UNISWAP V4 =========================================
    // Mirrors Uniswap v4-periphery encodings. `Currency` and `IHooks` are address-wide, so they are
    // represented as `address` here for ABI decoding.

    struct V4PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct V4PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    struct V4ExactInputSingleParams {
        V4PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct V4ExactInputParams {
        address currencyIn;
        V4PathKey[] path;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    struct V4ExactOutputSingleParams {
        V4PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        bytes hookData;
    }

    struct V4ExactOutputParams {
        address currencyOut;
        V4PathKey[] path;
        uint128 amountOut;
        uint128 amountInMaximum;
    }

    // ========================================= MORPHO BLUE =========================================

    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    // ========================================= 1INCH =========================================

    struct SwapDescription {
        address srcToken;
        address dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    // ========================================= KITTENSWAP =========================================
    struct route {
        address from;
        address to;
        bool stable;
    }

    // ========================================= PENDLE =========================================
    struct TokenInput {
        // TOKEN DATA
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        // AGGREGATOR DATA
        address pendleSwap;
        SwapData swapData;
    }

    struct TokenOutput {
        // TOKEN DATA
        address tokenOut;
        uint256 minTokenOut;
        address tokenRedeemSy;
        // AGGREGATOR DATA
        address pendleSwap;
        SwapData swapData;
    }

    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain; // pass 0 in to skip this variable
        uint256 maxIteration; // every iteration, the diff between guessMin and guessMax will be divided by 2
        uint256 eps; // the max eps between the returned result & the correct result, base 1e18. Normally this number
        // will be set
        // to 1e15 (1e18/1000 = 0.1%)
    }

    struct SwapData {
        SwapType swapType;
        address extRouter;
        bytes extCalldata;
        bool needScale;
    }

    enum OrderType {
        SY_FOR_PT,
        PT_FOR_SY,
        SY_FOR_YT,
        YT_FOR_SY
    }

    struct Order {
        uint256 salt;
        uint256 expiry;
        uint256 nonce;
        OrderType orderType;
        address token;
        address YT;
        address maker;
        address receiver;
        uint256 makingAmount;
        uint256 lnImpliedRate;
        uint256 failSafeRate;
        bytes permit;
    }

    struct FillOrderParams {
        Order order;
        bytes signature;
        uint256 makingAmount;
    }

    struct LimitOrderData {
        address limitRouter;
        uint256 epsSkipMarket; // only used for swap operations, will be ignored otherwise
        FillOrderParams[] normalFills;
        FillOrderParams[] flashFills;
        bytes optData;
    }

    enum SwapType {
        NONE,
        KYBERSWAP,
        ONE_INCH,
        // ETH_WETH not used in Aggregator
        ETH_WETH
    }

    // ========================================= PXL =========================================

    struct AtomicRequestUCP {
        uint64 deadline; // Timestamp when request expires
        uint96 atomicPrice; // User's limit price in want asset decimals
        uint96 offerAmount; // Amount of offer asset to sell
        address recipient; // Address to receive want assets
    }

    // ========================================= SUPERBRIDGE =========================================
    /// @notice Struct representing a withdrawal transaction.
    /// @custom:field nonce    Nonce of the withdrawal transaction
    /// @custom:field sender   Address of the sender of the transaction.
    /// @custom:field target   Address of the recipient of the transaction.
    /// @custom:field value    Value to send to the recipient.
    /// @custom:field gasLimit Gas limit of the transaction.
    /// @custom:field data     Data of the transaction.
    struct WithdrawalTransaction {
        uint256 nonce;
        address sender;
        address target;
        uint256 value;
        uint256 gasLimit;
        bytes data;
    }

    /// @notice Struct representing the elements that are hashed together to generate an output root
    ///         which itself represents a snapshot of the L2 state.
    /// @custom:field version                  Version of the output root.
    /// @custom:field stateRoot                Root of the state trie at the block of this output.
    /// @custom:field messagePasserStorageRoot Root of the message passer storage trie.
    /// @custom:field latestBlockhash          Hash of the block this output was generated from.
    struct OutputRootProof {
        bytes32 version;
        bytes32 stateRoot;
        bytes32 messagePasserStorageRoot;
        bytes32 latestBlockhash;
    }

    // ========================================= EIGEN LAYER =========================================

    struct QueuedWithdrawalParams {
        // Array of strategies that the QueuedWithdrawal contains
        address[] strategies;
        // Array containing the amount of shares in each Strategy in the `strategies` array
        uint256[] shares;
        // The address of the withdrawer
        address withdrawer;
    }

    struct Withdrawal {
        // The address that originated the Withdrawal
        address staker;
        // The address that the staker was delegated to at the time that the Withdrawal was created
        address delegatedTo;
        // The address that can complete the Withdrawal + will receive funds when completing the withdrawal
        address withdrawer;
        // Nonce used to guarantee that otherwise identical withdrawals have unique hashes
        uint256 nonce;
        // Block number when the Withdrawal was created
        uint32 startBlock;
        // Array of strategies that the Withdrawal contains
        address[] strategies;
        // Array containing the amount of shares in each Strategy in the `strategies` array
        uint256[] shares;
    }

    /// @notice Minimal market data to be provided by the user when setting markets.
    struct MarketData {
        /// @notice Morpho Market ID.
        bytes32 id;
        /// @notice Address of the price feed used to convert the value of the market's loan token to the numeraire.
        address priceFeed;
        /// @notice Indicates whether the price feed value should be inverted (e.g. USD/WETH -> WETH/USD).
        bool invertPrice;
    }

    // ========================================= Sentiment =========================================

    /// @title Operation
    /// @notice Operation type definitions that can be applied to a position
    /// @dev Every operation except NewPosition requires that the caller must be an authz caller or owner
    enum Operation {
        NewPosition, // create2 a new position with a given type, no auth needed
        // the following operations require msg.sender to be authorized
        Exec, // execute arbitrary calldata on a position
        Deposit, // Add collateral to a given position
        Transfer, // transfer assets from the position to a external address
        Approve, // allow a spender to transfer assets from a position
        Repay, // decrease position debt
        Borrow, // increase position debt
        AddToken, // upsert collateral asset to position storage
        RemoveToken // remove collateral asset from position storage
    }

    /// @title Action
    /// @notice Generic data struct to create a common data container for all operation types
    /// @dev target and data are interpreted in different ways based on the operation type
    struct Action {
        // operation type
        Operation op;
        // dynamic bytes data, interpreted differently across operation types
        bytes data;
    }
    // ========================================= Valantis =========================================

    struct SovereignPoolSwapContextData {
        bytes externalContext;
        bytes verifierContext;
        bytes swapCallbackContext;
        bytes swapFeeModuleContext;
    }

    struct SovereignPoolSwapParams {
        bool isSwapCallback;
        bool isZeroToOne;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 deadline;
        address recipient;
        address swapTokenOut;
        SovereignPoolSwapContextData swapContext;
    }

    // ========================================= PREDICATE =========================================
    struct PredicateMessage {
        // the unique identifier for the task
        string taskId;
        // the expiration block number for the task
        uint256 expireByBlockNumber;
        // the operators that have signed the task
        address[] signerAddresses;
        // the signatures of the operators that have signed the task
        bytes[] signatures;
    }

    // ========================================= ECO =========================================
    // Eco Portal reward, for the publishAndFund(uint64,bytes,Reward,bool) overload (route passed as opaque bytes).
    // The `Eco` prefix does not affect the selector, which depends only on the tuple layout.
    struct EcoTokenAmount {
        address token;
        uint256 amount;
    }

    struct EcoReward {
        uint64 deadline;
        address creator;
        address prover;
        uint256 nativeAmount;
        EcoTokenAmount[] tokens;
    }

    // ========================================= 0x SETTLER =========================================

    struct SettlerAllowedSlippage {
        address recipient;
        address buyToken;
        uint256 minAmountOut;
    }

    struct Permit2TokenPermissions {
        address token;
        uint256 amount;
    }

    struct Permit2PermitTransferFrom {
        Permit2TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

}
