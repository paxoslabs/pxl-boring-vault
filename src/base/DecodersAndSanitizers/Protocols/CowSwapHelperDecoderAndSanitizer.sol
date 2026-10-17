// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { CowSwapHelper } from "src/helper/cow-swap/CowSwapHelper.sol";

/**
 * @title CowSwapHelperDecoderAndSanitizer
 * @notice Decodes and sanitizes the vault's calls into `CowSwapHelper` for `ManagerWithMerkleVerification`.
 *         For each supported call it returns the argument values that the manager folds into the merkle leaf,
 *         so that only strategist actions matching an authorized leaf can execute.
 * @dev `CowSwapHelper` enforces a price floor on the orders it places, but it computes that floor
 *      using the `rateProvider`, `rateDecimals`, and `maxSlippageBps` its caller supplies.
 *
 *      `sellAmount`, `buyAmount`, and `validTo` are deliberately left unpinned, as the helper's floor check
 *      ties `buyAmount` to `sellAmount` through the pinned oracle.
 */
abstract contract CowSwapHelperDecoderAndSanitizer is BaseDecoderAndSanitizer {

    // @desc Place a CoW order via CowSwapHelper. Pins the sell/buy tokens, the rate provider, the rate's
    //       decimals, the numeric slippage bound, and the partial-fill flag; the per-order amounts and expiry
    //       are left free.
    // @tag sellToken:address:token the vault is selling
    // @tag buyToken:address:token the vault is buying
    // @tag rateProvider:address:oracle the price floor is derived from
    // @tag rateDecimals:uint8:fixed-point decimals the oracle rate is expressed in
    // @tag maxSlippageBps:uint256:tolerated slippage below the oracle rate, in basis points
    // @tag partiallyFillable:bool:whether the order may be filled in parts
    function placeOrder(CowSwapHelper.OrderParams calldata params) external pure returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(
            address(params.sellToken),
            address(params.buyToken),
            address(params.rateProvider),
            params.rateDecimals,
            params.maxSlippageBps,
            params.partiallyFillable
        );
    }

    // @desc Cancel a previously placed CoW order (clears the helper's pre-signature).
    function cancelOrder(bytes calldata) external pure returns (bytes memory addressesFound) {
        // Nothing to decode: orderUid is an opaque hash and cancellation only clears the helper's own
        // pre-signature.
    }

    // @desc Sweep an amount of `token` from the helper back to the vault.
    function sweepToken(address, uint256) external pure returns (bytes memory addressesFound) {
        // Token left unpinned: the sweep always sends to the vault, so it needn't be restricted.
    }

}
