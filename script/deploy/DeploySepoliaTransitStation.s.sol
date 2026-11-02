// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.21;

import { console } from "forge-std/console.sol";
import { Authority, RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";

import { BaseScript } from "script/Base.s.sol";
import { TransitStation } from "src/transit/TransitStation.sol";
import { PAUSER_EOA, PAUSER_ROLE, TRANSIT_EXECUTOR_ROLE } from "src/helper/Constants.sol";

/// @notice Testnet (Sepolia <> Robinhood testnet) deployment of a lone Transit Station wired to an already-deployed
///         Transit vault/manager combo.
/// @dev The broadcaster must own `ROLES_AUTHORITY`. Uses LayerZero's default DVN config and leaves ownership and the
///      LZ delegate with the broadcaster.
contract DeploySepoliaTransitStation is BaseScript {

    address constant QUOTE_SIGNER = 0xE4a40e9E04eb7F33368D998FD423073b778Ce420;
    address constant EXECUTOR = 0x501B3d86C893676cEF62EF74223e40DdecE67647;

    address constant BORING_VAULT = 0xb71d509a5A03427475a38a44f2824364Fe62C844;
    address constant ROLES_AUTHORITY = 0xa5894bAFa5d58e541f64744B87b492cC96eF0E9d;

    uint64 constant MESSAGE_GAS_LIMIT = 400_000;

    address constant USDC_SEPOLIA = 0x6587b742eF7536c196E5081Ce294D8E85f215D95;
    address constant USDG_RH_TESTNET = 0x6debC1f4aDD5d7d5096bdCAe65581ac7bcB1F141;

    uint256 constant CHAIN_ID_SEPOLIA = 11_155_111;
    uint256 constant CHAIN_ID_RH_TESTNET = 46_630;

    uint32 constant EID_SEPOLIA = 40_161;
    uint32 constant EID_RH_TESTNET = 40_451;

    TransitStation public transitStation;

    function run() public broadcast {
        RolesAuthority rolesAuthority = RolesAuthority(ROLES_AUTHORITY);
        require(rolesAuthority.owner() == broadcaster, "DeploySepoliaTransitStation: broadcaster must own authority");

        transitStation = TransitStation(
            payable(CREATEX.deployCreate3(
                    makeSalt(broadcaster, false, "Transit: TransitStation"),
                    abi.encodePacked(
                        type(TransitStation).creationCode,
                        abi.encode(
                            broadcaster,
                            Authority(ROLES_AUTHORITY),
                            _lzEndpoint(),
                            BORING_VAULT, // protocolFeeRecipient
                            QUOTE_SIGNER,
                            BORING_VAULT, // offerReceiver
                            BORING_VAULT // wantAssetSource
                        )
                    )
                ))
        );

        rolesAuthority.setRoleCapability(
            TRANSIT_EXECUTOR_ROLE, address(transitStation), TransitStation.executePendingOrders.selector, true
        );
        rolesAuthority.setRoleCapability(PAUSER_ROLE, address(transitStation), TransitStation.pause.selector, true);
        rolesAuthority.setUserRole(EXECUTOR, TRANSIT_EXECUTOR_ROLE, true);
        rolesAuthority.setUserRole(PAUSER_EOA, PAUSER_ROLE, true);
        rolesAuthority.setPublicCapability(address(transitStation), TransitStation.submitOrder.selector, true);
        rolesAuthority.setPublicCapability(address(transitStation), TransitStation.submitOrderWithPermit.selector, true);

        // CREATE3 gives the station the same address on both chains, so the peer is itself.
        uint32 peerEid = _peerEid();
        transitStation.setPeer(peerEid, bytes32(uint256(uint160(address(transitStation)))));
        transitStation.setMessageGasLimit(peerEid, MESSAGE_GAS_LIMIT);

        TransitStation.Route[] memory routes = new TransitStation.Route[](1);
        routes[0] = block.chainid == CHAIN_ID_SEPOLIA
            ? TransitStation.Route({ destEID: EID_RH_TESTNET, offerAsset: USDC_SEPOLIA, wantAsset: USDG_RH_TESTNET })
            : TransitStation.Route({ destEID: EID_SEPOLIA, offerAsset: USDG_RH_TESTNET, wantAsset: USDC_SEPOLIA });
        bool[] memory approved = new bool[](1);
        approved[0] = true;
        transitStation.setRouteApprovals(routes, approved);

        console.log("TransitStation:", address(transitStation));
    }

    function _peerEid() internal view returns (uint32) {
        if (block.chainid == CHAIN_ID_SEPOLIA) return EID_RH_TESTNET;
        if (block.chainid == CHAIN_ID_RH_TESTNET) return EID_SEPOLIA;
        revert("DeploySepoliaTransitStation: unsupported chain");
    }

    function _lzEndpoint() internal view returns (address) {
        if (block.chainid == CHAIN_ID_SEPOLIA) return 0x6EDCE65403992e310A62460808c4b910D972f10f;
        if (block.chainid == CHAIN_ID_RH_TESTNET) return 0x3aCAAf60502791D199a5a5F0B173D78229eBFe32;
        revert("DeploySepoliaTransitStation: unsupported chain");
    }

}
