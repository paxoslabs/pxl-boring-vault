// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { PaxgyDynamicWithdrawalFeeModule } from "src/helper/PaxgyDynamicWithdrawalFeeModule.sol";
import { IFeeModule } from "src/interfaces/IFeeModule.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { PaxgXauRateProvider } from "src/oracles/PaxgXauRateProvider.sol";

import { PaxgyDynamicFeeModuleIntegrationBase } from "test/helper/PaxgyDynamicFeeModuleIntegrationBase.t.sol";

/**
 * @title PaxgyDynamicWithdrawalFeeModuleIntegrationTest
 * @notice Drives a share->PAXG withdrawal end-to-end through the real {WithdrawQueue} with the
 * {PaxgyDynamicWithdrawalFeeModule} wired in, covering the dynamic-fee-zero (at/below peg: only the fixed
 * fee applies) and dynamic-fee-nonzero (above peg) paths. This verifies the queue calls calculateOfferFees
 * with (shares, PAXG), withholds the fee in shares from the offered amount, pays the receiver the post-fee
 * PAXG, and routes the withheld shares to the fee recipient.
 */
contract PaxgyDynamicWithdrawalFeeModuleIntegrationTest is PaxgyDynamicFeeModuleIntegrationBase {

    uint256 internal constant FIXED_FEE_BPS = 10; // 0.10%

    PaxgyDynamicWithdrawalFeeModule internal feeModule;
    WithdrawQueue internal withdrawQueue;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal recoveryAddress = makeAddr("recovery");

    uint256 internal constant OFFER = 100e18;

    WithdrawQueue.SignatureParams internal defaultSignatureParams = WithdrawQueue.SignatureParams({
        approvalMethod: WithdrawQueue.ApprovalMethod.EIP20_APPROVE,
        approvalV: 0,
        approvalR: bytes32(0),
        approvalS: bytes32(0),
        submitWithSignature: false,
        deadline: NOW + 1000,
        eip2612Signature: ""
    });

    function setUp() external {
        _deployVaultAndOracle();

        feeModule = new PaxgyDynamicWithdrawalFeeModule(
            IRateProvider(address(oracle)), IERC20(address(paxg)), IERC20(address(boringVault)), FIXED_FEE_BPS
        );

        vm.startPrank(owner);
        withdrawQueue = new WithdrawQueue(
            "PAXGy Withdraw Queue",
            "pWQ",
            feeRecipient,
            teller,
            IFeeModule(address(feeModule)),
            0,
            owner,
            recoveryAddress
        );
        withdrawQueue.setAuthority(rolesAuthority);

        // The queue burns shares via the teller's bulkWithdraw to pay out the want asset.
        rolesAuthority.setRoleCapability(
            QUEUE_ROLE, address(teller), TellerWithMultiAssetSupport.bulkWithdraw.selector, true
        );
        rolesAuthority.setUserRole(address(withdrawQueue), QUEUE_ROLE, true);
        rolesAuthority.setPublicCapability(address(withdrawQueue), WithdrawQueue.submitOrder.selector, true);
        rolesAuthority.setPublicCapability(address(withdrawQueue), WithdrawQueue.processOrders.selector, true);
        vm.stopPrank();
    }

    function _fee(uint256 amount) internal view returns (uint256) {
        return feeModule.calculateOfferFees(amount, IERC20(address(boringVault)), IERC20(address(paxg)), user);
    }

    /// @dev Mints shares to `user` by depositing PAXG (which also funds the vault with the PAXG to pay out),
    /// then submits a withdrawal order offering all shares for PAXG.
    function _mintAndSubmit(uint256 amount) internal {
        _depositForShares(user, amount);

        vm.startPrank(user);
        boringVault.approve(address(withdrawQueue), amount);
        withdrawQueue.submitOrder(
            WithdrawQueue.SubmitOrderParams({
                amountOffer: amount,
                wantAsset: IERC20(address(paxg)),
                intendedDepositor: user,
                receiver: user,
                refundReceiver: user,
                signatureParams: defaultSignatureParams
            })
        );
        vm.stopPrank();
    }

    /// @notice At peg the dynamic component is zero, so only the fixed 10 bps fee is withheld (in shares);
    /// the receiver is paid the post-fee PAXG 1:1 and the withheld shares land with the fee recipient.
    function testWithdrawOnlyFixedFeeAtPeg() external {
        // Feeds start at peg, so the dynamic depeg fee is zero.
        uint256 expectedFee = _fee(OFFER); // 100 * 10/10_000 = 0.1 shares
        assertEq(expectedFee, 0.1e18, "fixed 10 bps only");

        _mintAndSubmit(OFFER);
        withdrawQueue.processOrders(1);

        uint256 expectedOut = OFFER - expectedFee; // 99.9 PAXG paid 1:1
        assertEq(paxg.balanceOf(user), expectedOut, "receiver paid post-fee PAXG");
        assertEq(boringVault.balanceOf(feeRecipient), expectedFee, "fee withheld in shares to recipient");
        assertEq(paxg.balanceOf(address(boringVault)), expectedFee, "vault retains the fee's worth of PAXG");
        assertEq(withdrawQueue.totalSupply(), 0, "order NFT burned on process");
        assertEq(boringVault.balanceOf(address(withdrawQueue)), 0, "queue holds no residual shares");
    }

    /// @notice Above peg the fixed fee is taken first and the dynamic (p-1)/p fee is levied on the
    /// remainder, both withheld in shares; the receiver gets the reduced PAXG and the fee recipient the
    /// withheld shares.
    function testWithdrawChargesDynamicFeeAbovePeg() external {
        // p = 2.0  =>  fixed 0.1 shares; remaining 99.9; dynamic 99.9 * (2-1)/2 = 49.95; total 50.05 shares.
        _setPaxgXauPrice(2e18);

        uint256 expectedFee = _fee(OFFER);
        assertEq(expectedFee, 50.05e18, "fixed + dynamic depeg fee");

        _mintAndSubmit(OFFER);
        withdrawQueue.processOrders(1);

        uint256 expectedOut = OFFER - expectedFee; // 49.95 PAXG
        assertEq(paxg.balanceOf(user), expectedOut, "receiver paid post-fee PAXG");
        assertEq(boringVault.balanceOf(feeRecipient), expectedFee, "fee withheld in shares to recipient");
        assertEq(paxg.balanceOf(address(boringVault)), expectedFee, "vault retains the fee's worth of PAXG");
        assertEq(withdrawQueue.totalSupply(), 0, "order NFT burned on process");
        assertEq(boringVault.balanceOf(address(withdrawQueue)), 0, "queue holds no residual shares");
    }

    /// @notice A stale PAXG:XAU feed makes calculateOfferFees revert inside processOrders. That call sits
    /// outside the loop's try/catch (only bulkWithdraw is wrapped), so the revert propagates and rolls back
    /// the entire batch: no order advances, no NFT burns, and no fee shares are paid. The queue keeps
    /// custody of every offered share, so once the feed recovers the orders can still be cancelled and
    /// refunded to their owners.
    function testStaleFeedRevertsWholeBatchAndSharesRemainRefundable() external {
        _mintAndSubmit(OFFER);
        _mintAndSubmit(OFFER);

        assertEq(withdrawQueue.latestOrder(), 2, "two orders queued");
        assertEq(withdrawQueue.totalSupply(), 2, "two order NFTs held");
        assertEq(boringVault.balanceOf(address(withdrawQueue)), 2 * OFFER, "queue custodies both offers");

        // Age the PAXG/USD feed past MAX_STALE so PaxgXauRateProvider.getRate reverts on the second leg.
        uint256 staleTimestamp = NOW - MAX_STALE - 1;
        paxgUsdFeed.setUpdatedAt(staleTimestamp);

        vm.expectRevert(
            abi.encodeWithSelector(PaxgXauRateProvider.MaxTimeFromLastUpdatePassed.selector, NOW, staleTimestamp)
        );
        withdrawQueue.processOrders(2);

        // Batch fully rolled back: cursor unchanged, both NFTs retained, no fee shares paid, all shares held.
        assertEq(withdrawQueue.lastProcessedOrder(), 0, "lastProcessedOrder unchanged");
        assertEq(withdrawQueue.totalSupply(), 2, "both order NFTs retained");
        assertEq(withdrawQueue.ownerOf(1), user, "order 1 NFT still owned by user");
        assertEq(withdrawQueue.ownerOf(2), user, "order 2 NFT still owned by user");
        assertEq(boringVault.balanceOf(feeRecipient), 0, "fee recipient received no shares");
        assertEq(boringVault.balanceOf(address(withdrawQueue)), 2 * OFFER, "queue still holds all offered shares");

        // Feed recovers; the retained orders are cancelled and processed as refunds, returning the shares.
        paxgUsdFeed.setUpdatedAt(NOW);

        vm.prank(owner);
        rolesAuthority.setPublicCapability(address(withdrawQueue), WithdrawQueue.cancelOrder.selector, true);

        vm.startPrank(user);
        withdrawQueue.cancelOrder(1);
        withdrawQueue.cancelOrder(2);
        vm.stopPrank();

        withdrawQueue.processOrders(2);

        assertEq(withdrawQueue.lastProcessedOrder(), 2, "both refund orders processed");
        assertEq(withdrawQueue.totalSupply(), 0, "both order NFTs burned on refund");
        assertEq(boringVault.balanceOf(user), 2 * OFFER, "user refunded all offered shares");
        assertEq(boringVault.balanceOf(feeRecipient), 0, "fee recipient still received no shares");
        assertEq(boringVault.balanceOf(address(withdrawQueue)), 0, "queue holds no residual shares");
    }

}
