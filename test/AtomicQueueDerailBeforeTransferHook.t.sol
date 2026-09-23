// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdError } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { MockERC20 } from "@solmate/test/utils/mocks/MockERC20.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import { IAtomicSolver } from "src/atomic-queue/IAtomicSolver.sol";
import { AtomicQueueDerailBeforeTransferHook } from "src/helper/AtomicQueueDerailBeforeTransferHook.sol";

contract PassiveSmartAccount {
    fallback() external payable { }
    receive() external payable { }
}

contract RevertingQueue {
    error Nope();

    fallback() external {
        revert Nope();
    }
}

contract ApprovingSolver is IAtomicSolver {
    function finishSolve(bytes calldata, address, ERC20, ERC20 want, uint256, uint256 assetsForWant) external override {
        want.approve(msg.sender, assetsForWant);
    }
}

/// @dev A solver that, mid-`solve()`, calls the hook directly and records the raw revert. `solve()`'s own
/// `nonReentrant` lock is still held at this point, so the hook's reentrancy-detection branch fires for real. The
/// capture is a staticcall from this contract, not a top-level call into `AtomicQueue`, so it isn't masked by
/// `SafeTransferLib`'s generic "TRANSFER_FROM_FAILED" the way a normal attack solve is.
contract ReentrancyProbeSolver is IAtomicSolver {
    AtomicQueueDerailBeforeTransferHook internal immutable hook;

    bool public probed;
    bytes public probeRevertData;

    constructor(AtomicQueueDerailBeforeTransferHook _hook) {
        hook = _hook;
    }

    function finishSolve(bytes calldata, address, ERC20, ERC20 want, uint256, uint256 assetsForWant) external override {
        (, bytes memory returnData) =
            address(hook).staticcall(abi.encodeWithSelector(hook.beforeTransfer.selector, address(0xBEEF)));
        probed = true;
        probeRevertData = returnData;

        want.approve(msg.sender, assetsForWant);
    }
}

