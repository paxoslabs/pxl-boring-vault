// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

/// @notice Minimal stand-in for ManagerWithMerkleVerification exposing only `vault()`, which UManager reads
///         in its constructor to derive the BoringVault. Used by unit tests that don't drive the manager.
contract MockManagerWithVault {

    address public immutable vault;

    constructor(address _vault) {
        vault = _vault;
    }

}
