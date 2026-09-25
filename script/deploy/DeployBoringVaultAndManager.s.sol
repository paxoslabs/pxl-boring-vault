// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.21;

import { console } from "forge-std/console.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { stdJson } from "@forge-std/Script.sol";
import { BaseScript } from "script/Base.s.sol";
import "src/helper/Constants.sol";

contract DeployBoringVaultAndManager is BaseScript {

    string constant NAME = "PAXGy TWAP Vault";
    string constant SYMBOL = "PTWAP";
    address constant BALANCER_VAULT = 0x0000000000000000000000000000000000000000;
    uint8 constant DECIMALS = 6;

    function run() public broadcast {
        bytes32 SALT_ROLES_AUTHORITY = makeSalt(broadcaster, false, "PAXGyTWAPVault: RolesAuthority");
        bytes32 SALT_BORING_VAULT = makeSalt(broadcaster, false, "PAXGyTWAPVault: BoringVault");
        bytes32 SALT_MANAGER_WITH_MERKLE_VERIFICATION =
            makeSalt(broadcaster, false, "PAXGyTWAPVault: ManagerWithMerkleVerification");

        address STRATEGIST_ADDRESS = 0x774f67f9a4a98EcCD626e1A463F74d75d19CDcE4;
        // deploy a roles authority
        RolesAuthority rolesAuthority = RolesAuthority(
            CREATEX.deployCreate3(
                SALT_ROLES_AUTHORITY,
                abi.encodePacked(type(RolesAuthority).creationCode, abi.encode(broadcaster, Authority(address(0))))
            )
        );

        // deploy a boring vault
        address boringVaultAddress = CREATEX.deployCreate3(
            SALT_BORING_VAULT,
            abi.encodePacked(type(BoringVault).creationCode, abi.encode(broadcaster, NAME, SYMBOL, DECIMALS))
        );
        BoringVault boringVault = BoringVault(payable(boringVaultAddress));

        // deploy a managerWithMerkleVerification
        ManagerWithMerkleVerification managerWithMerkleVerification = ManagerWithMerkleVerification(
            CREATEX.deployCreate3(
                SALT_MANAGER_WITH_MERKLE_VERIFICATION,
                abi.encodePacked(
                    type(ManagerWithMerkleVerification).creationCode,
                    abi.encode(broadcaster, address(boringVault), BALANCER_VAULT)
                )
            )
        );

        // Set Authority
        boringVault.setAuthority(rolesAuthority);
        managerWithMerkleVerification.setAuthority(rolesAuthority);

        // configure the roles
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE,
            address(boringVault),
            bytes4(keccak256(abi.encodePacked("manage(address,bytes,uint256)"))),
            true
        );

        rolesAuthority.setRoleCapability(
            MANAGER_ROLE,
            address(boringVault),
            bytes4(keccak256(abi.encodePacked("manage(address[],bytes[],uint256[])"))),
            true
        );
        rolesAuthority.setRoleCapability(
            STRATEGIST_ROLE,
            address(managerWithMerkleVerification),
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
            true
        );

        rolesAuthority.setUserRole(address(managerWithMerkleVerification), MANAGER_ROLE, true);
        rolesAuthority.setUserRole(STRATEGIST_ADDRESS, STRATEGIST_ROLE, true);

        // Transfer ownership to the timelock
        // TODO For PAXGy contracts, ownership must be the timelock, not directly the multisig
        rolesAuthority.transferOwnership(getMultisig());
        boringVault.transferOwnership(getMultisig());
        managerWithMerkleVerification.transferOwnership(getMultisig());

        console.log("vault deployed at: ", address(boringVault));
        console.log("Roles Authority deployed at: ", address(rolesAuthority));
        console.log("Manager With Merkle Verification deployed at: ", address(managerWithMerkleVerification));
    }

}
