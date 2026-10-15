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
        require(config.withdrawQueueFeeRecipient != address(0), "withdrawQueueFeeRecipient must not be zero address");
        require(
            config.withdrawQueueRecoveryAddress != address(0), "withdrawQueueRecoveryAddress must not be zero address"
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

        address withdrawQueue = _deployWithdrawQueue(config, feeModule);
        config.withdrawQueue = withdrawQueue;

        // Post Deploy Checks
        // One assertion per constructor argument: the args are appended to the creation code as an untyped
        // blob, so a missing or reordered value is not a compile error and can decode to a plausible-looking
        // value rather than reverting.
        WithdrawQueue queue = WithdrawQueue(withdrawQueue);
        require(
            keccak256(bytes(queue.name())) == keccak256(bytes(config.withdrawQueueName)),
            "the withdraw queue name must match the config"
        );
        require(
            keccak256(bytes(queue.symbol())) == keccak256(bytes(config.withdrawQueueSymbol)),
            "the withdraw queue symbol must match the config"
        );
        require(
            queue.feeRecipient() == config.withdrawQueueFeeRecipient,
            "the withdraw queue fee recipient must match the config"
        );
        require(address(queue.tellerWithMultiAssetSupport()) == config.teller, "the withdraw queue teller must match");
        require(address(queue.feeModule()) == feeModule, "the withdraw queue fee module must match");
        require(
            queue.minimumOrderSize() == config.withdrawQueueMinimumOrderSize,
            "the withdraw queue minimum order size must match the config"
        );
        require(queue.owner() == broadcaster, "the withdraw queue owner must be the broadcaster");
        require(
            queue.recoveryAddress() == config.withdrawQueueRecoveryAddress,
            "the withdraw queue recovery address must match the config"
        );

        RolesAuthority rolesAuthority = RolesAuthority(config.rolesAuthority);
        rolesAuthority.setRoleCapability(
            WITHDRAW_QUEUE_PROCESSOR_ROLE, withdrawQueue, WithdrawQueue.processOrders.selector, true
        );

        // Without `allowPublicSubmitOrder` only MINTER_REDEEMER_ROLE can submit, and this script grants that role to
        // nobody: the owner whitelists redeemers after deployment.
        if (config.withdrawQueueAllowPublicSubmitOrder) {
            rolesAuthority.setPublicCapability(withdrawQueue, WithdrawQueue.submitOrder.selector, true);
        } else {
            rolesAuthority.setRoleCapability(
                MINTER_REDEEMER_ROLE, withdrawQueue, WithdrawQueue.submitOrder.selector, true
            );
        }

        // Without these, a pending order can only be unwound by the owner through refundOrder.
        if (config.withdrawQueueAllowPublicUserCancellations) {
            rolesAuthority.setPublicCapability(withdrawQueue, WithdrawQueue.cancelOrder.selector, true);
            rolesAuthority.setPublicCapability(withdrawQueue, WithdrawQueue.cancelOrderWithSignature.selector, true);
        }

        rolesAuthority.setUserRole(withdrawQueue, SOLVER_ROLE, true);

        // Assign roles to addresses
        rolesAuthority.setUserRole(config.withdrawQueueProcessorAddress, WITHDRAW_QUEUE_PROCESSOR_ROLE, true);

        return address(withdrawQueue);
    }

    /// @dev Split out of `_deploy` to stay under the stack limit.
    function _deployWithdrawQueue(ConfigReader.Config memory config, address feeModule) internal returns (address) {
        bytes32 withdrawQueueSalt = makeSalt(
            broadcaster,
            false,
            string(
                abi.encodePacked(config.nameEntropy, ":WithdrawQueue", config.withdrawQueueModuleSpecificNameEntropy)
            )
        );
        return CREATEX.deployCreate3(
            withdrawQueueSalt,
            abi.encodePacked(
                type(WithdrawQueue).creationCode,
                abi.encode(
                    config.withdrawQueueName,
                    config.withdrawQueueSymbol,
                    config.withdrawQueueFeeRecipient,
                    config.teller,
                    feeModule,
                    config.withdrawQueueMinimumOrderSize,
                    broadcaster,
                    config.withdrawQueueRecoveryAddress
                )
            )
        );
    }

}
