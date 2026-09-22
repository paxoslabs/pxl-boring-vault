// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BeforeTransferHook } from "src/interfaces/BeforeTransferHook.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";

/**
 * @title AtomicQueueDerailBeforeTransferHook
 * @dev The old AtomicQueue contract has a vulnerability whereby dangling approvals can be taken advantage of. Users
 * with BoringVault shares and outstanding approvals may be drained by attackers. This hook blocks BoringVault share
 * transfers that occur while the configured `atomicQueue`'s solve() is executing, by probing that queue's
 * reentrancy guard on every transfer. A normal transfer will successfully pass as a no-op will occur and the
 * reentrancy guard will not be triggered.
 * Scope limits:
 *   - Protects only share transfers of vaults that install this hook. Other ERC20 approvals a user has granted to
 * AtomicQueue are not covered; those must be revoked separately.
 *   - Probes only the `atomicQueue` address given at construction. Approvals to any other AtomicQueue instance are
 * not covered.
 *   - Installing this hook via `setBeforeTransferHook` replaces any hook a vault already holds.
 * @custom:security-contact security@molecularlabs.io
 */
contract AtomicQueueDerailBeforeTransferHook is BeforeTransferHook {
    error UnexpectedRevert(address from, bytes returnData);
    error UseOfInvalidContract(address from, address blockedContract, bytes returnData);

    uint256 internal constant DERAIL_GAS_STIPEND = 8000;
    bytes32 internal constant REENTRANCY_REVERT_HASH =
        keccak256(abi.encodeWithSignature("Error(string)", "REENTRANCY"));
    bytes internal constant PROBE_PAYLOAD = abi.encodeCall(
        AtomicQueue.solve, (ERC20(address(0)), ERC20(address(0)), new address[](0), new bytes(0), address(0))
    );

    AtomicQueue public immutable atomicQueue;

    constructor(address _atomicQueue) {
        atomicQueue = AtomicQueue(_atomicQueue);
    }

    /**
     * @dev This use of the beforeTransfer hook de-rails any attempt to use the vault tokens in a vulnerable AtomicQueue
     * contract.
     *   It does this by weaponizing the reentrancy guard and attempting on every single token transfer, to enter the
     * solve() function.
     *   This is slightly complicated by the fact that this beforeTransfer hook is a view function but we may still
     * utilize this technique by attempting a staticcall to solve() with empty inputs and inspecting the revert message.
     * A staticcall will revert with empty data upon an attempt to modify storage. Whereas a reentrancy will revert
     * early (within the modifier) with a specific revert message. We handle the revert data as follows:
     *
     *       1. If the call succeeded we panic as this should never happen
     *       2. If the revert message is empty, indicating the revert was NOT due to a reentrancy guard, we return
     * empty data and allow the transfer to continue as this transfer is shown to not occur during use of the
     * vulnerable contract.
     *       3. If the return data matches the reentrancy guard signature, we revert with a revert message to block this
     * interaction with the vulnerable atomicQueue.
     *       4. If for any reason the call reverted with different revert data, we throw a custom revert containing that
     * data.
     */
    function beforeTransfer(address from) external view override {
        (bool success, bytes memory returnData) =
            address(atomicQueue).staticcall{ gas: DERAIL_GAS_STIPEND }(PROBE_PAYLOAD);

        assert(!success); // The above call should always fail. Either by a reentrancy or by attempting to SSTORE as a
        // staticcall. There should be no possible path that results in a positive success value

        // empty return data indicates we did not hit the reentrancy guard
        if (returnData.length == 0) return;

        if (keccak256(returnData) == REENTRANCY_REVERT_HASH) {
            revert UseOfInvalidContract(from, address(atomicQueue), returnData);
        }

        revert UnexpectedRevert(from, returnData);
    }
}
