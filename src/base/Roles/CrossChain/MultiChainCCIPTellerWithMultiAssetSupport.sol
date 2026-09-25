// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IAny2EVMMessageReceiver } from "@chainlink/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import { IAny2EVMMessageReceiverV2 } from "@chainlink/ccip/interfaces/IAny2EVMMessageReceiverV2.sol";
import { IRouterClient } from "@chainlink/ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/ccip/libraries/Client.sol";
import { ExtraArgsCodec } from "@chainlink/ccip/libraries/ExtraArgsCodec.sol";
import { FinalityCodec } from "@chainlink/ccip/libraries/FinalityCodec.sol";
import { RateLimiter } from "@chainlink/ccip/libraries/RateLimiter.sol";
import {
    Chain,
    MultiChainTellerBase,
    MultiChainTellerBase_MessagesNotAllowedFrom,
    MultiChainTellerBase_MessagesNotAllowedFromSender
} from "src/base/Roles/CrossChain/MultiChainTellerBase.sol";
import { BridgeData } from "src/interfaces/ICrossChainTypes.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

/// @title MultiChainCCIPTellerWithMultiAssetSupport
/// @notice Chainlink CCIP adapter for Boring Vault `MultiChainTellerBase` share bridging.
/// @dev Native-fee, data-only CCIP v2 adapter. Base Teller `uint32` chain selectors are compatibility keys that map to
/// CCIP `uint64` selectors without unsafe truncation.
contract MultiChainCCIPTellerWithMultiAssetSupport is MultiChainTellerBase, IAny2EVMMessageReceiverV2, IERC165 {

    using RateLimiter for RateLimiter.TokenBucket;

    /// @dev CCIP uses `address(0)` to indicate native-token fee payment in `EVM2AnyMessage`.
    address internal constant CCIP_NATIVE_FEE_TOKEN = address(0);

    /// @notice Chainlink CCIP router used for fee quoting, outbound sends, and inbound router authentication.
    IRouterClient public immutable router;

    /// @notice Maps Base Teller `uint32` chain-selector keys to Chainlink CCIP `uint64` chain selectors.
    mapping(uint32 baseTellerChainSelector => uint64 ccipChainSelector) public chainSelectorToCcipSelector;

    /// @notice Maps Chainlink CCIP `uint64` chain selectors back to Base Teller `uint32` chain-selector keys.
    mapping(uint64 ccipChainSelector => uint32 baseTellerChainSelector) public ccipSelectorToChainSelector;

    /// @notice Requested finality for outbound CCIP messages, keyed by destination Base Teller chain selector.
    mapping(uint32 destinationChainSelector => bytes4 requestedFinalityConfig) public ccipOutboundFinalityConfig;

    /// @notice Allowed finality for inbound CCIP messages, keyed by source Base Teller chain selector.
    mapping(uint32 sourceChainSelector => bytes4 allowedFinalityConfig) public ccipInboundFinalityConfig;

    /// @notice Outbound share bridge rate limiters, keyed by destination Base Teller chain selector.
    mapping(uint32 destinationChainSelector => RateLimiter.TokenBucket) internal ccipOutboundRateLimiters;

    /// @notice Inbound share mint rate limiters, keyed by source Base Teller chain selector.
    mapping(uint32 sourceChainSelector => RateLimiter.TokenBucket) internal ccipInboundRateLimiters;

    event CcipChainSelectorSet(uint32 indexed baseTellerChainSelector, uint64 indexed ccipChainSelector);
    event CcipOutboundFinalityConfigSet(uint32 indexed destinationChainSelector, bytes4 requestedFinalityConfig);
    event CcipInboundFinalityConfigSet(uint32 indexed sourceChainSelector, bytes4 allowedFinalityConfig);
    event CcipChainConfigReset(uint32 indexed baseTellerChainSelector, uint64 indexed ccipChainSelector);
    event CcipRateLimiterConfigSet(
        uint32 indexed chainSelector,
        RateLimiter.Config outboundRateLimiterConfig,
        RateLimiter.Config inboundRateLimiterConfig
    );

    error InvalidRouter();
    error InvalidBridgeFeeToken();
    error InvalidChainSelector();
    error CcipChainStillActive(uint32 chainSelector);
    error CallerMustBeRouter(address caller);
    error InvalidSenderBytes(bytes sender);
    error UnexpectedTokenAmounts();
    error ZeroAddressDestinationReceiver();
    error IncorrectNativeFee(uint256 requiredFee, uint256 providedFee);
    error MessageGasLimitTooHigh(uint64 messageGas);
    error NonZeroShareLockPeriod(uint64 shareLockPeriod);
    error InvalidExtraArgsTag();

    /// @param _owner Teller owner/auth root.
    /// @param _vault BoringVault share token.
    /// @param _accountant Accountant used by the teller base.
    /// @param _router Chainlink CCIP router.
    constructor(
        address _owner,
        address _vault,
        address _accountant,
        IRouterClient _router
    )
        MultiChainTellerBase(_owner, _vault, _accountant)
    {
        if (address(_router) == address(0)) revert InvalidRouter();
        router = _router;
    }

    /// @notice Sets the Base Teller selector-key to CCIP selector mapping used for sends and receives.
    /// @dev Callable by Owner. Reassigning either side clears stale reverse/forward mappings to keep the mapping
    /// one-to-one. Remapping is rejected while the lane has either message direction enabled so the selector mappings
    /// and the inherited `Chain` row can never diverge on an active lane; stealing a CCIP selector still owned by
    /// another active lane is rejected for the same reason.
    /// @param baseTellerChainSelector Base Teller `MultiChainTellerBase` chain-selector key.
    /// @param ccipChainSelector Chainlink CCIP chain selector.
    function setCcipChainSelector(uint32 baseTellerChainSelector, uint64 ccipChainSelector) external requiresAuth {
        if (baseTellerChainSelector == 0 || ccipChainSelector == 0) {
            revert InvalidChainSelector();
        }

        Chain memory chain = selectorToChains[baseTellerChainSelector];
        if (chain.allowMessagesFrom || chain.allowMessagesTo) {
            revert CcipChainStillActive(baseTellerChainSelector);
        }

        uint64 oldCcipSelector = chainSelectorToCcipSelector[baseTellerChainSelector];
        if (oldCcipSelector != 0) delete ccipSelectorToChainSelector[oldCcipSelector];

        uint32 oldBaseTellerSelector = ccipSelectorToChainSelector[ccipChainSelector];
        if (oldBaseTellerSelector != 0) {
            Chain memory oldChain = selectorToChains[oldBaseTellerSelector];
            if (oldChain.allowMessagesFrom || oldChain.allowMessagesTo) {
                revert CcipChainStillActive(oldBaseTellerSelector);
            }
            delete chainSelectorToCcipSelector[oldBaseTellerSelector];
        }

        chainSelectorToCcipSelector[baseTellerChainSelector] = ccipChainSelector;
        ccipSelectorToChainSelector[ccipChainSelector] = baseTellerChainSelector;

        emit CcipChainSelectorSet(baseTellerChainSelector, ccipChainSelector);
    }

    /// @notice Sets the finality requested by outbound messages to a configured destination chain.
    /// @dev Defaults to `WAIT_FOR_FINALITY_FLAG` when unset. Requested finality must select exactly one mode.
    /// @param destinationChainSelector Base Teller `MultiChainTellerBase` destination chain-selector key.
    /// @param requestedFinalityConfig Requested finality encoded with `FinalityCodec`.
    function setCcipOutboundFinalityConfig(
        uint32 destinationChainSelector,
        bytes4 requestedFinalityConfig
    )
        external
        requiresAuth
    {
        if (destinationChainSelector == 0) revert InvalidChainSelector();
        FinalityCodec._validateRequestedFinality(requestedFinalityConfig);

        ccipOutboundFinalityConfig[destinationChainSelector] = requestedFinalityConfig;
        emit CcipOutboundFinalityConfigSet(destinationChainSelector, requestedFinalityConfig);
    }

    /// @notice Sets the finality accepted for inbound messages from a configured source chain and trusted teller.
    /// @dev Defaults to `WAIT_FOR_FINALITY_FLAG` when unset.
    /// @param sourceChainSelector Base Teller `MultiChainTellerBase` source chain-selector key.
    /// @param allowedFinalityConfig Allowed finality encoded with `FinalityCodec`.
    function setCcipInboundFinalityConfig(
        uint32 sourceChainSelector,
        bytes4 allowedFinalityConfig
    )
        external
        requiresAuth
    {
        if (sourceChainSelector == 0) revert InvalidChainSelector();

        ccipInboundFinalityConfig[sourceChainSelector] = allowedFinalityConfig;
        emit CcipInboundFinalityConfigSet(sourceChainSelector, allowedFinalityConfig);
    }

    /// @notice Sets the inbound and outbound share-amount rate limiters for a configured chain.
    /// @dev Defaults to disabled. Capacity and rate use BoringVault share decimals.
    /// @param chainSelector Base Teller `MultiChainTellerBase` chain-selector key.
    /// @param outboundRateLimiterConfig Outbound token-bucket configuration.
    /// @param inboundRateLimiterConfig Inbound token-bucket configuration.
    function setCcipRateLimiterConfig(
        uint32 chainSelector,
        RateLimiter.Config calldata outboundRateLimiterConfig,
        RateLimiter.Config calldata inboundRateLimiterConfig
    )
        external
        requiresAuth
    {
        if (chainSelector == 0) revert InvalidChainSelector();

        ccipOutboundRateLimiters[chainSelector]._setTokenBucketConfig(outboundRateLimiterConfig);
        ccipInboundRateLimiters[chainSelector]._setTokenBucketConfig(inboundRateLimiterConfig);
        emit CcipRateLimiterConfigSet(chainSelector, outboundRateLimiterConfig, inboundRateLimiterConfig);
    }

    /// @notice Clears all adapter-side configuration for a disabled Base Teller chain selector.
    /// @dev Disable both message directions and reconcile in-flight messages before resetting a lane.
    function resetCcipChainConfig(uint32 chainSelector) external requiresAuth {
        if (chainSelector == 0) revert InvalidChainSelector();
        Chain memory chain = selectorToChains[chainSelector];
        if (chain.allowMessagesFrom || chain.allowMessagesTo) revert CcipChainStillActive(chainSelector);

        uint64 ccipChainSelector = chainSelectorToCcipSelector[chainSelector];
        if (ccipSelectorToChainSelector[ccipChainSelector] == chainSelector) {
            delete ccipSelectorToChainSelector[ccipChainSelector];
        }
        delete chainSelectorToCcipSelector[chainSelector];
        delete ccipOutboundFinalityConfig[chainSelector];
        delete ccipInboundFinalityConfig[chainSelector];
        delete ccipOutboundRateLimiters[chainSelector];
        delete ccipInboundRateLimiters[chainSelector];

        emit CcipChainConfigReset(chainSelector, ccipChainSelector);
    }

    /// @notice Returns the current outbound and inbound rate limiter state for a chain.
    function getCurrentCcipRateLimiterState(uint32 chainSelector)
        external
        view
        returns (RateLimiter.TokenBucket memory outboundRateLimiter, RateLimiter.TokenBucket memory inboundRateLimiter)
    {
        return (
            ccipOutboundRateLimiters[chainSelector]._currentTokenBucketState(),
            ccipInboundRateLimiters[chainSelector]._currentTokenBucketState()
        );
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IAny2EVMMessageReceiverV2).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function getCCVsAndFinalityConfig(
        uint64 sourceChainSelector,
        bytes calldata sender
    )
        external
        view
        override
        returns (
            address[] memory requiredCCVs,
            address[] memory optionalCCVs,
            uint8 optionalThreshold,
            bytes4 allowedFinalityConfig
        )
    {
        allowedFinalityConfig = FinalityCodec.WAIT_FOR_FINALITY_FLAG;
        uint32 baseTellerSourceSelector = ccipSelectorToChainSelector[sourceChainSelector];
        if (baseTellerSourceSelector != 0 && sender.length == 32) {
            Chain memory chain = selectorToChains[baseTellerSourceSelector];
            if (chain.allowMessagesFrom && keccak256(sender) == keccak256(abi.encode(chain.targetTeller))) {
                allowedFinalityConfig = ccipInboundFinalityConfig[baseTellerSourceSelector];
            }
        }

        return (new address[](0), new address[](0), 0, allowedFinalityConfig);
    }

    /// @notice Receives a CCIP message and mints BoringVault shares to the encoded destination receiver.
    /// @dev Only the configured CCIP router may call this function. The CCIP source selector is mapped to the Base
    /// Teller selector key before applying the existing chain allowlist and target teller checks.
    /// @param message CCIP Any2EVM message containing `abi.encode(uint256 shareAmount, address receiver)`.
    function ccipReceive(Client.Any2EVMMessage calldata message) external override {
        if (msg.sender != address(router)) {
            revert CallerMustBeRouter(msg.sender);
        }

        uint32 baseTellerSourceSelector = ccipSelectorToChainSelector[message.sourceChainSelector];
        if (baseTellerSourceSelector == 0) revert InvalidChainSelector();

        Chain memory chain = selectorToChains[baseTellerSourceSelector];
        if (!chain.allowMessagesFrom) revert MultiChainTellerBase_MessagesNotAllowedFrom(baseTellerSourceSelector);

        if (message.sender.length != 32) revert InvalidSenderBytes(message.sender);
        address sender = abi.decode(message.sender, (address));
        if (sender != chain.targetTeller) {
            revert MultiChainTellerBase_MessagesNotAllowedFromSender(uint256(baseTellerSourceSelector), sender);
        }
        if (message.destTokenAmounts.length != 0) revert UnexpectedTokenAmounts();

        (uint256 shareAmount, address receiver) = abi.decode(message.data, (uint256, address));
        _beforeReceive(shareAmount, receiver);

        if (receiver == address(0)) revert ZeroAddressDestinationReceiver();

        ccipInboundRateLimiters[baseTellerSourceSelector]._consume(shareAmount, address(vault));
        vault.enter(address(0), ERC20(address(0)), 0, receiver, shareAmount);
        _afterReceive(shareAmount, receiver, message.messageId);
    }

    /// @dev Quotes CCIP transport only; caller-specific and mutable bridge preconditions are enforced by `bridge`.
    function _quote(uint256 shareAmount, BridgeData calldata data) internal view override returns (uint256) {
        if (address(data.bridgeFeeToken) != NATIVE) {
            revert InvalidBridgeFeeToken();
        }

        uint64 ccipSelector = _ccipSelector(data.chainSelector);
        bytes4 requestedFinalityConfig = ccipOutboundFinalityConfig[data.chainSelector];
        Client.EVM2AnyMessage memory message = _buildMessage(shareAmount, data, requestedFinalityConfig);
        (, uint256 fee) = _quoteMessageFee(
            ccipSelector, message, data.messageGas, requestedFinalityConfig == FinalityCodec.WAIT_FOR_FINALITY_FLAG
        );
        return fee;
    }

    function _bridge(uint256 shareAmount, BridgeData calldata data) internal override returns (bytes32 messageId) {
        if (shareLockPeriod != 0) revert NonZeroShareLockPeriod(shareLockPeriod);
        if (address(data.bridgeFeeToken) != NATIVE) {
            revert InvalidBridgeFeeToken();
        }

        uint64 ccipSelector = _ccipSelector(data.chainSelector);
        bytes4 requestedFinalityConfig = ccipOutboundFinalityConfig[data.chainSelector];
        Client.EVM2AnyMessage memory message = _buildMessage(shareAmount, data, requestedFinalityConfig);
        uint256 fee;
        (message, fee) = _quoteMessageFee(
            ccipSelector, message, data.messageGas, requestedFinalityConfig == FinalityCodec.WAIT_FOR_FINALITY_FLAG
        );
        if (msg.value != fee) {
            revert IncorrectNativeFee(fee, msg.value);
        }

        ccipOutboundRateLimiters[data.chainSelector]._consume(shareAmount, address(vault));
        messageId = router.ccipSend{ value: fee }(ccipSelector, message);
    }

    function _buildMessage(
        uint256 shareAmount,
        BridgeData calldata data,
        bytes4 requestedFinalityConfig
    )
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        return Client.EVM2AnyMessage({
            receiver: abi.encode(selectorToChains[data.chainSelector].targetTeller),
            data: abi.encode(shareAmount, data.destinationChainReceiver),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: CCIP_NATIVE_FEE_TOKEN,
            extraArgs: ExtraArgsCodec._getBasicEncodedExtraArgsV3(
                _ccipGasLimit(data.messageGas), requestedFinalityConfig
            )
        });
    }

    function _quoteMessageFee(
        uint64 ccipSelector,
        Client.EVM2AnyMessage memory message,
        uint64 messageGas,
        bool allowLegacyFallback
    )
        internal
        view
        returns (Client.EVM2AnyMessage memory, uint256)
    {
        try router.getFee(ccipSelector, message) returns (uint256 fee) {
            return (message, fee);
        } catch (bytes memory reason) {
            if (!_isInvalidExtraArgsTagRevert(reason)) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }

            if (!allowLegacyFallback) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }

            message.extraArgs = _legacyExtraArgs(messageGas);
            return (message, router.getFee(ccipSelector, message));
        }
    }

    function _legacyExtraArgs(uint64 messageGas) internal pure returns (bytes memory) {
        return Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: messageGas }));
    }

    function _isInvalidExtraArgsTagRevert(bytes memory reason) internal pure returns (bool) {
        if (reason.length < 4) return false;

        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }

        if (selector == InvalidExtraArgsTag.selector) return reason.length == 4;
        if (selector != ExtraArgsCodec.InvalidExtraArgsTag.selector || reason.length != 68) return false;

        uint256 expectedWord;
        uint256 actualWord;
        assembly ("memory-safe") {
            expectedWord := mload(add(reason, 0x24))
            actualWord := mload(add(reason, 0x44))
        }
        if (uint224(expectedWord) != 0 || uint224(actualWord) != 0) return false;

        return bytes4(uint32(actualWord >> 224)) == ExtraArgsCodec.GENERIC_EXTRA_ARGS_V3_TAG;
    }

    function _ccipGasLimit(uint64 messageGas) internal pure returns (uint32) {
        if (messageGas > type(uint32).max) revert MessageGasLimitTooHigh(messageGas);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(messageGas);
    }

    function _ccipSelector(uint32 baseTellerChainSelector) internal view returns (uint64 ccipSelector) {
        ccipSelector = chainSelectorToCcipSelector[baseTellerChainSelector];
        if (ccipSelector == 0) revert InvalidChainSelector();
    }

}
