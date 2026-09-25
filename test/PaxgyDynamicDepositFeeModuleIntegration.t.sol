// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";

import { DistributorCodeDepositor, INativeWrapper } from "src/helper/DistributorCodeDepositor.sol";
import { PaxgyDynamicDepositFeeModule } from "src/helper/PaxgyDynamicDepositFeeModule.sol";
import { IFeeModule } from "src/interfaces/IFeeModule.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";

import { PaxgyDynamicFeeModuleIntegrationBase } from "test/helper/PaxgyDynamicFeeModuleIntegrationBase.t.sol";

/**
 * @title PaxgyDynamicDepositFeeModuleIntegrationTest
 * @notice Drives a PAXG deposit end-to-end through the real {DistributorCodeDepositor} with the
 * {PaxgyDynamicDepositFeeModule} wired in, covering the zero-fee (at/above peg) and non-zero-fee
 * (below peg) paths. This is the integration the unit tests cannot reach: it verifies the depositor
 * actually calls calculateOfferFees with (PAXG, shares), withholds the returned PAXG before minting,
 * and routes it to the fee recipient.
 */
contract PaxgyDynamicDepositFeeModuleIntegrationTest is PaxgyDynamicFeeModuleIntegrationBase {

    PaxgyDynamicDepositFeeModule internal feeModule;
    DistributorCodeDepositor internal depositor;

    address internal feeRecipient = makeAddr("feeRecipient");

    uint256 internal constant DEPOSIT = 100e18;

    function setUp() external {
        _deployVaultAndOracle();

        feeModule = new PaxgyDynamicDepositFeeModule(
            IRateProvider(address(oracle)), IERC20(address(paxg)), IERC20(address(boringVault))
        );

        vm.startPrank(owner);
        // KYT stays disabled (default), so the Predicate registry is never called during a deposit and the
        // empty policy id skips the one registry call the constructor would otherwise make. A placeholder
        // registry address is therefore never dereferenced.
        depositor = new DistributorCodeDepositor(
            teller,
            INativeWrapper(address(0)),
            rolesAuthority,
            false, // native deposits not supported
            type(uint256).max, // supply cap disabled
            IFeeModule(address(feeModule)),
            feeRecipient,
            makeAddr("predicateRegistry"),
            "", // empty policy id: no registry call
            owner
        );
        rolesAuthority.setPublicCapability(address(depositor), DistributorCodeDepositor.deposit.selector, true);
        vm.stopPrank();
    }

    /// @dev Empty attestation; unused because KYT is disabled for PAXG.
    function _emptyAttestation() internal pure returns (Attestation memory) {
        return Attestation({ uuid: "", expiration: 0, attester: address(0), signature: "" });
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        deal(address(paxg), user, amount);
        vm.startPrank(user);
        paxg.approve(address(depositor), amount);
        shares = depositor.deposit(ERC20(address(paxg)), amount, 0, user, "distributor-code", _emptyAttestation());
        vm.stopPrank();
    }

    /// @notice At peg the deposit fee is zero: the full amount is minted 1:1 and nothing reaches the fee
    /// recipient.
    function testDepositNoDynamicFeeAtPeg() external {
        // Feeds start at peg (both $3400), so the market PAXG:XAU rate is exactly 1.0 and the fee is zero.
        assertEq(feeModule.calculateOfferFees(DEPOSIT, IERC20(address(paxg)), IERC20(address(boringVault)), user), 0);

        uint256 shares = _deposit(DEPOSIT);

        assertEq(shares, DEPOSIT, "shares minted 1:1 at peg");
        assertEq(boringVault.balanceOf(user), DEPOSIT, "user holds full shares");
        assertEq(paxg.balanceOf(feeRecipient), 0, "no fee taken at peg");
        assertEq(paxg.balanceOf(address(boringVault)), DEPOSIT, "vault backs shares with full deposit");
        assertEq(paxg.balanceOf(user), 0, "user spent full deposit");
    }

    /// @notice Below peg the deposit fee is the shortfall (1 - p): it is withheld in PAXG before minting,
    /// routed to the fee recipient, and only the post-fee amount is minted.
    function testDepositChargesDynamicFeeBelowPeg() external {
        // p = 0.98  =>  fee fraction = 2%. On a 100 PAXG deposit the fee is 2 PAXG.
        _setPaxgXauPrice(0.98e18);

        uint256 expectedFee =
            feeModule.calculateOfferFees(DEPOSIT, IERC20(address(paxg)), IERC20(address(boringVault)), user);
        assertEq(expectedFee, 2e18, "2% shortfall fee");

        uint256 expectedMint = DEPOSIT - expectedFee; // 98 PAXG minted 1:1
        uint256 shares = _deposit(DEPOSIT);

        assertEq(shares, expectedMint, "shares minted on post-fee amount");
        assertEq(boringVault.balanceOf(user), expectedMint, "user holds post-fee shares");
        assertEq(paxg.balanceOf(feeRecipient), expectedFee, "fee routed to recipient in PAXG");
        assertEq(paxg.balanceOf(address(boringVault)), expectedMint, "vault holds only the minted backing");
        assertEq(paxg.balanceOf(user), 0, "user spent full deposit");
    }

}
