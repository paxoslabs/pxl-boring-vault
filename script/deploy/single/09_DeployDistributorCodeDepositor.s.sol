// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "./../../Base.s.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { DCDAssetSpecificFeeModule } from "src/helper/DCDAssetSpecificFeeModule.sol";
import { IERC20 } from "src/interfaces/IFeeModule.sol";
import "src/helper/Constants.sol";
import { console } from "forge-std/console.sol";

/**
 * Deploy the Distributor Code Depositor contract.
 */
contract DeployDistributorCodeDepositor is BaseScript {

    function run() public {
        deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values
        require(config.distributorCodeDepositorDeploy, "Distributor Code Depositor must be set true to be deployed");
        require(config.distributorCodeDepositorFeeRecipient != address(0), "DCD fee recipient must not be zero");

        address nativeWrapper =
            config.distributorCodeDepositorIsNativeDepositSupported ? config.nativeWrapper : address(0);

        bytes32 distributorCodeDepositorSalt = makeSalt(
            broadcaster,
            false,
            string(
                abi.encodePacked(
                    config.nameEntropy,
                    ":DistributorCodeDepositor",
                    config.distributorCodeDepositorModuleSpecificNameEntropy
                )
            )
        );

        address assetSpecificFeeModule = _deployFeeModule(config, distributorCodeDepositorSalt);

        bytes memory dcdInitCalldata = abi.encode(
            config.teller,
            nativeWrapper,
            config.rolesAuthority,
            config.distributorCodeDepositorIsNativeDepositSupported,
            config.distributorCodeDepositorSupplyCap,
            assetSpecificFeeModule,
            config.distributorCodeDepositorFeeRecipient,
            config.registry,
            config.policyID,
            config.protocolAdmin
        );

        DistributorCodeDepositor distributorCodeDepositor = DistributorCodeDepositor(
            CREATEX.deployCreate3(
                distributorCodeDepositorSalt,
                abi.encodePacked(type(DistributorCodeDepositor).creationCode, dcdInitCalldata)
            )
        );

        // Constructor args are hand-encoded above, so the compiler cannot catch a wrong order.
        require(address(distributorCodeDepositor.teller()) == config.teller, "DCD teller mismatch");
        require(address(distributorCodeDepositor.feeModule()) == assetSpecificFeeModule, "DCD fee module mismatch");
        require(
            distributorCodeDepositor.feeRecipient() == config.distributorCodeDepositorFeeRecipient,
            "DCD fee recipient mismatch"
        );
        require(
            distributorCodeDepositor.supplyCapInBase() == config.distributorCodeDepositorSupplyCap,
            "DCD supply cap mismatch"
        );
        require(distributorCodeDepositor.owner() == config.protocolAdmin, "DCD owner mismatch");
        require(address(distributorCodeDepositor.authority()) == config.rolesAuthority, "DCD authority mismatch");

        RolesAuthority rolesAuthority = RolesAuthority(config.rolesAuthority);
        if (config.distributorCodeDepositorAllowPublicDeposit) {
            rolesAuthority.setPublicCapability(
                address(distributorCodeDepositor), distributorCodeDepositor.deposit.selector, true
            );
            rolesAuthority.setPublicCapability(
                address(distributorCodeDepositor), distributorCodeDepositor.depositWithPermit.selector, true
            );
            if (config.distributorCodeDepositorIsNativeDepositSupported) {
                rolesAuthority.setPublicCapability(
                    address(distributorCodeDepositor), distributorCodeDepositor.depositNative.selector, true
                );
            }
        } else {
            // MINTER_REDEEMER_ROLE is granted to nobody here: the owner whitelists depositors after deployment.
            rolesAuthority.setRoleCapability(
                MINTER_REDEEMER_ROLE, address(distributorCodeDepositor), distributorCodeDepositor.deposit.selector, true
            );
            rolesAuthority.setRoleCapability(
                MINTER_REDEEMER_ROLE,
                address(distributorCodeDepositor),
                distributorCodeDepositor.depositWithPermit.selector,
                true
            );
            if (config.distributorCodeDepositorIsNativeDepositSupported) {
                rolesAuthority.setRoleCapability(
                    MINTER_REDEEMER_ROLE,
                    address(distributorCodeDepositor),
                    distributorCodeDepositor.depositNative.selector,
                    true
                );
            }
        }

        // Grant the DEPOSITOR ROLE to the distributor code depositor
        rolesAuthority.setUserRole(address(distributorCodeDepositor), DEPOSITOR_ROLE, true);

        return address(distributorCodeDepositor);
    }

    function _deployFeeModule(
        ConfigReader.Config memory config,
        bytes32 distributorCodeDepositorSalt
    )
        internal
        returns (address assetSpecificFeeModule)
    {
        bytes32 feeModuleSalt = keccak256(abi.encodePacked(distributorCodeDepositorSalt, "DCDAssetSpecificFeeModule"));
        // Deploy with `broadcaster` as the temporary owner so this script can configure per-asset
        // fees via `setFeeData` (which is `requiresAuth`). Ownership is transferred to
        // `protocolAdmin` after fees are configured.
        assetSpecificFeeModule = CREATEX.deployCreate3(
            feeModuleSalt, abi.encodePacked(type(DCDAssetSpecificFeeModule).creationCode, abi.encode(broadcaster))
        );
        console.log("AssetSpecificFeeModule (DCD) deployed: ", assetSpecificFeeModule);

        // Skip assets that have both fees as zero — the mapping defaults to zero, so calling
        // `setFeeData` with all-zero args would just burn gas and emit a no-op event.
        DCDAssetSpecificFeeModule dcdFeeModule = DCDAssetSpecificFeeModule(assetSpecificFeeModule);
        for (uint256 i; i < config.depositAssets.length; ++i) {
            if (config.depositAssetPercentFees[i] == 0 && config.depositAssetFlatFees[i] == 0) continue;
            dcdFeeModule.setFeeData(
                IERC20(config.depositAssets[i]), config.depositAssetPercentFees[i], config.depositAssetFlatFees[i]
            );
        }
        dcdFeeModule.transferOwnership(config.protocolAdmin);
        require(dcdFeeModule.owner() == config.protocolAdmin, "DCD fee module owner mismatch");
    }

}
