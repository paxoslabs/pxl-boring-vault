// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";

import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import {
    CowSwapHelperDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/CowSwapHelperDecoderAndSanitizer.sol";
import { CowSwapHelper } from "src/helper/cow-swap/CowSwapHelper.sol";
import { CowSwapOrderLib } from "src/libraries/CowSwapOrderLib.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { IGPv2Settlement } from "src/interfaces/IGPv2Settlement.sol";

/// @notice Fixed-price rate provider so the floor is deterministic and independent of live oracles.
contract FixedRateProvider is IRateProvider {

    uint256 internal immutable rate;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

}

/// @notice Shared scaffolding for the CowSwapHelper integration and fork suites: the roles wiring, the merkle
///         tree construction, the placeOrder-leaf derivation, and the order-UID reconstruction that both suites
///         exercise identically.
/// @dev Only the pieces that differ between a mocked and a forked environment are left virtual: the sell token,
///      the buy token, and the settlement address. Everything else - the merkle primitives (which mirror
///      ManagerWithMerkleVerification's OpenZeppelin-style tree so proofs built here verify on-chain), the roles
///      authority, and the shared constants - lives here so the concrete suites hold only their own setUp,
///      tests, and flow helpers.
abstract contract CowSwapHelperTestBase is Test {

    uint8 internal constant MANAGER_ROLE = 1;
    uint8 internal constant STRATEGIST_ROLE = 2;

    // 3000 buyToken per sellToken, expressed as an 18-decimal rate.
    uint256 internal constant RATE_18 = 3000e18;
    uint8 internal constant RATE_DECIMALS = 18;
    uint256 internal constant MAX_SLIPPAGE_BPS = 100; // 1%
    uint256 internal constant SELL_AMOUNT = 10e18; // 10 sellToken (18 decimals)
    uint32 internal constant MAX_ORDER_VALIDITY = 1 days;
    uint256 internal constant BUY_AMOUNT = 29_700e6; // 10 * 3000 * 0.99 = floor at 1% slippage (buyToken has 6 dp)

    BoringVault internal boringVault;
    ManagerWithMerkleVerification internal manager;
    RolesAuthority internal rolesAuthority;
    CowSwapHelperDecoderAndSanitizer internal decoder;
    CowSwapHelper internal helper;
    FixedRateProvider internal rateProvider;

    address internal strategist = makeAddr("strategist");

    // Cached merkle material. sweepToken is merkle-gated (onlyBoringVault) and so also has a leaf.
    bytes32[][] internal tree;
    bytes32 internal approveLeaf;
    bytes32 internal placeLeaf;
    bytes32 internal cancelLeaf;
    bytes32 internal sweepLeaf;

    // ------------------------------------------------------------------------
    // Parameterization hooks (supplied by the concrete suite)
    // ------------------------------------------------------------------------

    /// @dev The sell token the leaves pin and the order sells.
    function _sellToken() internal view virtual returns (address);

    /// @dev The buy token the leaves pin and the order buys.
    function _buyToken() internal view virtual returns (address);

    /// @dev The GPv2 settlement whose domain separator seals the reconstructed order digest.
    function _settlement() internal view virtual returns (address);

    // ------------------------------------------------------------------------
    // Roles + merkle setup
    // ------------------------------------------------------------------------

    function _wireRolesAuthority() internal {
        rolesAuthority = new RolesAuthority(address(this), Authority(address(0)));
        boringVault.setAuthority(rolesAuthority);
        manager.setAuthority(rolesAuthority);

        rolesAuthority.setRoleCapability(
            MANAGER_ROLE, address(boringVault), bytes4(keccak256("manage(address,bytes,uint256)")), true
        );
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE, address(boringVault), bytes4(keccak256("manage(address[],bytes[],uint256[])")), true
        );
        rolesAuthority.setRoleCapability(
            STRATEGIST_ROLE,
            address(manager),
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
            true
        );

        rolesAuthority.setUserRole(address(manager), MANAGER_ROLE, true);
        rolesAuthority.setUserRole(strategist, STRATEGIST_ROLE, true);
    }

    /// @dev Builds the 4-leaf tree (approve, placeOrder, cancelOrder, sweepToken) and registers the root.
    function _buildAndSetRoot(bool partiallyFillable) internal {
        approveLeaf = keccak256(
            abi.encodePacked(address(decoder), _sellToken(), false, ERC20.approve.selector, address(helper))
        );
        placeLeaf = _placeLeaf(partiallyFillable);
        cancelLeaf =
            keccak256(abi.encodePacked(address(decoder), address(helper), false, CowSwapHelper.cancelOrder.selector));
        sweepLeaf =
            keccak256(abi.encodePacked(address(decoder), address(helper), false, CowSwapHelper.sweepToken.selector));

        bytes32[][] memory leafs = new bytes32[][](1);
        leafs[0] = new bytes32[](4);
        leafs[0][0] = approveLeaf;
        leafs[0][1] = placeLeaf;
        leafs[0][2] = cancelLeaf;
        leafs[0][3] = sweepLeaf;

        tree = _buildTrees(leafs);
        manager.setManageRoot(strategist, tree[tree.length - 1][0]);
    }

    /// @dev The placeOrder leaf pins sellToken, buyToken, rateProvider, rateDecimals, maxSlippageBps, and the
    ///      partial-fill flag - exactly the bytes the decoder returns, in order.
    function _placeLeaf(bool partiallyFillable) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                address(decoder),
                address(helper),
                false,
                CowSwapHelper.placeOrder.selector,
                _sellToken(),
                _buyToken(),
                address(rateProvider),
                RATE_DECIMALS,
                MAX_SLIPPAGE_BPS,
                partiallyFillable
            )
        );
    }

    /// @dev Rebuilds, against the settlement's domain separator, the order digest the helper will sign; the
    ///      helper itself is the owner and the vault is the receiver.
    function _expectedUid(CowSwapHelper.OrderParams memory p) internal view returns (bytes memory) {
        CowSwapOrderLib.Data memory order = CowSwapOrderLib.Data({
            sellToken: address(p.sellToken),
            buyToken: address(p.buyToken),
            receiver: address(boringVault),
            sellAmount: p.sellAmount,
            buyAmount: p.buyAmount,
            validTo: p.validTo,
            appData: bytes32(0),
            feeAmount: 0,
            kind: CowSwapOrderLib.KIND_SELL,
            partiallyFillable: p.partiallyFillable,
            sellTokenBalance: CowSwapOrderLib.BALANCE_ERC20,
            buyTokenBalance: CowSwapOrderLib.BALANCE_ERC20
        });
        bytes32 digest = CowSwapOrderLib.hash(order, IGPv2Settlement(_settlement()).domainSeparator());
        return CowSwapOrderLib.packOrderUid(digest, address(helper), p.validTo);
    }

    // ------------------------------------------------------------------------
    // Merkle primitives (mirror ManagerWithMerkleVerification's OpenZeppelin-style tree)
    // ------------------------------------------------------------------------

    function _proof(bytes32 leaf) internal view returns (bytes32[] memory proof) {
        uint256 treeLength = tree.length;
        proof = new bytes32[](treeLength - 1);
        for (uint256 i; i < treeLength - 1; ++i) {
            for (uint256 j; j < tree[i].length; ++j) {
                if (leaf == tree[i][j]) {
                    proof[i] = j % 2 == 0 ? tree[i][j + 1] : tree[i][j - 1];
                    leaf = _hashPair(leaf, proof[i]);
                    break;
                }
            }
        }
    }

    function _buildTrees(bytes32[][] memory merkleTreeIn) internal pure returns (bytes32[][] memory merkleTreeOut) {
        uint256 inLength = merkleTreeIn.length;
        merkleTreeOut = new bytes32[][](inLength + 1);
        uint256 layerLength;
        for (uint256 i; i < inLength; ++i) {
            layerLength = merkleTreeIn[i].length;
            merkleTreeOut[i] = new bytes32[](layerLength);
            for (uint256 j; j < layerLength; ++j) {
                merkleTreeOut[i][j] = merkleTreeIn[i][j];
            }
        }

        uint256 nextLayerLength = layerLength % 2 != 0 ? (layerLength + 1) / 2 : layerLength / 2;
        merkleTreeOut[inLength] = new bytes32[](nextLayerLength);
        bytes32[] memory prevLayer = merkleTreeIn[inLength - 1];
        uint256 count;
        for (uint256 i; i < layerLength; i += 2) {
            // Guard the odd tail: an unpaired final node is promoted by hashing it with itself rather than
            // reading past the end of the layer.
            bytes32 right = (i + 1 < layerLength) ? prevLayer[i + 1] : prevLayer[i];
            merkleTreeOut[inLength][count] = _hashPair(prevLayer[i], right);
            count++;
        }
        if (nextLayerLength > 1) {
            merkleTreeOut = _buildTrees(merkleTreeOut);
        }
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? _efficientHash(a, b) : _efficientHash(b, a);
    }

    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }

}
