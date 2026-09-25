// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";

/**
 * @notice Minimal ERC20 exposing a configurable `decimals()` at construction. Used across tests to stand in
 * for the PAXG token and vault shares, and to drive decimals-dependent logic deterministically.
 */
contract MockToken is ERC20 {

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_, decimals_) { }

}
