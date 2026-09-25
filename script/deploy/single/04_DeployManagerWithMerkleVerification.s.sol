// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ManagerWithMerkleVerification } from "./../../../src/base/Roles/ManagerWithMerkleVerification.sol";
import { BaseScript } from "./../../Base.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";

contract DeployManagerWithMerkleVerification is BaseScript {

    using StdJson for string;

    function run() public returns (address manager) {
        manager = deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values
        bytes32 managerSalt = makeSalt(
            broadcaster,
            false,
            string(
                abi.encodePacked(
                    config.nameEntropy, ":ManagerWithMerkleVerification", config.managerModuleSpecificNameEntropy
                )
            )
        );
        require(config.boringVault != address(0), "boring vault address must not be zero");
        require(address(config.boringVault).code.length != 0, "boring vault must have code");
        require(
            address(config.balancerVault).code.length != 0 || address(config.balancerVault) == address(0),
            "balancer vault must have code or be zero address"
        );

        // Create Contract
        bytes memory creationCode = type(ManagerWithMerkleVerification).creationCode;
        ManagerWithMerkleVerification manager = ManagerWithMerkleVerification(
            CREATEX.deployCreate3(
                managerSalt,
                abi.encodePacked(
                    creationCode,
                    abi.encode(
                        broadcaster,
                        config.boringVault,
                        config.balancerVault,
                        18 // decimals
                    )
                )
            )
        );

        // Post Deploy Checks
        require(manager.isPaused() == false, "the manager must not be paused");
        require(address(manager.vault()) == config.boringVault, "the manager vault must be the boring vault");
        require(
            address(manager.balancerVault()) == config.balancerVault,
            "the manager balancer vault must be the balancer vault"
        );

        return address(manager);
    }

}