contract AtomicQueueDerailBeforeTransferHookTest is Test {
    BoringVault internal boringVault;
    AtomicQueue internal atomicQueue;
    AtomicQueueDerailBeforeTransferHook internal hook;

    MockERC20 internal junkToken;
    MockERC20 internal otherToken;

    PassiveSmartAccount internal victim;
    ApprovingSolver internal approvingSolver;

    address internal attacker = vm.addr(0xA11CE);
    address internal alice = vm.addr(1);
    address internal bob = vm.addr(2);

    string internal constant TRANSFER_FROM_FAILED = "TRANSFER_FROM_FAILED";

    uint256 internal constant VICTIM_SHARES = 100e18;
    uint256 internal constant ATTACKER_OFFER = 1e18;

    function setUp() external {
        boringVault = new BoringVault(address(this), "Boring Vault", "BV", 18);
        atomicQueue = new AtomicQueue();

        junkToken = new MockERC20("Junk", "JUNK", 18);
        otherToken = new MockERC20("Other", "OTHER", 18);

        victim = new PassiveSmartAccount();
        approvingSolver = new ApprovingSolver();

        hook = new AtomicQueueDerailBeforeTransferHook(address(atomicQueue));

        _mintShares(address(victim), VICTIM_SHARES);
        vm.prank(address(victim));
        boringVault.approve(address(atomicQueue), type(uint256).max);

        boringVault.setBeforeTransferHook(address(hook));
    }

    function testAttackDrainsApprovedSharesWithoutHook() external {
        boringVault.setBeforeTransferHook(address(0));
        _createAttackRequest();

        _executeAttackSolve();

        assertEq(boringVault.balanceOf(attacker), VICTIM_SHARES);
        assertEq(boringVault.balanceOf(address(victim)), 0);
        assertEq(junkToken.balanceOf(address(victim)), ATTACKER_OFFER);
    }

    function testHookBlocksAttack() external {
        _createAttackRequest();

        vm.expectRevert(bytes(TRANSFER_FROM_FAILED));
        _executeAttackSolve();

        assertEq(boringVault.balanceOf(attacker), 0);
        assertEq(boringVault.balanceOf(address(victim)), VICTIM_SHARES);
    }

    function testHookBlocksSolveWithSharesAsOffer() external {
        _mintShares(alice, 10e18);
        junkToken.mint(address(approvingSolver), 10e18);

        vm.startPrank(alice);
        boringVault.approve(address(atomicQueue), type(uint256).max);
        atomicQueue.updateAtomicRequest(ERC20(address(boringVault)), ERC20(address(junkToken)), _request(10e18, 1e18));
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(bytes(TRANSFER_FROM_FAILED));
        atomicQueue.solve(
            ERC20(address(boringVault)), ERC20(address(junkToken)), _users(alice), hex"", address(approvingSolver)
        );

        assertEq(boringVault.balanceOf(alice), 10e18);
        assertEq(junkToken.balanceOf(alice), 0);
    }

    function testSolveOfUnrelatedTokensStillWorks() external {
        junkToken.mint(alice, 10e18);
        otherToken.mint(address(approvingSolver), 10e18);

        vm.startPrank(alice);
        junkToken.approve(address(atomicQueue), type(uint256).max);
        atomicQueue.updateAtomicRequest(ERC20(address(junkToken)), ERC20(address(otherToken)), _request(10e18, 1e18));
        vm.stopPrank();

        vm.prank(alice);
        atomicQueue.solve(
            ERC20(address(junkToken)), ERC20(address(otherToken)), _users(alice), hex"", address(approvingSolver)
        );

        assertEq(otherToken.balanceOf(alice), 10e18);
        assertEq(junkToken.balanceOf(address(approvingSolver)), 10e18);
    }

    function testTransferStillWorks() external {
        _mintShares(alice, 10e18);

        vm.prank(alice);
        boringVault.transfer(bob, 4e18);

        assertEq(boringVault.balanceOf(alice), 6e18);
        assertEq(boringVault.balanceOf(bob), 4e18);
    }

    function testTransferFromStillWorks() external {
        _mintShares(alice, 10e18);
        vm.prank(alice);
        boringVault.approve(bob, 10e18);

        vm.prank(bob);
        boringVault.transferFrom(alice, bob, 4e18);

        assertEq(boringVault.balanceOf(alice), 6e18);
        assertEq(boringVault.balanceOf(bob), 4e18);
        assertEq(boringVault.allowance(alice, bob), 6e18);
    }

    function testEnterAndExitStillWork() external {
        junkToken.mint(alice, 10e18);
        vm.prank(alice);
        junkToken.approve(address(boringVault), 10e18);

        boringVault.enter(alice, ERC20(address(junkToken)), 10e18, alice, 10e18);
        assertEq(boringVault.balanceOf(alice), 10e18);

        boringVault.exit(alice, ERC20(address(junkToken)), 10e18, alice, 10e18);
        assertEq(boringVault.balanceOf(alice), 0);
        assertEq(junkToken.balanceOf(alice), 10e18);
    }

    function testMisconfiguredQueueBlocksTransfers() external {
        boringVault.setBeforeTransferHook(address(new AtomicQueueDerailBeforeTransferHook(address(0xDEAD))));
        _mintShares(alice, 10e18);

        vm.prank(alice);
        vm.expectRevert(stdError.assertionError);
        boringVault.transfer(bob, 1e18);
    }

    function testUnrelatedRevertBlocksTransfers() external {
        RevertingQueue revertingQueue = new RevertingQueue();
        boringVault.setBeforeTransferHook(address(new AtomicQueueDerailBeforeTransferHook(address(revertingQueue))));
        _mintShares(alice, 10e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                AtomicQueueDerailBeforeTransferHook.UnexpectedRevert.selector,
                alice,
                abi.encodeWithSelector(RevertingQueue.Nope.selector)
            )
        );
        boringVault.transfer(bob, 1e18);
    }

    function testUseOfInvalidContractBlocksLiveReentrancy() external {
        ReentrancyProbeSolver probe = new ReentrancyProbeSolver(hook);

        junkToken.mint(alice, 10e18);
        otherToken.mint(address(probe), 10e18);

        vm.startPrank(alice);
        junkToken.approve(address(atomicQueue), type(uint256).max);
        atomicQueue.updateAtomicRequest(ERC20(address(junkToken)), ERC20(address(otherToken)), _request(10e18, 1e18));
        vm.stopPrank();

        vm.prank(alice);
        atomicQueue.solve(ERC20(address(junkToken)), ERC20(address(otherToken)), _users(alice), hex"", address(probe));

        assertTrue(probe.probed());
        assertEq(
            probe.probeRevertData(),
            abi.encodeWithSelector(
                AtomicQueueDerailBeforeTransferHook.UseOfInvalidContract.selector,
                address(0xBEEF),
                address(atomicQueue),
                abi.encodeWithSignature("Error(string)", "REENTRANCY")
            )
        );
    }

    /// @dev EIP-150 gas-griefing check: a caller who supplies too little gas to the outer call
    /// can only ever forward gasleft() - gasleft()/64 to the staticcall, which could silently be
    /// less than DERAIL_GAS_STIPEND. Without a guard, that under-forwarded probe could run out of
    /// gas before completing a live-reentrancy revert, producing empty return data indistinguishable
    /// from "not reentrant" -- and letting the transfer bypass the protection. Confirm the hook now
    /// reverts up front instead.
    function testInsufficientGasFailsClosed() external {
        _mintShares(alice, 10e18);

        vm.prank(alice);
        vm.expectPartialRevert(AtomicQueueDerailBeforeTransferHook.InsufficientGasForProbe.selector);
        boringVault.transfer{ gas: 11_000 }(bob, 1e18);
    }

    function testHookedTransferGasStaysReasonable() external {
        _mintShares(alice, 10e18);

        vm.prank(alice);
        uint256 start = gasleft();
        boringVault.transfer(bob, 1e18);
        uint256 used = start - gasleft();

        assertLt(used, 200_000);
    }

    function _mintShares(address to, uint256 amount) internal {
        boringVault.enter(address(0), ERC20(address(0)), 0, to, amount);
    }

    function _users(address user) internal pure returns (address[] memory users) {
        users = new address[](1);
        users[0] = user;
    }

    function _request(
        uint256 offerAmount,
        uint256 atomicPrice
    )
        internal
        view
        returns (AtomicQueue.AtomicRequest memory)
    {
        return AtomicQueue.AtomicRequest({
            deadline: uint64(block.timestamp + 1 days),
            atomicPrice: uint88(atomicPrice),
            offerAmount: uint96(offerAmount),
            inSolve: false
        });
    }

    function _createAttackRequest() internal {
        junkToken.mint(attacker, ATTACKER_OFFER);

        vm.startPrank(attacker);
        junkToken.approve(address(atomicQueue), type(uint256).max);
        atomicQueue.updateAtomicRequest(
            ERC20(address(junkToken)), ERC20(address(boringVault)), _request(ATTACKER_OFFER, VICTIM_SHARES)
        );
        vm.stopPrank();
    }

    function _executeAttackSolve() internal {
        vm.prank(attacker);
        atomicQueue.solve(
            ERC20(address(junkToken)), ERC20(address(boringVault)), _users(attacker), hex"", address(victim)
        );
    }
}

