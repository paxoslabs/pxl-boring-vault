// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { AccountantWithRateProviders } from "./../../../src/base/Roles/AccountantWithRateProviders.sol";
import { TellerWithMultiAssetSupport } from "./../../../src/base/Roles/TellerWithMultiAssetSupport.sol";
import { MainnetAddresses } from "./../../../test/resources/MainnetAddresses.sol";
import { BaseScript } from "./../../Base.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";

contract DeployTellerWithMultiAssetSupport is BaseScript, MainnetAddresses {

    using StdJson for string;

    function run() public returns (address) {
        return deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values
        require(config.boringVault.code.length != 0, "boringVault must have code");
        require(config.accountant.code.length != 0, "accountant must have code");
        bytes32 tellerSalt = makeSalt(
            broadcaster,
            false,
            string(
                abi.encodePacked(
                    config.nameEntropy, ":TellerWithMultiAssetSupport", config.tellerModuleSpecificNameEntropy
                )
            )
        );
        require(config.boringVault != address(0), "boringVault");
        require(config.accountant != address(0), "accountant");

        // Create Contract
        bytes memory creationCode = type(TellerWithMultiAssetSupport).creationCode;
        TellerWithMultiAssetSupport teller = TellerWithMultiAssetSupport(
            CREATEX.deployCreate3(
                tellerSalt,
                abi.encodePacked(creationCode, abi.encode(broadcaster, config.boringVault, config.accountant))
            )
        );

        // Post Deploy Checks
        require(teller.shareLockPeriod() == 0, "share lock period must be zero");
        require(teller.isPaused() == false, "the teller must not be paused");
        require(
            AccountantWithRateProviders(teller.accountant()).vault() == teller.vault(),
            "the accountant vault must be the teller vault"
        );

        return address(teller);
    }

}
