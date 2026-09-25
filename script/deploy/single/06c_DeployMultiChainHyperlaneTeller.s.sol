// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { AccountantWithRateProviders } from "./../../../src/base/Roles/AccountantWithRateProviders.sol";
import {
    MultiChainHyperlaneTellerWithMultiAssetSupport
} from "./../../../src/base/Roles/CrossChain/MultiChainHyperlaneTellerWithMultiAssetSupport.sol";
import { IMailbox } from "./../../../src/interfaces/hyperlane/IMailbox.sol";
import { BaseScript } from "./../../Base.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { console2 } from "@forge-std/console2.sol";

contract DeployMultiChainHyperlaneTeller is BaseScript {

    using StdJson for string;

    function run() public returns (address teller) {
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
                    config.nameEntropy,
                    ":MultiChainHyperlaneTellerWithMultiAssetSupport",
                    config.tellerModuleSpecificNameEntropy
                )
            )
        );
        require(config.boringVault != address(0), "boringVault");
        require(config.accountant != address(0), "accountant");

        // Create Contract
        bytes memory creationCode = type(MultiChainHyperlaneTellerWithMultiAssetSupport).creationCode;
        MultiChainHyperlaneTellerWithMultiAssetSupport teller = MultiChainHyperlaneTellerWithMultiAssetSupport(
            CREATEX.deployCreate3(
                tellerSalt,
                abi.encodePacked(
                    creationCode, abi.encode(broadcaster, config.boringVault, config.accountant, config.mailbox)
                )
            )
        );

        teller.addChain(config.peerDomainId, true, true, address(teller), config.maxGasForPeer, config.minGasForPeer);

        IMailbox mailbox = teller.mailbox();

        // Post Deploy Checks
        require(teller.shareLockPeriod() == 0, "share lock period must be zero");
        require(teller.isPaused() == false, "the teller must not be paused");
        require(
            AccountantWithRateProviders(teller.accountant()).vault() == teller.vault(),
            "the accountant vault must be the teller vault"
        );
        require(address(mailbox) == config.mailbox, "mailbox must be set");

        return address(teller);
    }

}
