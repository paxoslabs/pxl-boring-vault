// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BoringVault } from "./../../../src/base/BoringVault.sol";
import { BaseScript } from "./../../Base.s.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";

contract DeployIonBoringVaultScript is BaseScript {

    using StdJson for string;

    function run() public returns (address boringVault) {
        return deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values
        bytes32 boringVaultSalt = makeSalt(
            broadcaster,
            false,
            string(abi.encodePacked(config.nameEntropy, ":BoringVault", config.boringVaultModuleSpecificNameEntropy))
        );

        require(keccak256(bytes(config.boringVaultName)) != keccak256(bytes("")));
        require(keccak256(bytes(config.boringVaultSymbol)) != keccak256(bytes("")));

        // Create Contract
        bytes memory creationCode = type(BoringVault).creationCode;
        BoringVault boringVault = BoringVault(
            payable(CREATEX.deployCreate3(
                    boringVaultSalt,
                    abi.encodePacked(
                        creationCode,
                        abi.encode(
                            broadcaster,
                            config.boringVaultName,
                            config.boringVaultSymbol,
                            config.boringVaultAndBaseDecimals // decimals
                        )
                    )
                ))
        );

        if (config.freezeHookMode == ConfigReader.FreezeHookMode.USE_EXISTING) {
            require(
                FREEZE_LIST_BEFORE_TRANSFER_HOOK.code.length != 0,
                "FreezeListBeforeTransferHook not deployed on this chain. Run DeployBeforeTransferHook first"
            );

            boringVault.setBeforeTransferHook(FREEZE_LIST_BEFORE_TRANSFER_HOOK);
            require(
                address(boringVault.hook()) == FREEZE_LIST_BEFORE_TRANSFER_HOOK, "boringVault must have freeze hook"
            );
        } else {
            // Holds under both NONE and DEPLOY_NEW: a new vault has no hook. Under DEPLOY_NEW the hook is deployed and
            // attached later by DeployFreezeListBeforeTransferHook, which needs the vault's RolesAuthority to exist.
            require(address(boringVault.hook()) == address(0), "boringVault must have no hook");
        }

        // Post Deploy Checks
        require(boringVault.owner() == broadcaster, "owner should be the deployer");
        require(
            boringVault.decimals() == ERC20(config.base).decimals(), "boringVault decimals should be the same as base"
        );
        return address(boringVault);
    }

}
