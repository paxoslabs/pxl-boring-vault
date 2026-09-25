// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IAny2EVMMessageReceiver } from "@chainlink/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import { IRouterClient } from "@chainlink/ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/ccip/libraries/Client.sol";
import { ExtraArgsCodec } from "@chainlink/ccip/libraries/ExtraArgsCodec.sol";

contract MockRouterClient is IRouterClient {

    error InvalidExtraArgsTag();
    error MessageAlreadyRouted(bytes32 messageId);

    uint256 public fee;
    uint64 public lastDestinationChainSelector;
    bytes32 public lastMessageId;
    bytes public lastReceiver;
    bytes public lastData;
    bytes public lastExtraArgs;
    address public lastFeeToken;
    uint256 public lastMsgValue;
    bytes4 public rejectedExtraArgsTag;
    bool public useTypedExtraArgsTagError;
    bool public revertFeeQuoteWithoutReason;
    bytes public feeQuoteRevertReason;
    mapping(bytes32 messageId => bool routed) public routedMessages;

    constructor(uint256 fee_) {
        fee = fee_;
    }

    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory message) external view returns (uint256) {
        if (revertFeeQuoteWithoutReason) revert();
        bytes memory reason = feeQuoteRevertReason;
        if (reason.length != 0) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        _requireSupportedExtraArgs(message.extraArgs);
        return fee;
    }

    function ccipSend(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage calldata message
    )
        external
        payable
        returns (bytes32)
    {
        _requireSupportedExtraArgs(message.extraArgs);

        lastDestinationChainSelector = destinationChainSelector;
        lastReceiver = message.receiver;
        lastData = message.data;
        lastExtraArgs = message.extraArgs;
        lastFeeToken = message.feeToken;
        lastMsgValue = msg.value;
        lastMessageId = keccak256(abi.encode(destinationChainSelector, msg.sender, block.number));
        return lastMessageId;
    }

    function routeMessage(address receiver, Client.Any2EVMMessage calldata message) external {
        if (routedMessages[message.messageId]) revert MessageAlreadyRouted(message.messageId);
        IAny2EVMMessageReceiver(receiver).ccipReceive(message);
        routedMessages[message.messageId] = true;
    }

    function setRejectedExtraArgsTag(bytes4 rejectedExtraArgsTag_) external {
        rejectedExtraArgsTag = rejectedExtraArgsTag_;
    }

    function setUseTypedExtraArgsTagError(bool useTypedExtraArgsTagError_) external {
        useTypedExtraArgsTagError = useTypedExtraArgsTagError_;
    }

    function setRevertFeeQuoteWithoutReason(bool revertFeeQuoteWithoutReason_) external {
        revertFeeQuoteWithoutReason = revertFeeQuoteWithoutReason_;
    }

    function setFeeQuoteRevertReason(bytes calldata feeQuoteRevertReason_) external {
        feeQuoteRevertReason = feeQuoteRevertReason_;
    }

    function _requireSupportedExtraArgs(bytes memory extraArgs) internal view {
        bytes4 tag = rejectedExtraArgsTag;
        if (tag == bytes4(0) || _readExtraArgsTag(extraArgs) != tag) return;

        if (useTypedExtraArgsTagError) {
            revert ExtraArgsCodec.InvalidExtraArgsTag(bytes4(0), tag);
        }
        revert InvalidExtraArgsTag();
    }

    function _readExtraArgsTag(bytes memory extraArgs) internal pure returns (bytes4 tag) {
        if (extraArgs.length < 4) return tag;

        assembly ("memory-safe") {
            tag := mload(add(extraArgs, 0x20))
        }
    }

}
