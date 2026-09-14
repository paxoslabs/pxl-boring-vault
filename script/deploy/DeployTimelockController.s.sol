// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BaseScript } from "../Base.s.sol";

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { console2 } from "@forge-std/console2.sol";

/// @notice Deploys an OpenZeppelin `TimelockController` via CreateX's CREATE3 factory.
/// @dev The salt is built with `makeSalt(broadcaster, true, ...)`, which yields CreateX guard mode
/// "permissioned deploy protection + cross-chain redeploy protection": CreateX derives the effective
/// salt as `keccak256(abi.encode(msg.sender, block.chainid, salt))`. Two consequences to be aware of
/// before running this:
///   1. Only `broadcaster` can ever deploy to the resulting address, and only on this chain. If that
///      key is lost, the address can never be (re)deployed anywhere.
///   2. The address is chain-specific by construction, so the timelock will NOT share an address
///      across chains. Each chain needs its own run of this script and its own address record.
contract DeployTimelockController is BaseScript {

    // ============================== FILL PER DEPLOYMENT ==============================

    /// @dev Namespaces the CREATE3 salt for this deployment. Bump this (e.g. append a nonce) if a
    /// deployment attempt with the same entropy already occupied the address on this chain.
    string constant NAME_ENTROPY = "Prod:TimelockController";

    /// @dev Minimum delay, in seconds, between scheduling and executing an operation.
    uint256 constant MIN_DELAY = 1 days;

    /// @dev Accounts granted EXECUTOR_ROLE. Execution is deliberately permissioned: `address(0)` would make
    /// execution open to anyone, which we rejected so that the timing of unpauses and merkle root rotations
    /// stays under our control. The multisig executes today; the signer EOAs (all cold wallets) are included
    /// so execution can move to a single signer without a role change going through the delay.
    address constant EXECUTOR_1 = 0x1D607E4eb747f1294AE632D3490f121B00Db9312; // Signer
    address constant EXECUTOR_2 = 0x317eEbf4B4a2ceE0e9a73f276628986Ab254A024; // Signer
    address constant EXECUTOR_3 = 0xFBf73C3622668cfE655fAFF8fCb9876015001A5e; // Signer
    address constant EXECUTOR_4 = 0x41431e315A84659012B5622627b8f9e9Bf79652C; // Signer
    address constant EXECUTOR_5 = 0x6Be51156C578414E7893B91FDE1627E8741D526E; // Signer

    /// @dev This must be kept to `address(0)` so the timelock is purely
    /// self-administered: role changes must themselves go through the timelock. A non-zero admin can
    /// re-grant roles instantly and therefore bypasses the whole point of the delay.
    address constant ADMIN = address(0);

    /// @dev Optional. If non-zero, the deployment reverts unless it lands exactly here. Set this from
    /// a dry run so the broadcast can be reviewed against a known address.
    address constant EXPECTED_ADDRESS = address(0);

    // =================================================================================

    function run() external broadcast returns (TimelockController timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = getMultisig();

        address[] memory executors = new address[](6);
        executors[0] = getMultisig();
        executors[1] = EXECUTOR_1;
        executors[2] = EXECUTOR_2;
        executors[3] = EXECUTOR_3;
        executors[4] = EXECUTOR_4;
        executors[5] = EXECUTOR_5;

        require(MIN_DELAY != 0, "MIN_DELAY required");
        require(proposers.length != 0, "at least one proposer required");
        require(executors.length != 0, "at least one executor required");
        // The team multisig is both the sole proposer/canceller and the first executor. Pinning both slots
        // to `getMultisig()` catches running this script against the wrong chain, where the hardcoded
        // proposer/executor set would not correspond to any key we control.

        // Execution is permissioned by decision: address(0) in the executor set would open it to everyone.
        for (uint256 i; i < executors.length; ++i) {
            require(executors[i] != address(0), "executor cannot be address(0) (would be permissionless)");
            for (uint256 j = i + 1; j < executors.length; ++j) {
                require(executors[i] != executors[j], "duplicate executor");
            }
        }

        bytes32 salt = makeSalt({ deployer: broadcaster, isCrosschainProtected: true, nameEntropy: NAME_ENTROPY });

        // Logged before the deploy so the salt is visible even when CreateX reverts (e.g. the address is
        // already occupied and NAME_ENTROPY needs bumping). `guardedSalt` is what CreateX actually feeds
        // to CREATE3 under permissioned + cross-chain redeploy protection; it is the value to reproduce
        // when recomputing the address off-chain.
        console2.log("CreateX salt: ", vm.toString(salt));
        console2.log("CreateX guarded salt: ", vm.toString(keccak256(abi.encode(broadcaster, block.chainid, salt))));

        timelock = TimelockController(
            payable(CREATEX.deployCreate3(
                    salt,
                    abi.encodePacked(
                        type(TimelockController).creationCode, abi.encode(MIN_DELAY, proposers, executors, ADMIN)
                    )
                ))
        );

        // Post-deploy checks.
        if (EXPECTED_ADDRESS != address(0)) {
            require(address(timelock) == EXPECTED_ADDRESS, "deployed address does not match EXPECTED_ADDRESS");
        }
        require(timelock.getMinDelay() == MIN_DELAY, "min delay mismatch");
        for (uint256 i; i < proposers.length; ++i) {
            require(timelock.hasRole(timelock.PROPOSER_ROLE(), proposers[i]), "proposer role not granted");
            require(timelock.hasRole(timelock.CANCELLER_ROLE(), proposers[i]), "canceller role not granted");
        }
        for (uint256 i; i < executors.length; ++i) {
            require(timelock.hasRole(timelock.EXECUTOR_ROLE(), executors[i]), "executor role not granted");
        }
        // The timelock always admins itself; anything else holding admin can bypass the delay.
        require(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)), "timelock is not self-administered");
        if (ADMIN == address(0)) {
            require(
                !timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), broadcaster), "deployer unexpectedly holds admin role"
            );
        } else {
            require(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), ADMIN), "admin role not granted");
        }

        console2.log("TimelockController deployed at: ", address(timelock));
        console2.log("Chain id: ", block.chainid);
        console2.log("Deployer (salt-bound, cannot be changed): ", broadcaster);
        console2.log("Min delay (seconds): ", MIN_DELAY);
    }

}
