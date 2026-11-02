// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "./../../Base.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader, IAuthority } from "../../ConfigReader.s.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { DistributorCodeDepositor } from "src/helper/DistributorCodeDepositor.sol";
import { Auth } from "@solmate/auth/Auth.sol";

/**
 * Update `rolesAuthority` and transfer ownership from deployer EOA to the
 * protocol.
 */
contract SetAuthorityAndTransferOwnerships is BaseScript {

    using StdJson for string;

    function run() public {
        deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values

        require(address(config.boringVault) != address(0), "boringVault must not be zero address");
        require(address(config.manager) != address(0), "manager must not be zero address");
        require(address(config.accountant) != address(0), "accountant must not be zero address");
        require(address(config.teller) != address(0), "teller must not be zero address");
        require(address(config.withdrawQueue) != address(0), "withdrawQueue must not be zero address");

        require(address(config.boringVault).code.length != 0, "boringVault must have code");
        require(address(config.manager).code.length != 0, "manager must have code");
        require(address(config.teller).code.length != 0, "teller must have code");
        require(address(config.accountant).code.length != 0, "accountant must have code");
        require(address(config.withdrawQueue).code.length != 0, "withdrawQueue must have code");
        require(config.rolesAuthority != address(0), "rolesAuthority");
        require(config.protocolAdmin != address(0), "protocolAdmin");

        require(
            address(WithdrawQueue(config.withdrawQueue).feeModule()) != address(0),
            "withdrawQueue fee module must not be zero address"
        );
        require(
            address(WithdrawQueue(config.withdrawQueue).feeModule()).code.length != 0,
            "withdrawQueue fee module must have code"
        );

        // Set Authority
        IAuthority(config.boringVault).setAuthority(config.rolesAuthority);
        IAuthority(config.accountant).setAuthority(config.rolesAuthority);
        IAuthority(config.manager).setAuthority(config.rolesAuthority);
        IAuthority(config.teller).setAuthority(config.rolesAuthority);
        IAuthority(config.withdrawQueue).setAuthority(config.rolesAuthority);

        IAuthority(config.boringVault).transferOwnership(config.protocolAdmin);
        IAuthority(config.manager).transferOwnership(config.protocolAdmin);
        IAuthority(config.accountant).transferOwnership(config.protocolAdmin);
        IAuthority(config.teller).transferOwnership(config.protocolAdmin);
        IAuthority(config.withdrawQueue).transferOwnership(config.protocolAdmin);
        IAuthority(config.rolesAuthority).transferOwnership(config.protocolAdmin);

        if (config.freezeHookMode == ConfigReader.FreezeHookMode.DEPLOY_NEW) {
            require(config.freezeListBeforeTransferHook.code.length != 0, "freeze hook must have code");
            IAuthority(config.freezeListBeforeTransferHook).setAuthority(config.rolesAuthority);
            IAuthority(config.freezeListBeforeTransferHook).transferOwnership(config.protocolAdmin);
        }

        // No need to transfer ownership to distributor code depositor as it is set to protocolAdmin in deployment.

        // Post Configuration Check
        require(IAuthority(config.boringVault).owner() == config.protocolAdmin, "boringVault");
        require(IAuthority(config.manager).owner() == config.protocolAdmin, "manager");
        require(IAuthority(config.accountant).owner() == config.protocolAdmin, "accountant");
        require(IAuthority(config.teller).owner() == config.protocolAdmin, "teller");
        require(IAuthority(config.withdrawQueue).owner() == config.protocolAdmin, "withdrawQueue");
        if (config.distributorCodeDepositorDeploy) {
            require(
                IAuthority(config.distributorCodeDepositor).owner() == config.protocolAdmin, "distributorCodeDepositor"
            );
            require(
                address(Auth(config.distributorCodeDepositor).authority()) == config.rolesAuthority,
                "distributorCodeDepositor authority"
            );
            // The fee modules are owned directly and never get an authority.
            require(
                IAuthority(address(DistributorCodeDepositor(config.distributorCodeDepositor).feeModule())).owner()
                    == config.protocolAdmin,
                "distributorCodeDepositor fee module"
            );
        }
        require(
            IAuthority(address(WithdrawQueue(config.withdrawQueue).feeModule())).owner() == config.protocolAdmin,
            "withdrawQueue fee module"
        );
        require(IAuthority(config.rolesAuthority).owner() == config.protocolAdmin, "rolesAuthority");
        if (config.freezeHookMode == ConfigReader.FreezeHookMode.DEPLOY_NEW) {
            require(IAuthority(config.freezeListBeforeTransferHook).owner() == config.protocolAdmin, "freeze hook");
            require(
                address(Auth(config.freezeListBeforeTransferHook).authority()) == config.rolesAuthority,
                "freeze hook authority"
            );
        }

        require(address(Auth(config.boringVault).authority()) == config.rolesAuthority, "boringVault authority");
        require(address(Auth(config.manager).authority()) == config.rolesAuthority, "manager authority");
        require(address(Auth(config.accountant).authority()) == config.rolesAuthority, "accountant authority");
        require(address(Auth(config.teller).authority()) == config.rolesAuthority, "teller authority");
        require(address(Auth(config.withdrawQueue).authority()) == config.rolesAuthority, "withdrawQueue authority");

        require(config.protocolAdmin != broadcaster, "deployer must not remain the owner");
    }

}
