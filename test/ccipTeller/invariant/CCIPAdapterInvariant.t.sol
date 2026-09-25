// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IAny2EVMMessageReceiver } from "@chainlink/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import { IRouterClient } from "@chainlink/ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/ccip/libraries/Client.sol";
import { RateLimiter } from "@chainlink/ccip/libraries/RateLimiter.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import {
    MultiChainCCIPTellerWithMultiAssetSupport
} from "src/base/Roles/CrossChain/MultiChainCCIPTellerWithMultiAssetSupport.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { BridgeData } from "src/interfaces/ICrossChainTypes.sol";

contract QueuedRouter is IRouterClient {

    error MessageAlreadyDelivered(bytes32 messageId);
    error SendFailed();

    struct QueuedMessage {
        bytes32 messageId;
        uint64 sourceChainSelector;
        uint64 destinationChainSelector;
        address sender;
        address receiver;
        bytes data;
        uint256 shareAmount;
        bool delivered;
    }

    uint64 public immutable sourceChainSelector;
    uint64 public immutable destinationChainSelector;
    uint256 public nextMessage;
    uint256 public inFlightShares;
    address public expectedReceiver;
    bool public failSend;
    bool public allMessagesWellFormed = true;
    QueuedMessage[] internal messages;

    constructor(uint64 sourceChainSelector_, uint64 destinationChainSelector_) {
        sourceChainSelector = sourceChainSelector_;
        destinationChainSelector = destinationChainSelector_;
    }

    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external pure returns (uint256) {
        return 0;
    }

    function ccipSend(
        uint64 destinationSelector,
        Client.EVM2AnyMessage calldata message
    )
        external
        payable
        returns (bytes32 messageId)
    {
        if (failSend) revert SendFailed();
        (uint256 shareAmount,) = abi.decode(message.data, (uint256, address));
        address receiver = abi.decode(message.receiver, (address));
        if (
            destinationSelector != destinationChainSelector || receiver != expectedReceiver
                || message.tokenAmounts.length != 0 || message.feeToken != address(0)
        ) allMessagesWellFormed = false;
        messageId = keccak256(abi.encode(messages.length, msg.sender, message.receiver, message.data));
        messages.push(
            QueuedMessage({
                messageId: messageId,
                sourceChainSelector: sourceChainSelector,
                destinationChainSelector: destinationSelector,
                sender: msg.sender,
                receiver: receiver,
                data: message.data,
                shareAmount: shareAmount,
                delivered: false
            })
        );
        inFlightShares += shareAmount;
    }

    function deliverNext() external {
        _deliver(nextMessage);
    }

    function deliverMessage(uint256 index) external {
        _deliver(index);
    }

    function setExpectedReceiver(address expectedReceiver_) external {
        expectedReceiver = expectedReceiver_;
    }

    function setFailSend(bool failSend_) external {
        failSend = failSend_;
    }

    function messageCount() external view returns (uint256) {
        return messages.length;
    }

    function _deliver(uint256 index) internal {
        QueuedMessage storage queued = messages[index];
        if (queued.delivered) revert MessageAlreadyDelivered(queued.messageId);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: queued.messageId,
            sourceChainSelector: queued.sourceChainSelector,
            sender: abi.encode(queued.sender),
            data: queued.data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        queued.delivered = true;
        if (index == nextMessage) nextMessage++;
        inFlightShares -= queued.shareAmount;

        IAny2EVMMessageReceiver(queued.receiver).ccipReceive(message);
    }

}

