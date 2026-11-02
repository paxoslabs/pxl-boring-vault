// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

abstract contract FluidDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== FLUID ===============================

    // @desc Fluid DEX exact-in swap
    // @tag swap0to1:bool:true sells token0 for token1, false sells token1 for token0
    // @tag to:address:recipient of the output token; address(0) pays msg.sender
    function swapIn(
        bool swap0to1_,
        uint256,
        uint256,
        address to_
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(swap0to1_, to_);
    }

}
