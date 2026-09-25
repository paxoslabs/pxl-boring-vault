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

        // Create Contract
        // Have to cut some corners here with local variables to avoid stack too deep errors
        // To avoid "stack too deep", split the arguments into intermediate local variables.

        bytes32 feeModuleSalt = keccak256(abi.encodePacked(distributorCodeDepositorSalt, "DCDAssetSpecificFeeModule"));
        // Deploy with `broadcaster` as the temporary owner so this script can configure per-asset
        // fees via `setFeeData` (which is `requiresAuth`). Ownership is transferred to
        // `protocolAdmin` after fees are configured.
        address assetSpecificFeeModule = CREATEX.deployCreate3(
            feeModuleSalt, abi.encodePacked(type(DCDAssetSpecificFeeModule).creationCode, abi.encode(broadcaster))
        );
        console.log("AssetSpecificFeeModule (DCD) deployed: ", assetSpecificFeeModule);

        // Configure per-asset deposit fees, then hand the module off to the protocol admin.
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

        address teller = config.teller;
        address rolesAuthority = config.rolesAuthority;
        bool isNativeSupported = config.distributorCodeDepositorIsNativeDepositSupported;
        uint256 supplyCap = config.distributorCodeDepositorSupplyCap;
        address protocolAdmin = config.protocolAdmin;
        address registry = config.registry;
        string memory policyID = config.policyID;

        bytes memory dcdInitCalldata = abi.encode(
            teller,
            nativeWrapper,
            rolesAuthority,
            isNativeSupported,
            supplyCap,
            assetSpecificFeeModule,
            protocolAdmin,
            registry,
            policyID,
            protocolAdmin
        );

        DistributorCodeDepositor distributorCodeDepositor = DistributorCodeDepositor(
            CREATEX.deployCreate3(
                distributorCodeDepositorSalt,
                abi.encodePacked(type(DistributorCodeDepositor).creationCode, dcdInitCalldata)
            )
        );

        RolesAuthority(config.rolesAuthority)
            .setPublicCapability(address(distributorCodeDepositor), distributorCodeDepositor.deposit.selector, true);
        RolesAuthority(config.rolesAuthority)
            .setPublicCapability(
                address(distributorCodeDepositor), distributorCodeDepositor.depositWithPermit.selector, true
            );
        if (config.distributorCodeDepositorIsNativeDepositSupported) {
            RolesAuthority(config.rolesAuthority)
                .setPublicCapability(
                    address(distributorCodeDepositor), distributorCodeDepositor.depositNative.selector, true
                );
        }

        // Grant the DEPOSITOR ROLE to the distributor code depositor
        RolesAuthority(config.rolesAuthority).setUserRole(address(distributorCodeDepositor), DEPOSITOR_ROLE, true);

        return address(distributorCodeDepositor);
    }

}
