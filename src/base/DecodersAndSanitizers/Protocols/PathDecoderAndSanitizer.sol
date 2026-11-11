// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

abstract contract PathDecoderAndSanitizer is BaseDecoderAndSanitizer {

    // @desc Burn Paxos tokens through the PATH CrossChainBridgeMessenger to bridge them to another chain
    // @tag burnToken:address:the Paxos token to burn
    // @tag destinationChainId:uint16:the Paxos-internal PATH chain ID of the destination, not the EIP-155 chain ID
    // @tag destinationAddress:bytes32:the recipient on the destination chain; EVM addresses are left-padded with zeros
    // @tag features:uint64:informational bitmask for backend processing; does not affect minting
    function sendTo(
        address burnToken,
        uint256,
        uint16 destinationChainId,
        bytes32 destinationAddress,
        uint64 features
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(burnToken, destinationChainId, destinationAddress, features);
    }

    // @desc Complete a PATH transfer by minting to the recipient set in the attestation
    function completeSend(
        bytes calldata,
        bytes calldata,
        bytes calldata,
        uint128,
        uint64
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        // Nothing to decode. Anyone may call as long as they have valid attestation data from PATH
        return addressesFound;
    }

}
