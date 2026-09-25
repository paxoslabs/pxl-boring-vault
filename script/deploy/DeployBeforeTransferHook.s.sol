// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";

import { BaseScript } from "../Base.s.sol";
import { FreezeListBeforeTransferHook } from "src/helper/FreezeListBeforeTransferHook.sol";
import { console } from "@forge-std/console.sol";
import "src/helper/Constants.sol";

/**
 * @title DeployBeforeTransferHook
 * @notice Deploys the chain's single `FreezeListBeforeTransferHook` and the `RolesAuthority` that governs it.
 * @dev Run once per chain, before any vault deployment. Every vault on the chain shares the resulting hook, so this
 * script deliberately takes no vault config and wires the hook to a `RolesAuthority` of its own rather than to any
 * vault's. `BaseScript.deploy` refuses to run while the hook is missing, which is what forces this ordering.
 * @custom:security The CREATE3 address depends on the salt and `msg.sender` only -- never on the constructor
 * arguments -- so `REQUIRED_DEPLOYER` must sign the transaction or the deployment lands elsewhere. CreateX enforces
 * the match on-chain; the check here just fails earlier and more legibly.
 */
contract DeployBeforeTransferHook is BaseScript {

    /// @dev First 20 bytes of `SALT`.
    address constant REQUIRED_DEPLOYER = 0xDdDdF452dEc1F3877392e08810a7994c2A19A000;
    address constant FREEZE_MANAGER = 0x363c256D368277BBFaf6EaF65beE123a7AdbA464;

    /// can call it regardless, as `Auth` short-circuits for the owner.
    function run() public broadcast returns (address hook, address rolesAuthority) {
        require(broadcaster == REQUIRED_DEPLOYER, "broadcaster is not the deployer SALT is prefixed with");
        require(FREEZE_LIST_BEFORE_TRANSFER_HOOK.code.length == 0, "hook already deployed on this chain");

        bytes32 SALT = makeSalt(broadcaster, false, string("FreezeListBeforeTransferHook"));

        address multisig = getMultisig();

        // Owner is the broadcaster so this script can still wire the authority below; handed to the multisig at the
        // end.
        hook = CREATEX.deployCreate3(
            SALT, abi.encodePacked(type(FreezeListBeforeTransferHook).creationCode, abi.encode(broadcaster))
        );
        require(hook == FREEZE_LIST_BEFORE_TRANSFER_HOOK, "hook address does not match the canonical address");

        rolesAuthority = CREATEX.deployCreate3(
            makeSalt(broadcaster, false, "FreezeListBeforeTransferHook:RolesAuthority"),
            abi.encodePacked(type(RolesAuthority).creationCode, abi.encode(broadcaster, Authority(address(0))))
        );

        RolesAuthority(rolesAuthority)
            .setRoleCapability(FREEZE_MANAGER_ROLE, hook, FreezeListBeforeTransferHook.setFreezeList.selector, true);
        RolesAuthority(rolesAuthority).setUserRole(FREEZE_MANAGER, FREEZE_MANAGER_ROLE, true);

        FreezeListBeforeTransferHook(hook).setAuthority(Authority(rolesAuthority));
        FreezeListBeforeTransferHook(hook).transferOwnership(multisig);
        RolesAuthority(rolesAuthority).transferOwnership(multisig);

        require(address(hook) == FREEZE_LIST_BEFORE_TRANSFER_HOOK, "createx address match");
        require(FreezeListBeforeTransferHook(hook).owner() == multisig, "hook owner");
        require(address(FreezeListBeforeTransferHook(hook).authority()) == rolesAuthority, "hook authority");
        require(RolesAuthority(rolesAuthority).owner() == multisig, "rolesAuthority owner");
        require(
            RolesAuthority(rolesAuthority).doesUserHaveRole(FREEZE_MANAGER, FREEZE_MANAGER_ROLE), "FREEZE_MANAGER role"
        );

        console.log("FreezeListBeforeTransferHook: ", hook);
        console.log("FreezeList RolesAuthority: ", rolesAuthority);
        console.log("Freeze Manager: ", FREEZE_MANAGER);
    }

}
