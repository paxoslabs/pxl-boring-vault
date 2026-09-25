// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import {
    MultiChainCCIPTellerWithMultiAssetSupport
} from "src/base/Roles/CrossChain/MultiChainCCIPTellerWithMultiAssetSupport.sol";
import { BaseScript } from "script/Base.s.sol";
import { RateLimiter } from "@chainlink/ccip/libraries/RateLimiter.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader } from "script/ConfigReader.s.sol";
import { console2 } from "@forge-std/console2.sol";

contract DeployMultiChainCCIPTeller is BaseScript {

    using StdJson for string;

    function run() public returns (address teller) {
        return deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values
        require(config.boringVault.code.length != 0, "boringVault must have code");
        require(config.accountant.code.length != 0, "accountant must have code");
        require(config.ccipRouter.code.length != 0, "ccipRouter must have code");
        bytes32 tellerSalt = makeSalt(
            broadcaster,
            false,
            string(
                abi.encodePacked(
                    config.nameEntropy,
                    ":MultiChainCCIPTellerWithMultiAssetSupport",
                    config.tellerModuleSpecificNameEntropy
                )
            )
        );
        require(config.boringVault != address(0), "boringVault");
        require(config.accountant != address(0), "accountant");

        // Create Contract
        bytes memory creationCode = type(MultiChainCCIPTellerWithMultiAssetSupport).creationCode;
        MultiChainCCIPTellerWithMultiAssetSupport teller = MultiChainCCIPTellerWithMultiAssetSupport(
            CREATEX.deployCreate3(
                tellerSalt,
                abi.encodePacked(
                    creationCode, abi.encode(broadcaster, config.boringVault, config.accountant, config.ccipRouter)
                )
            )
        );

        // Only configure the lane if made to do so. The router is wired regardless, leaving a teller that cannot send
        // or receive until the protocol admin opens a lane.
        if (config.setupCCIPConfigs) {
            require(config.peerChainId != 0, "If configuring CCIP, peerChainId must not be 0");
            require(config.peerCcipChainSelector != 0, "If configuring CCIP, peerCcipChainSelector must not be 0");
            // The teller rejects a bridge whose messageGas exceeds uint32 (MessageGasLimitTooHigh).
            require(config.maxGasForPeer <= type(uint32).max, "maxGasForPeer must fit in uint32");
            console2.log("setting up CCIP configs...");

            // assume the peer teller deploys to this same address
            teller.setCcipChainSelector(config.peerChainId, config.peerCcipChainSelector);
            teller.addChain(config.peerChainId, true, true, address(teller), config.maxGasForPeer, config.minGasForPeer);

            teller.setCcipOutboundFinalityConfig(config.peerChainId, bytes4(config.ccipOutboundFinality));
            teller.setCcipInboundFinalityConfig(config.peerChainId, bytes4(config.ccipInboundFinality));
            teller.setCcipRateLimiterConfig(
                config.peerChainId,
                RateLimiter.Config({
                    isEnabled: config.ccipOutboundRateLimitEnabled,
                    capacity: config.ccipOutboundRateLimitCapacity,
                    rate: config.ccipOutboundRateLimitRate
                }),
                RateLimiter.Config({
                    isEnabled: config.ccipInboundRateLimitEnabled,
                    capacity: config.ccipInboundRateLimitCapacity,
                    rate: config.ccipInboundRateLimitRate
                })
            );
        } else {
            console2.log(
                "Skipping configuration of CCIP Teller. Must configure manually in the future from protocol admin: ",
                config.protocolAdmin
            );
        }

        // Post Deploy Checks
        // A non-zero share lock period makes every bridge revert with NonZeroShareLockPeriod.
        require(teller.shareLockPeriod() == 0, "share lock period must be zero");
        require(teller.isPaused() == false, "the teller must not be paused");
        require(
            AccountantWithRateProviders(teller.accountant()).vault() == teller.vault(),
            "the accountant vault must be the teller vault"
        );
        require(address(teller.router()) == config.ccipRouter, "CCIP Teller must have router set");
        if (config.setupCCIPConfigs) {
            // Both directions, because setCcipChainSelector silently clears a stale mapping on either side.
            require(
                teller.chainSelectorToCcipSelector(config.peerChainId) == config.peerCcipChainSelector,
                "peer chain id must map to the CCIP selector"
            );
            require(
                teller.ccipSelectorToChainSelector(config.peerCcipChainSelector) == config.peerChainId,
                "CCIP selector must map back to the peer chain id"
            );
        }

        return address(teller);
    }

}