contract CCIPAdapterHandler is Test {

    uint32 internal constant SOURCE_SELECTOR = 1;
    uint32 internal constant DESTINATION_SELECTOR = 2;
    uint32 internal constant ALTERNATE_SELECTOR = 3;
    uint64 internal constant CCIP_DESTINATION_SELECTOR = 16_015_286_601_757_825_753;
    uint64 internal constant ALTERNATE_CCIP_SELECTOR = 3_373_944_357_266_576_138;
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address internal immutable owner;
    BoringVault internal immutable sourceVault;
    MultiChainCCIPTellerWithMultiAssetSupport internal immutable sourceAdapter;
    MultiChainCCIPTellerWithMultiAssetSupport internal immutable destinationAdapter;
    QueuedRouter internal immutable router;

    constructor(
        address owner_,
        BoringVault sourceVault_,
        MultiChainCCIPTellerWithMultiAssetSupport sourceAdapter_,
        MultiChainCCIPTellerWithMultiAssetSupport destinationAdapter_,
        QueuedRouter router_
    ) {
        owner = owner_;
        sourceVault = sourceVault_;
        sourceAdapter = sourceAdapter_;
        destinationAdapter = destinationAdapter_;
        router = router_;
    }

    function bridge(uint256 amount) external {
        if (sourceAdapter.chainSelectorToCcipSelector(DESTINATION_SELECTOR) != CCIP_DESTINATION_SELECTOR) return;
        uint256 balance = sourceVault.balanceOf(owner);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        BridgeData memory data = BridgeData({
            chainSelector: DESTINATION_SELECTOR,
            destinationChainReceiver: owner,
            bridgeFeeToken: ERC20(NATIVE),
            messageGas: 80_000,
            data: ""
        });
        vm.prank(owner);
        try sourceAdapter.bridge(amount, data) { } catch { }
    }

    function deliver() external {
        if (router.nextMessage() == router.messageCount()) return;
        try router.deliverNext() { } catch { }
    }

    function setDestinationPaused(bool paused) external {
        vm.startPrank(owner);
        if (paused) destinationAdapter.pause();
        else destinationAdapter.unpause();
        vm.stopPrank();
    }

    function setInboundRateLimit(bool enabled, uint128 capacity, uint128 rate) external {
        RateLimiter.Config memory config;
        if (enabled) {
            capacity = uint128(bound(capacity, 1, 1000 ether));
            rate = uint128(bound(rate, 0, capacity));
            config = RateLimiter.Config({ isEnabled: true, capacity: capacity, rate: rate });
        }

        vm.prank(owner);
        destinationAdapter.setCcipRateLimiterConfig(
            SOURCE_SELECTOR, RateLimiter.Config({ isEnabled: false, capacity: 0, rate: 0 }), config
        );
    }

    function setOutboundRateLimit(bool enabled, uint128 capacity, uint128 rate) external {
        RateLimiter.Config memory config;
        if (enabled) {
            capacity = uint128(bound(capacity, 1, 1000 ether));
            rate = uint128(bound(rate, 0, capacity));
            config = RateLimiter.Config({ isEnabled: true, capacity: capacity, rate: rate });
        }

        vm.prank(owner);
        sourceAdapter.setCcipRateLimiterConfig(
            DESTINATION_SELECTOR, config, RateLimiter.Config({ isEnabled: false, capacity: 0, rate: 0 })
        );
    }

    function setSendFailure(bool failSend) external {
        router.setFailSend(failSend);
    }

    function advanceTime(uint32 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 1, 30 days));
    }

    function reassignSourceSelector(bool alternateBaseTeller, bool alternateCcip) external {
        uint32 baseTellerSelector = alternateBaseTeller ? ALTERNATE_SELECTOR : DESTINATION_SELECTOR;
        uint64 ccipSelector = alternateCcip ? ALTERNATE_CCIP_SELECTOR : CCIP_DESTINATION_SELECTOR;

        vm.startPrank(owner);
        sourceAdapter.stopMessagesFromChain(baseTellerSelector);
        sourceAdapter.stopMessagesToChain(baseTellerSelector);
        try sourceAdapter.setCcipChainSelector(baseTellerSelector, ccipSelector) {
            sourceAdapter.allowMessagesToChain(baseTellerSelector, address(destinationAdapter), 100_000);
        } catch { }
        vm.stopPrank();
    }

}

