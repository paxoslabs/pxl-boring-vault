// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { AccountantWithRateProviders } from "./../../../src/base/Roles/AccountantWithRateProviders.sol";
import {
    MultiChainLayerZeroTellerWithMultiAssetSupport
} from "./../../../src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol";
import { BaseScript } from "./../../Base.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { console2 } from "@forge-std/console2.sol";

contract DeployMultiChainLayerZeroTellerWithMultiAssetSupport is BaseScript {

    using StdJson for string;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct UlnConfig {
        uint64 confirmations;
        // we store the length of required DVNs and optional DVNs instead of using DVN.length directly to save gas
        uint8 requiredDVNCount; // 0 indicate DEFAULT, NIL_DVN_COUNT indicate NONE (to override the value of default)
        uint8 optionalDVNCount; // 0 indicate DEFAULT, NIL_DVN_COUNT indicate NONE (to override the value of default)
        uint8 optionalDVNThreshold; // (0, optionalDVNCount]
        address[] requiredDVNs; // no duplicates. sorted an an ascending order. allowed overlap with optionalDVNs
        address[] optionalDVNs; // no duplicates. sorted an an ascending order. allowed overlap with requiredDVNs
    }

    function run() public returns (address teller) {
        return deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Get Config Values

        // Require config Values
        require(config.boringVault.code.length != 0, "boringVault must have code");
        require(config.accountant.code.length != 0, "accountant must have code");
        bytes32 tellerSalt = makeSalt(
            broadcaster,
            false,
            string(
                abi.encodePacked(
                    config.nameEntropy,
                    ":MultiChainLayerZeroTellerWithMultiAssetSupport",
                    config.tellerModuleSpecificNameEntropy
                )
            )
        );
        require(config.boringVault != address(0), "boringVault");
        require(config.accountant != address(0), "accountant");

        // Create Contract
        bytes memory creationCode = type(MultiChainLayerZeroTellerWithMultiAssetSupport).creationCode;
        MultiChainLayerZeroTellerWithMultiAssetSupport teller = MultiChainLayerZeroTellerWithMultiAssetSupport(
            CREATEX.deployCreate3(
                tellerSalt,
                abi.encodePacked(
                    creationCode, abi.encode(broadcaster, config.boringVault, config.accountant, config.lzEndpoint)
                )
            )
        );

        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(config.lzEndpoint);

        // Only configure the peers, chain, libraries and DVNs if made to do so.
        // The endpoint is still set and the delegate sent to multisig regardless.
        // This is for situations where we want the LZ teller deployed for possible future integrations, but with no
        // possible interaction even from poisoned DVNs, considering our own receive function reverts if a possible
        // matching chain/peer isn't provided.
        if (config.setupLZConfigs) {
            require(config.peerEid != 0, "If configuring LZ, peerEid must not be 0");
            console2.log("setting up LZ configs...");
            // configure the crosschain functionality, assume same address
            bytes32 leftPaddedBytes32Peer = addressToBytes32LeftPad(address(teller));

            // this number = 1 << (8*20)
            // an address cannot take up more than 20 bytes and thus 1 shifted 20 bytes right should be larger than any
            // number address can be if padded correctly
            require(
                leftPaddedBytes32Peer < 0x0000000000000000000000010000000000000000000000000000000000000000,
                "Address not left padded correctly"
            );

            teller.setPeer(config.peerEid, leftPaddedBytes32Peer);
            teller.addChain(config.peerEid, true, true, address(teller), config.maxGasForPeer, config.minGasForPeer);

            // get the default libraries for the peer
            address sendLib = endpoint.defaultSendLibrary(config.peerEid);
            address receiveLib = endpoint.defaultReceiveLibrary(config.peerEid);
            require(sendLib != address(0), "sendLib = 0, check peerEid");
            require(receiveLib != address(0), "receiveLib = 0, check peerEid");

            // check if a default config exists for these libraries and if not set the config
            _checkUlnConfig(address(teller), config, sendLib);
            _checkUlnConfig(address(teller), config, receiveLib);

            // confirm the library is set
            sendLib = endpoint.getSendLibrary(address(teller), config.peerEid);
            (receiveLib,) = endpoint.getReceiveLibrary(address(teller), config.peerEid);
            require(sendLib != address(0), "No sendLib");
            require(receiveLib != address(0), "no receiveLib");
        } else {
            console2.log(
                "Skipping configuration of LZ Teller. Must configure manually in the future from protocol admin: ",
                config.protocolAdmin
            );
        }

        // transfer delegate to the multisig
        teller.setDelegate(config.protocolAdmin);

        // Post Deploy Checks
        require(teller.shareLockPeriod() == 0, "share lock period must be zero");
        require(teller.isPaused() == false, "the teller must not be paused");
        require(
            AccountantWithRateProviders(teller.accountant()).vault() == teller.vault(),
            "the accountant vault must be the teller vault"
        );
        require(address(endpoint) == config.lzEndpoint, "LZ Teller must have endpoint set");

        return address(teller);
    }

    function _checkUlnConfig(address newTeller, ConfigReader.Config memory config, address lib) internal {
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(config.lzEndpoint);

        bytes memory configBytes = endpoint.getConfig(newTeller, lib, config.peerEid, 2);
        UlnConfig memory ulnConfig = abi.decode(configBytes, (UlnConfig));

        uint8 numRequiredDVN = ulnConfig.requiredDVNCount;
        uint8 numOptionalDVN = ulnConfig.optionalDVNCount;
        bool isDead;

        for (uint256 i; i < numRequiredDVN; ++i) {
            if (ulnConfig.requiredDVNs[i] == DEAD) {
                isDead = true;
            }
        }

        for (uint256 i; i < numOptionalDVN; ++i) {
            if (ulnConfig.optionalDVNs[i] == DEAD) {
                isDead = true;
            }
        }

        // if no dead address in the ulnConfig, there is a default onchain configuration we can use. However, only
        // prompt to notify user and always set to configured params.
        if (!isDead) {
            console2.log(
                "A default onchain configuration is provided. Regardless, we will be using the the params provided in the config file"
            );
        } else {
            console2.log(
                "No default configuration for this chain/peerEid combination. Using params provided in config file"
            );
        }
        // Use what's in the config file regardless of default configuration
        _setConfig(newTeller, endpoint, lib, config);
    }

    function _setConfig(
        address newTeller,
        ILayerZeroEndpointV2 endpoint,
        address lib,
        ConfigReader.Config memory config
    )
        internal
    {
        require(config.dvnBlockConfirmationsRequired != 0, "dvn block confirmations 0");
        require(config.requiredDvns.length != 0, "no required dvns");

        // sort the dvns
        config.requiredDvns = sortAddresses(config.requiredDvns);
        config.optionalDvns = sortAddresses(config.optionalDvns);

        require(
            config.requiredDvns.length + config.optionalDvnThreshold > 2, "DEPLOY_06b_setConfig() DVN Count Must Be > 2"
        );

        require(
            config.optionalDvnThreshold <= config.optionalDvns.length,
            "Optional DVN threshold is larger than the number of optional DVNs provided"
        );

        bytes memory ulnConfigBytes = abi.encode(
            UlnConfig(
                config.dvnBlockConfirmationsRequired,
                uint8(config.requiredDvns.length),
                uint8(config.optionalDvns.length),
                config.optionalDvnThreshold,
                config.requiredDvns,
                config.optionalDvns
            )
        );

        SetConfigParam[] memory setConfigParams = new SetConfigParam[](1);
        setConfigParams[0] = SetConfigParam(config.peerEid, 2, ulnConfigBytes);
        endpoint.setConfig(newTeller, lib, setConfigParams);
    }

    function sortAddresses(address[] memory addresses) internal pure returns (address[] memory) {
        uint256 length = addresses.length;
        if (length < 2) return addresses;

        for (uint256 i; i < length - 1; ++i) {
            for (uint256 j; j < length - i - 1; ++j) {
                if (addresses[j] > addresses[j + 1]) {
                    address temp = addresses[j];
                    addresses[j] = addresses[j + 1];
                    addresses[j + 1] = temp;
                }
            }
        }
        return addresses;
    }

    function addressToBytes32LeftPad(address addr) internal returns (bytes32 leftPadBytes32) {
        leftPadBytes32 = bytes32(bytes20(addr)) >> 0x60;
    }

}
