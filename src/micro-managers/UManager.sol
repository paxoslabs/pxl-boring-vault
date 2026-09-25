// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";

abstract contract UManager is Auth {

    //============================== IMMUTABLES ===============================

    /**
     * @notice The ManagerWithMerkleVerification this uManager works with.
     */
    ManagerWithMerkleVerification internal immutable manager;

    /**
     * @notice The BoringVault this uManager works with.
     */
    address internal immutable boringVault;

    constructor(address _owner, address _manager) Auth(_owner, Authority(address(0))) {
        manager = ManagerWithMerkleVerification(_manager);
        // Derive the vault from the manager so the two can never be wired to mismatched contracts.
        boringVault = address(ManagerWithMerkleVerification(_manager).vault());
    }

    // ========================================= ADMIN FUNCTIONS =========================================

    /**
     * @notice Allows auth to set token approvals to zero.
     * @dev Callable by STRATEGIST_ROLE.
     */
    function revokeTokenApproval(
        bytes32[][] calldata manageProofs,
        address[] calldata decodersAndSanitizers,
        ERC20[] calldata tokens,
        address[] calldata spenders
    )
        external
        requiresAuth
    {
        uint256 tokensLength = tokens.length;
        address[] memory targets = new address[](tokensLength);
        bytes[] memory targetData = new bytes[](tokensLength);
        uint256[] memory values = new uint256[](tokensLength);

        for (uint256 i; i < tokensLength; ++i) {
            targets[i] = address(tokens[i]);
            targetData[i] = abi.encodeWithSelector(ERC20.approve.selector, spenders[i], 0);
            // values[i] = 0;
        }

        // Make the manage call.
        manager.manageVaultWithMerkleVerification(manageProofs, decodersAndSanitizers, targets, targetData, values);
    }

}