contract CCIPAdapterInvariantTest is StdInvariant, Test {

    uint8 internal constant MINTER_ROLE = 7;
    uint8 internal constant BURNER_ROLE = 8;
    uint32 internal constant SOURCE_SELECTOR = 1;
    uint32 internal constant DESTINATION_SELECTOR = 2;
    uint32 internal constant ALTERNATE_SELECTOR = 3;
    uint64 internal constant CCIP_SOURCE_SELECTOR = 14_767_482_510_784_806_043;
    uint64 internal constant CCIP_DESTINATION_SELECTOR = 16_015_286_601_757_825_753;
    uint64 internal constant ALTERNATE_CCIP_SELECTOR = 3_373_944_357_266_576_138;
    uint256 internal constant INITIAL_SUPPLY = 1000 ether;

    QueuedRouter internal router;
    BoringVault internal sourceVault;
    BoringVault internal destinationVault;
    MultiChainCCIPTellerWithMultiAssetSupport internal sourceAdapter;
    MultiChainCCIPTellerWithMultiAssetSupport internal destinationAdapter;
    CCIPAdapterHandler internal handler;

    function setUp() public {
        router = new QueuedRouter(CCIP_SOURCE_SELECTOR, CCIP_DESTINATION_SELECTOR);
        sourceVault = new BoringVault(address(this), "Source Vault", "sBV", 18);
        destinationVault = new BoringVault(address(this), "Destination Vault", "dBV", 18);

        AccountantWithRateProviders sourceAccountant = new AccountantWithRateProviders(
            address(this), address(sourceVault), address(this), 1e18, address(sourceVault), 1e4, 1e4, 0, 0, 0
        );
        AccountantWithRateProviders destinationAccountant = new AccountantWithRateProviders(
            address(this), address(destinationVault), address(this), 1e18, address(destinationVault), 1e4, 1e4, 0, 0, 0
        );

        sourceAdapter = new MultiChainCCIPTellerWithMultiAssetSupport(
            address(this), address(sourceVault), address(sourceAccountant), router
        );
        destinationAdapter = new MultiChainCCIPTellerWithMultiAssetSupport(
            address(this), address(destinationVault), address(destinationAccountant), router
        );
        router.setExpectedReceiver(address(destinationAdapter));

        _configureVault(sourceVault, sourceAdapter, true);
        _configureVault(destinationVault, destinationAdapter, false);

        sourceAdapter.addChain(DESTINATION_SELECTOR, false, false, address(destinationAdapter), 100_000, 0);
        sourceAdapter.setCcipChainSelector(DESTINATION_SELECTOR, CCIP_DESTINATION_SELECTOR);
        sourceAdapter.allowMessagesToChain(DESTINATION_SELECTOR, address(destinationAdapter), 100_000);
        destinationAdapter.addChain(SOURCE_SELECTOR, false, false, address(sourceAdapter), 100_000, 0);
        destinationAdapter.setCcipChainSelector(SOURCE_SELECTOR, CCIP_SOURCE_SELECTOR);
        destinationAdapter.allowMessagesFromChain(SOURCE_SELECTOR, address(sourceAdapter));

        sourceVault.enter(address(0), ERC20(address(0)), 0, address(this), INITIAL_SUPPLY);

        handler = new CCIPAdapterHandler(address(this), sourceVault, sourceAdapter, destinationAdapter, router);
        targetContract(address(handler));
    }

    function invariant_globalSharesAreConserved() public view {
        assertEq(sourceVault.totalSupply() + destinationVault.totalSupply() + router.inFlightShares(), INITIAL_SUPPLY);
    }

    function invariant_selectorMappingsRemainBidirectional() public view {
        _assertMappingRoundTrip(DESTINATION_SELECTOR);
        _assertMappingRoundTrip(ALTERNATE_SELECTOR);
        _assertReverseMappingRoundTrip(CCIP_DESTINATION_SELECTOR);
        _assertReverseMappingRoundTrip(ALTERNATE_CCIP_SELECTOR);
        assertEq(destinationAdapter.chainSelectorToCcipSelector(SOURCE_SELECTOR), CCIP_SOURCE_SELECTOR);
        assertEq(destinationAdapter.ccipSelectorToChainSelector(CCIP_SOURCE_SELECTOR), SOURCE_SELECTOR);
    }

    function invariant_queuedMessagesUseExpectedCcipEnvelope() public view {
        assertTrue(router.allMessagesWellFormed());
    }

    function invariant_rateLimiterTokensDoNotExceedCapacity() public view {
        (RateLimiter.TokenBucket memory sourceOutbound,) =
            sourceAdapter.getCurrentCcipRateLimiterState(DESTINATION_SELECTOR);
        (, RateLimiter.TokenBucket memory destinationInbound) =
            destinationAdapter.getCurrentCcipRateLimiterState(SOURCE_SELECTOR);
        assertLe(sourceOutbound.tokens, sourceOutbound.capacity);
        assertLe(destinationInbound.tokens, destinationInbound.capacity);
    }

    function test_failedDeliveryRemainsInFlightUntilRetry() public {
        handler.bridge(10 ether);
        handler.setDestinationPaused(true);
        handler.deliver();
        assertEq(router.inFlightShares(), 10 ether);
        assertEq(destinationVault.totalSupply(), 0);

        handler.setDestinationPaused(false);
        handler.deliver();
        assertEq(router.inFlightShares(), 0);
        assertEq(destinationVault.totalSupply(), 10 ether);
        assertEq(destinationVault.balanceOf(address(this)), 10 ether);

        vm.expectRevert();
        router.deliverMessage(0);
        assertEq(destinationVault.totalSupply(), 10 ether);
    }

    function test_rateLimitedDeliveryRemainsInFlightUntilCapacityIsRaised() public {
        handler.setInboundRateLimit(true, 5 ether, 0);
        handler.bridge(10 ether);
        (, RateLimiter.TokenBucket memory beforeFailure) =
            destinationAdapter.getCurrentCcipRateLimiterState(SOURCE_SELECTOR);
        handler.deliver();
        assertEq(router.inFlightShares(), 10 ether);
        assertEq(destinationVault.totalSupply(), 0);
        (, RateLimiter.TokenBucket memory afterFailure) =
            destinationAdapter.getCurrentCcipRateLimiterState(SOURCE_SELECTOR);
        assertEq(afterFailure.tokens, beforeFailure.tokens);

        handler.setInboundRateLimit(true, 10 ether, 0);
        handler.deliver();
        assertEq(router.inFlightShares(), 0);
        assertEq(destinationVault.totalSupply(), 10 ether);
    }

    function test_failedSendRollsBackBurnQueueAndOutboundBucket() public {
        handler.setOutboundRateLimit(true, 20 ether, 0);
        handler.setSendFailure(true);
        handler.bridge(10 ether);

        assertEq(sourceVault.totalSupply(), INITIAL_SUPPLY);
        assertEq(router.messageCount(), 0);
        (RateLimiter.TokenBucket memory afterFailure,) =
            sourceAdapter.getCurrentCcipRateLimiterState(DESTINATION_SELECTOR);
        assertEq(afterFailure.tokens, 20 ether);

        handler.setSendFailure(false);
        handler.bridge(10 ether);
        assertEq(sourceVault.totalSupply(), INITIAL_SUPPLY - 10 ether);
        assertEq(router.inFlightShares(), 10 ether);
        (RateLimiter.TokenBucket memory afterSuccess,) =
            sourceAdapter.getCurrentCcipRateLimiterState(DESTINATION_SELECTOR);
        assertEq(afterSuccess.tokens, 10 ether);
    }

    function _assertMappingRoundTrip(uint32 baseTellerSelector) internal view {
        uint64 ccipSelector = sourceAdapter.chainSelectorToCcipSelector(baseTellerSelector);
        if (ccipSelector != 0) assertEq(sourceAdapter.ccipSelectorToChainSelector(ccipSelector), baseTellerSelector);
    }

    function _assertReverseMappingRoundTrip(uint64 ccipSelector) internal view {
        uint32 baseTellerSelector = sourceAdapter.ccipSelectorToChainSelector(ccipSelector);
        if (baseTellerSelector != 0) {
            assertEq(sourceAdapter.chainSelectorToCcipSelector(baseTellerSelector), ccipSelector);
        }
    }

    function _configureVault(
        BoringVault vault,
        MultiChainCCIPTellerWithMultiAssetSupport adapter,
        bool grantTestMinter
    )
        internal
    {
        RolesAuthority authority = new RolesAuthority(address(this), Authority(address(0)));
        vault.setAuthority(authority);
        authority.setRoleCapability(MINTER_ROLE, address(vault), BoringVault.enter.selector, true);
        authority.setRoleCapability(BURNER_ROLE, address(vault), BoringVault.exit.selector, true);
        authority.setUserRole(address(adapter), MINTER_ROLE, true);
        authority.setUserRole(address(adapter), BURNER_ROLE, true);
        if (grantTestMinter) authority.setUserRole(address(this), MINTER_ROLE, true);
    }

}
