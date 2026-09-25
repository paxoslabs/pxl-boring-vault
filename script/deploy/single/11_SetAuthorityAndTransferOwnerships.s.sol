// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "./../../Base.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader, IAuthority } from "../../ConfigReader.s.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";

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
        }
    }

}
