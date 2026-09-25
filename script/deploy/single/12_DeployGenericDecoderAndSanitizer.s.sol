// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "./../../Base.s.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { GenericDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/GenericDecoderAndSanitizer.sol";
import { console } from "@forge-std/console.sol";

/**
 * Deploy the GenericDecoderAndSanitizer for the configured boring vault.
 * @dev The Uniswap V3 NonFungiblePositionManager address is sourced from the chain config under the
 * `uniswapV3NonFungiblePositionManager` key and is required by the constructor.
 */
contract DeployGenericDecoderAndSanitizer is BaseScript {

    function run() public returns (address) {
        return deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values
        require(config.boringVault != address(0), "boringVault must not be zero address");
        require(config.boringVault.code.length != 0, "boringVault must have code");
        require(
            config.uniswapV3NonFungiblePositionManager != address(0),
            "uniswapV3NonFungiblePositionManager must be set in chain config"
        );
        require(
            config.uniswapV3NonFungiblePositionManager.code.length != 0,
            "uniswapV3NonFungiblePositionManager must have code"
        );

        bytes32 salt = makeSalt(
            broadcaster,
            false,
            string(
                abi.encodePacked(
                    config.nameEntropy,
                    ":GenericDecoderAndSanitizer",
                    config.genericDecoderAndSanitizerModuleSpecificNameEntropy
                )
            )
        );

        bytes memory creationCode = type(GenericDecoderAndSanitizer).creationCode;
        address decoder = CREATEX.deployCreate3(
            salt,
            abi.encodePacked(creationCode, abi.encode(config.boringVault, config.uniswapV3NonFungiblePositionManager))
        );

        return decoder;
    }

}
