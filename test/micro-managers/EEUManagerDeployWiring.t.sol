// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { EquivalentExchangeUManager } from "src/micro-managers/EquivalentExchangeUManager.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";

import { MockRateProvider } from "./mocks/MockRateProvider.sol";

/// @notice Minimal token to stand up basket entries at arbitrary decimals.
contract WiringMockERC20 is ERC20 {

    constructor(uint8 decimals) ERC20("Mock", "MOCK", decimals) { }

}

/// @notice Reproduces the exact authority wiring performed by
///         script/deploy/DeployBoringVaultAndManager.s.sol (which deploys the vault, manager, and
///         EquivalentExchangeUManager together and grants STRATEGIST_ROLE) and asserts the resulting
///         access matrix.
contract EEUManagerDeployWiringTest is Test {

    uint8 internal constant STRATEGIST_ROLE = 1; // matches src/helper/Constants.sol

    function test_deployWiringAccessMatrix() external {
        address broadcaster = makeAddr("broadcaster");
        address multisig = makeAddr("multisig"); // protocolAdmin
        address strategistEOA = makeAddr("strategistEOA");
        address randomUser = makeAddr("randomUser");

        vm.startPrank(broadcaster);

        // --- Pre-existing system (deployed earlier in deployAll) ---
        BoringVault boringVault = new BoringVault(broadcaster, "BV", "BV", 18);
        ManagerWithMerkleVerification manager =
            new ManagerWithMerkleVerification(broadcaster, address(boringVault), address(0));
        RolesAuthority rolesAuthority = new RolesAuthority(broadcaster, Authority(address(0)));

        // From 07_DeployRolesAuthority: STRATEGIST_ROLE may drive the merkle manager, strategist EOA holds it.
        rolesAuthority.setRoleCapability(
            STRATEGIST_ROLE,
            address(manager),
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
            true
        );
        rolesAuthority.setUserRole(strategistEOA, STRATEGIST_ROLE, true);

        // --- Exactly what DeployBoringVaultAndManager does for the UManager ---
        EquivalentExchangeUManager uManager = new EquivalentExchangeUManager(broadcaster, address(manager));
        uManager.setAuthority(rolesAuthority);
        rolesAuthority.setRoleCapability(
            STRATEGIST_ROLE, address(uManager), EquivalentExchangeUManager.execute.selector, true
        );
        rolesAuthority.setUserRole(address(uManager), STRATEGIST_ROLE, true);
        uManager.transferOwnership(multisig);

        vm.stopPrank();

        // --- Assertions: exactly the deploy script's post-checks ---
        assertEq(address(uManager.authority()), address(rolesAuthority), "authority");
        assertEq(uManager.owner(), multisig, "owner is multisig");
        assertTrue(rolesAuthority.doesUserHaveRole(address(uManager), STRATEGIST_ROLE), "uManager STRATEGIST_ROLE");

        // execute: strategist EOA yes, multisig owner yes (owner bypass), random no.
        assertTrue(
            rolesAuthority.canCall(strategistEOA, address(uManager), EquivalentExchangeUManager.execute.selector),
            "strategist can execute"
        );
        assertFalse(
            rolesAuthority.canCall(randomUser, address(uManager), EquivalentExchangeUManager.execute.selector),
            "random cannot execute"
        );

        // setBasketTokens: owner-only. No role capability was granted, so NOBODY but the owner passes auth.
        // canCall (authority path) must be false even for the strategist EOA and the UManager itself.
        assertFalse(
            rolesAuthority.canCall(
                strategistEOA, address(uManager), EquivalentExchangeUManager.setBasketTokens.selector
            ),
            "strategist cannot setBasketTokens via authority"
        );
        assertFalse(
            rolesAuthority.canCall(multisig, address(uManager), EquivalentExchangeUManager.setBasketTokens.selector),
            "even owner has no role-capability for setBasketTokens (owner passes via owner-bypass, not authority)"
        );

        // UManager can drive the merkle manager.
        assertTrue(
            rolesAuthority.canCall(
                address(uManager),
                address(manager),
                ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector
            ),
            "uManager can drive manager"
        );

        // --- Behavioral check: owner-bypass actually lets the multisig call setBasketTokens while the
        //     strategist EOA is rejected. Uses a trivial 1-token basket. ---
        EquivalentExchangeUManager.BasketToken[] memory basket = new EquivalentExchangeUManager.BasketToken[](1);
        basket[0] = EquivalentExchangeUManager.BasketToken({
            token: ERC20(address(boringVault)),
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });

        vm.prank(strategistEOA);
        vm.expectRevert(); // Unauthorized: not owner, no role capability
        uManager.setBasketTokens(basket);

        vm.prank(multisig);
        uManager.setBasketTokens(basket); // owner-bypass succeeds
        assertTrue(uManager.isBasketToken(ERC20(address(boringVault))), "basket set by multisig");
    }

    /// @notice Covers the inline-basket pattern the DeployBoringVaultAndManager TODO points at: a basket set
    ///         while the broadcaster still owns the UManager (before the ownership transfer) must persist
    ///         afterward. Mixes a 1:1 token and an oracle-priced token.
    function test_deployWiring_configuredBasketPersistsAfterOwnershipTransfer() external {
        address broadcaster = makeAddr("broadcaster");
        address multisig = makeAddr("multisig");

        WiringMockERC20 usd = new WiringMockERC20(6); // 1:1 token
        WiringMockERC20 gold = new WiringMockERC20(8); // oracle-priced token
        MockRateProvider goldOracle = new MockRateProvider(2000e18); // positive rate

        vm.startPrank(broadcaster);

        BoringVault boringVault = new BoringVault(broadcaster, "BV", "BV", 18);
        ManagerWithMerkleVerification manager =
            new ManagerWithMerkleVerification(broadcaster, address(boringVault), address(0));
        EquivalentExchangeUManager uManager = new EquivalentExchangeUManager(broadcaster, address(manager));

        // Basket configured BEFORE the ownership transfer, exactly as step 13 does it. The broadcaster is
        // still the owner here, so the owner-gated setBasketTokens succeeds.
        EquivalentExchangeUManager.BasketToken[] memory basket = new EquivalentExchangeUManager.BasketToken[](2);
        basket[0] = EquivalentExchangeUManager.BasketToken({
            token: ERC20(address(usd)),
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        basket[1] = EquivalentExchangeUManager.BasketToken({
            token: ERC20(address(gold)),
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: false, rateProvider: IRateProvider(address(goldOracle)), rateDecimals: 18
            })
        });
        // The deploy step asserts each non-zero oracle is live before setting; assert the same invariant.
        assertGt(goldOracle.getRate(), 0, "oracle must be live at deploy time");
        uManager.setBasketTokens(basket);

        uManager.transferOwnership(multisig);

        vm.stopPrank();

        // The basket survives the ownership handoff.
        assertEq(uManager.owner(), multisig, "owner is multisig");
        EquivalentExchangeUManager.BasketToken[] memory stored = uManager.getBasketTokens();
        assertEq(stored.length, 2, "basket length persisted");
        assertTrue(uManager.isBasketToken(ERC20(address(usd))), "usd persisted");
        assertTrue(uManager.isBasketToken(ERC20(address(gold))), "gold persisted");
        assertEq(address(stored[1].config.rateProvider), address(goldOracle), "gold oracle persisted");
        assertEq(stored[1].config.rateDecimals, 18, "gold rateDecimals persisted");

        // After the handoff, only the multisig can change the basket.
        EquivalentExchangeUManager.BasketToken[] memory empty = new EquivalentExchangeUManager.BasketToken[](0);
        vm.prank(broadcaster);
        vm.expectRevert();
        uManager.setBasketTokens(empty);
    }

}
