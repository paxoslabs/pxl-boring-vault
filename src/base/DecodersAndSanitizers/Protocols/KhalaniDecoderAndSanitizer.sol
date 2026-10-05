// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {
    BaseDecoderAndSanitizer,
    DecoderCustomTypes
} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

interface ISettlerTakerSubmitted {

    function execute(
        DecoderCustomTypes.SettlerAllowedSlippage calldata slippage,
        bytes[] calldata actions,
        bytes32 zid
    )
        external
        payable
        returns (bool);

}

interface ISettlerActions {

    function TRANSFER_FROM(
        address recipient,
        DecoderCustomTypes.Permit2PermitTransferFrom memory permit,
        bytes memory sig
    )
        external;

    function RFQ(
        address recipient,
        DecoderCustomTypes.Permit2PermitTransferFrom memory permit,
        address maker,
        bytes memory makerSig,
        address takerToken,
        uint256 maxTakerAmount
    )
        external;

}

abstract contract KhalaniDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== ERRORS ===============================

    error UnexpectedSettlerCall(bytes4 selector);
    error UnexpectedActionCount(uint256 actionCount);
    error UnexpectedAction(uint256 index, bytes4 selector);
    error RfqTokenNotBuyToken(address rfqToken, address buyToken);

    //============================== KHALANI ===============================

    // @desc Khalani AssetReserves deposit
    // @tag token:address:the source spoke token deposited
    // @tag payloadType:bytes32:the Gateway conversion-deposit type hash
    // @tag integratorId:bytes32:the integrator identifier
    // @tag dstMToken:address:the destination spoke token
    // @tag payoutAddr:address:where the converted token is paid out
    // @tag refundAddr:address:where refunds go if the order fails
    // @tag totalMarginBps:uint16:sum of feeBps and lpMarginBps, this is the pre-determined margin of a swap for LPs
    function deposit(
        address token,
        uint256,
        bytes calldata conversionPayload,
        uint256
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        // conversionPayload = abi.encode(payloadType, integratorId, dstMToken, payoutAddr, refundAddr, nonce, feeBps,
        // totalMarginBps, deadline, operatorSig)
        (
            bytes32 payloadType,
            bytes32 integratorId,
            address dstMToken,
            address payoutAddr,
            address refundAddr,,,
            uint16 totalMarginBps,,
        ) = abi.decode(
            conversionPayload, (bytes32, bytes32, address, address, address, uint256, uint16, uint16, uint256, bytes)
        );
        addressesFound =
            abi.encodePacked(token, payloadType, integratorId, dstMToken, payoutAddr, refundAddr, totalMarginBps);
    }

    // @desc Khalani RFQ fill via 0x AllowanceHolder.exec into Settler.execute; actions must be exactly
    //       [TRANSFER_FROM, RFQ] and the maker's permitted token must be the slippage buyToken
    // @tag operator:address:the Settler allowed to pull the sell token through AllowanceHolder
    // @tag token:address:the sell token
    // @tag target:address:the Settler called with data
    // @tag slippageRecipient:address:receives the buy token from the Settler
    // @tag buyToken:address:the token bought
    // @tag transferFromRecipient:address:receives the vault's sell token
    // @tag rfqRecipient:address:receives the maker's buy token
    // @tag takerToken:address:the sell token the maker's coupon is signed over
    // @tag maker:address:the Khalani signer that supplies the buy token and receives the sell token
    function exec(
        address operator,
        address token,
        uint256,
        address target,
        bytes calldata data
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        bytes4 selector = bytes4(data);
        if (selector != ISettlerTakerSubmitted.execute.selector) {
            revert UnexpectedSettlerCall(selector);
        }
        (DecoderCustomTypes.SettlerAllowedSlippage memory slippage, bytes[] memory actions,) =
            abi.decode(data[4:], (DecoderCustomTypes.SettlerAllowedSlippage, bytes[], bytes32));
        if (actions.length != 2) revert UnexpectedActionCount(actions.length);

        if (bytes4(actions[0]) != ISettlerActions.TRANSFER_FROM.selector) {
            revert UnexpectedAction(0, bytes4(actions[0]));
        }
        if (bytes4(actions[1]) != ISettlerActions.RFQ.selector) revert UnexpectedAction(1, bytes4(actions[1]));

        (address transferFromRecipient,,) = abi.decode(
            _stripSelectorInPlace(actions[0]), (address, DecoderCustomTypes.Permit2PermitTransferFrom, bytes)
        );
        (address rfqRecipient, address makerToken, address maker, address takerToken) = _decodeRfqAction(actions[1]);
        // The RFQ action pays the maker's token straight to rfqRecipient; only buyToken is swept to
        // slippage.recipient, so any other token would bypass the leaf-approved buyToken.
        if (makerToken != slippage.buyToken) revert RfqTokenNotBuyToken(makerToken, slippage.buyToken);

        addressesFound = abi.encodePacked(
            operator,
            token,
            target,
            slippage.recipient,
            slippage.buyToken,
            transferFromRecipient,
            rfqRecipient,
            takerToken,
            maker
        );
    }

    /// @dev Consumes `action`; see `_stripSelectorInPlace`.
    function _decodeRfqAction(bytes memory action)
        internal
        pure
        returns (address recipient, address makerToken, address maker, address takerToken)
    {
        DecoderCustomTypes.Permit2PermitTransferFrom memory makerPermit;
        (recipient, makerPermit, maker,, takerToken,) = abi.decode(
            _stripSelectorInPlace(action),
            (address, DecoderCustomTypes.Permit2PermitTransferFrom, address, bytes, address, uint256)
        );
        makerToken = makerPermit.permitted.token;
    }

    /// @dev Memory equivalent of `action[4:]`. The result aliases `action` and overwrites its length word, so `action`
    ///      must not be read afterwards. Requires `action.length >= 4`.
    function _stripSelectorInPlace(bytes memory action) internal pure returns (bytes memory args) {
        /// @solidity memory-safe-assembly
        assembly {
            args := add(action, 4)
            mstore(args, sub(mload(action), 4))
        }
    }

}
