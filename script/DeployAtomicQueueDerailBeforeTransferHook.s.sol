// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { AtomicQueueDerailBeforeTransferHook } from "src/helper/AtomicQueueDerailBeforeTransferHook.sol";
import { BaseScript } from "./Base.s.sol";
import { ConfigReader } from "./ConfigReader.s.sol";
import { console2 } from "@forge-std/console2.sol";

contract DeployAtomicQueueDerailBeforeTransferHook is BaseScript {
    bytes11 internal constant SALT_ENTROPY = bytes11(keccak256("AtomicQueueDerailBeforeTransferHook"));
    address atomicQueue = 0xc7287780bfa0C5D2dD74e3e51E238B1cd9B221ee;

    function run() public returns (address) {
        return deployHook();
    }

    function deploy(ConfigReader.Config memory) public pure override returns (address) {
        revert("use run()");
    }

    function deployHook() public broadcast returns (address hook) {
        require(atomicQueue.code.length != 0, "atomicQueue must have code");

        bytes32 salt = bytes32(abi.encodePacked(broadcaster, bytes1(0x00), SALT_ENTROPY));
        bytes memory initCode =
            abi.encodePacked(type(AtomicQueueDerailBeforeTransferHook).creationCode, abi.encode(atomicQueue));

        hook = CREATEX.deployCreate3(salt, initCode);

        require(address(AtomicQueueDerailBeforeTransferHook(hook).atomicQueue()) == atomicQueue, "atomicQueue mismatch");
        console2.log("AtomicQueueDerailBeforeTransferHook: ", hook);
    }
}
