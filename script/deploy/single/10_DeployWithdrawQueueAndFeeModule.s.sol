// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "./../../Base.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader, IAuthority } from "../../ConfigReader.s.sol";
import { WithdrawQueueAssetSpecificFeeModule } from "src/helper/WithdrawQueueAssetSpecificFeeModule.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { IERC20 } from "src/interfaces/IFeeModule.sol";
import "src/helper/Constants.sol";
import { console } from "forge-std/console.sol";

/**
 * Deploy the Withdraw Queue and Fee Module
 */
contract DeployWithdrawQueueAndFeeModule is BaseScript {

    using StdJson for string;

    function run() public {
        deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        require(
            keccak256(bytes(config.withdrawQueueName)) != keccak256(bytes("")), "withdrawQueueName must not be empty"
        );
        require(
            keccak256(bytes(config.withdrawQueueSymbol)) != keccak256(bytes("")),
            "withdrawQueueSymbol must not be empty"
        );
        require(
            config.withdrawQueueFeeRecipient == config.protocolAdmin,
            "withdrawQueueFeeRecipient must be the protocol admin"
        );
        require(config.teller != address(0), "teller must not be zero address");
        require(
            config.withdrawQueueProcessorAddress != address(0), "withdrawQueueProcessorAddress must not be zero address"
        );
        address feeModule;
        {
            // Deploy the Fee Module
            bytes32 feeModuleSalt = makeSalt(
                broadcaster,
                false,
                string(
                    abi.encodePacked(
                        config.nameEntropy,
                        ":WithdrawQueueAssetSpecificFeeModule",
                        config.withdrawQueueModuleSpecificNameEntropy
                    )
                )
            );
            bytes memory feeModuleCreationCode = type(WithdrawQueueAssetSpecificFeeModule).creationCode;
            // Deploy with `broadcaster` as the temporary owner so this script can configure per-asset
            // fees via `setFeeData` (which is `requiresAuth`). Ownership is transferred to
            // `protocolAdmin` after fees are configured.
            feeModule = CREATEX.deployCreate3(
                feeModuleSalt, abi.encodePacked(feeModuleCreationCode, abi.encode(broadcaster, config.accountant))
            );
            console.log("WithdrawQueueAssetSpecificFeeModule deployed: ", feeModule);
        }

        require(
            address(WithdrawQueueAssetSpecificFeeModule(feeModule).accountant()) == config.accountant,
            "accountant mismatch"
        );

        // Configure per-asset withdraw fees, then hand the module off to the protocol admin.
        // Skip assets that have both fees as zero — the mapping defaults to zero, so calling
        // `setFeeData` with all-zero args would just burn gas and emit a no-op event.
        WithdrawQueueAssetSpecificFeeModule wqFeeModule = WithdrawQueueAssetSpecificFeeModule(feeModule);
        for (uint256 i; i < config.withdrawAssets.length; ++i) {
            if (config.withdrawAssetPercentFees[i] == 0 && config.withdrawAssetFlatFees[i] == 0) continue;
            wqFeeModule.setFeeData(
                IERC20(config.withdrawAssets[i]), config.withdrawAssetPercentFees[i], config.withdrawAssetFlatFees[i]
            );
        }
        wqFeeModule.transferOwnership(config.protocolAdmin);

        require(WithdrawQueueAssetSpecificFeeModule(feeModule).owner() == config.protocolAdmin, "owner mismatch");

        // Deploy the Withdraw Queue
        bytes32 withdrawQueueSalt = makeSalt(
            broadcaster,
            false,
            string(
                abi.encodePacked(config.nameEntropy, ":WithdrawQueue", config.withdrawQueueModuleSpecificNameEntropy)
            )
        );
        bytes memory withdrawQueueCreationCode = type(WithdrawQueue).creationCode;
        address withdrawQueue = CREATEX.deployCreate3(
            withdrawQueueSalt,
            abi.encodePacked(
                withdrawQueueCreationCode,
                abi.encode(
                    config.withdrawQueueName,
                    config.withdrawQueueSymbol,
                    config.withdrawQueueFeeRecipient,
                    config.teller,
                    feeModule,
                    config.withdrawQueueMinimumOrderSize,
                    broadcaster
                )
            )
        );
        config.withdrawQueue = withdrawQueue;

        // Set Role Capabilities
        RolesAuthority(config.rolesAuthority)
            .setRoleCapability(
                WITHDRAW_QUEUE_PROCESSOR_ROLE, address(withdrawQueue), WithdrawQueue.processOrders.selector, true
            );

        // Set Public Capabilities
        RolesAuthority(config.rolesAuthority)
            .setPublicCapability(address(withdrawQueue), WithdrawQueue.submitOrder.selector, true);
        RolesAuthority(config.rolesAuthority)
            .setPublicCapability(address(withdrawQueue), WithdrawQueue.cancelOrder.selector, true);
        RolesAuthority(config.rolesAuthority)
            .setPublicCapability(address(withdrawQueue), WithdrawQueue.cancelOrderWithSignature.selector, true);
        RolesAuthority(config.rolesAuthority).setUserRole(address(withdrawQueue), SOLVER_ROLE, true);

        // Assign roles to addresses
        RolesAuthority(config.rolesAuthority)
            .setUserRole(config.withdrawQueueProcessorAddress, WITHDRAW_QUEUE_PROCESSOR_ROLE, true);

        return address(withdrawQueue);
    }

}