contract AtomicQueueDerailBeforeTransferHookForkTest is Test {
    BoringVault internal constant BORING_VAULT = BoringVault(payable(0x196ead472583Bc1e9aF7A05F860D9857e1Bd3dCc));
    AtomicQueue internal constant ATOMIC_QUEUE = AtomicQueue(0xc7287780bfa0C5D2dD74e3e51E238B1cd9B221ee);
    uint256 internal constant FORK_BLOCK = 25_943_286; // A state of the vault before we introduced the temporary freeze
    // hook

    MockERC20 internal junkToken;
    PassiveSmartAccount internal victim;

    address internal attacker = vm.addr(0xA11CE);

    uint256 internal constant VICTIM_SHARES = 100e18;
    uint256 internal constant ATTACKER_OFFER = 1e18;

    function setUp() external {
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK));

        junkToken = new MockERC20("Junk", "JUNK", 18);
        victim = new PassiveSmartAccount();

        deal(address(BORING_VAULT), address(victim), VICTIM_SHARES);
        vm.prank(address(victim));
        BORING_VAULT.approve(address(ATOMIC_QUEUE), type(uint256).max);

        junkToken.mint(attacker, ATTACKER_OFFER);
        vm.startPrank(attacker);
        junkToken.approve(address(ATOMIC_QUEUE), type(uint256).max);
        ATOMIC_QUEUE.updateAtomicRequest(
            ERC20(address(junkToken)),
            ERC20(address(BORING_VAULT)),
            AtomicQueue.AtomicRequest({
                deadline: uint64(block.timestamp + 1 days),
                atomicPrice: uint88(VICTIM_SHARES),
                offerAmount: uint96(ATTACKER_OFFER),
                inSolve: false
            })
        );
        vm.stopPrank();
    }

    function testForkAttackDrainsApprovedShares() external {
        assertEq(address(BORING_VAULT.hook()), address(0));

        _executeAttackSolve();

        assertEq(BORING_VAULT.balanceOf(attacker), VICTIM_SHARES);
        assertEq(BORING_VAULT.balanceOf(address(victim)), 0);
        assertEq(junkToken.balanceOf(address(victim)), ATTACKER_OFFER);
    }

    function testForkDerailHookPreventsAttack() external {
        _installDerailHook();

        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        _executeAttackSolve();

        assertEq(BORING_VAULT.balanceOf(attacker), 0);
        assertEq(BORING_VAULT.balanceOf(address(victim)), VICTIM_SHARES);
    }

    function testForkTransfersStillWorkWithDerailHook() external {
        _installDerailHook();

        vm.prank(address(victim));
        BORING_VAULT.transfer(attacker, 4e18);

        assertEq(BORING_VAULT.balanceOf(attacker), 4e18);
        assertEq(BORING_VAULT.balanceOf(address(victim)), VICTIM_SHARES - 4e18);
    }

    function _installDerailHook() internal {
        AtomicQueueDerailBeforeTransferHook hook = new AtomicQueueDerailBeforeTransferHook(address(ATOMIC_QUEUE));

        vm.prank(BORING_VAULT.owner());
        BORING_VAULT.setBeforeTransferHook(address(hook));

        assertEq(address(BORING_VAULT.hook()), address(hook));
    }

    function _executeAttackSolve() internal {
        address[] memory users = new address[](1);
        users[0] = attacker;

        vm.prank(attacker);
        ATOMIC_QUEUE.solve(ERC20(address(junkToken)), ERC20(address(BORING_VAULT)), users, hex"", address(victim));
    }
}
