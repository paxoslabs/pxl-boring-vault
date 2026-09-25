// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseScript } from "../Base.s.sol";
import { CowSwapHelper } from "src/helper/cow-swap/CowSwapHelper.sol";
import { console2 } from "forge-std/console2.sol";

/// @notice Deploys the {CowSwapHelper} via CreateX CREATE3. Set `BORING_VAULT` before broadcasting.
contract DeployCowSwapHelper is BaseScript {

    /// @dev Canonical CoW Protocol GPv2Settlement, deployed at the same address on every supported chain.
    address internal constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    /// @dev The BoringVault this helper serves. Deployment-specific: set to the target vault before broadcasting.
    /// NOTE predetermined CREATEX address from DeployBoringVaultAndManager.s.sol script
    address internal constant BORING_VAULT = 0x0EE0c592224bAe0FF5B73B4651166dAF02518369;

    /// @dev Upper bound on how far past `block.timestamp` a placed order's `validTo` may reach. Caps the window a
    /// stale price can be filled.
    /// Declared `uint32` to match the constructor: an over-wide value fails to compile here rather than
    /// reverting the deployment inside the constructor's ABI decoding.
    uint32 internal constant MAX_ORDER_VALIDITY = 1 days;

    /// @dev Entropy folded into the CREATE3 salt; determines the deployed address.
    string internal constant SALT_ENTROPY = "CowSwapHelper";

    function run() public broadcast returns (address) {
        // Owner is the chain's canonical protocol multisig.
        address owner = getMultisig();

        require(owner != address(0), "owner (multisig) must not be zero address");
        require(BORING_VAULT != address(0), "BORING_VAULT must not be zero address");
        require(BORING_VAULT.code.length != 0, "BORING_VAULT must have code");
        require(SETTLEMENT.code.length != 0, "SETTLEMENT has no code on this chain");

        // Permissioned (broadcaster-guarded), no cross-chain protection: same address on every chain.
        // `BORING_VAULT` is folded into the entropy so helpers for different vaults get distinct addresses.
        bytes32 salt =
            makeSalt(broadcaster, false, string(abi.encodePacked(SALT_ENTROPY, ":", vm.toString(BORING_VAULT))));

        bytes memory creationCode = type(CowSwapHelper).creationCode;
        address helper = CREATEX.deployCreate3(
            salt, abi.encodePacked(creationCode, abi.encode(owner, BORING_VAULT, SETTLEMENT, MAX_ORDER_VALIDITY))
        );

        console2.log("CowSwapHelper: ", helper);
        return helper;
    }

}
