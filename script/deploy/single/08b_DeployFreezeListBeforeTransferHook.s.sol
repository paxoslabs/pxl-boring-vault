// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { FreezeListBeforeTransferHook } from "src/helper/FreezeListBeforeTransferHook.sol";
import { BaseScript } from "script/Base.s.sol";
import { ConfigReader } from "script/ConfigReader.s.sol";
import "src/helper/Constants.sol";

/**
 * @notice Deploys a `FreezeListBeforeTransferHook` used by one vault only and governed by that vault's own
 * RolesAuthority, for vaults that must not depend on the chain-wide hook in `DeployBeforeTransferHook.s.sol`.
 * @dev Runs after the RolesAuthority exists and while the broadcaster still owns the vault. The hook's authority and
 * ownership are handed over in `SetAuthorityAndTransferOwnerships`.
 */
contract DeployFreezeListBeforeTransferHook is BaseScript {

    function run() public returns (address) {
        return deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        require(
            config.freezeHookMode == ConfigReader.FreezeHookMode.DEPLOY_NEW,
            "freezeListBeforeTransferHook.mode must be deployNew"
        );
        require(config.boringVault.code.length != 0, "boringVault must have code");
        require(config.rolesAuthority.code.length != 0, "rolesAuthority must have code");
        require(config.freezeManagers.length != 0, "no freeze managers");

        bytes32 salt = makeSalt(broadcaster, false, string.concat(config.nameEntropy, ":FreezeListBeforeTransferHook"));
        FreezeListBeforeTransferHook hook = FreezeListBeforeTransferHook(
            CREATEX.deployCreate3(
                salt, abi.encodePacked(type(FreezeListBeforeTransferHook).creationCode, abi.encode(broadcaster))
            )
        );
        require(address(hook) != FREEZE_LIST_BEFORE_TRANSFER_HOOK, "dedicated hook resolved to the shared hook");

        BoringVault boringVault = BoringVault(payable(config.boringVault));
        boringVault.setBeforeTransferHook(address(hook));
        require(address(boringVault.hook()) == address(hook), "boringVault must point at the dedicated hook");

        RolesAuthority rolesAuthority = RolesAuthority(config.rolesAuthority);
        rolesAuthority.setRoleCapability(
            FREEZE_MANAGER_ROLE, address(hook), FreezeListBeforeTransferHook.setFreezeList.selector, true
        );
        for (uint256 i; i < config.freezeManagers.length; ++i) {
            require(config.freezeManagers[i] != address(0), "freeze manager");
            rolesAuthority.setUserRole(config.freezeManagers[i], FREEZE_MANAGER_ROLE, true);
            require(
                rolesAuthority.canCall(
                    config.freezeManagers[i], address(hook), FreezeListBeforeTransferHook.setFreezeList.selector
                ),
                "freeze manager should be able to call setFreezeList"
            );
        }

        return address(hook);
    }

}
