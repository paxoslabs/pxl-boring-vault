// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IAny2EVMMessageReceiver } from "@chainlink/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import { IAny2EVMMessageReceiverV2 } from "@chainlink/ccip/interfaces/IAny2EVMMessageReceiverV2.sol";
import { Client } from "@chainlink/ccip/libraries/Client.sol";
import { ExtraArgsCodec } from "@chainlink/ccip/libraries/ExtraArgsCodec.sol";
import { FinalityCodec } from "@chainlink/ccip/libraries/FinalityCodec.sol";
import { RateLimiter } from "@chainlink/ccip/libraries/RateLimiter.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import {
    MultiChainCCIPTellerWithMultiAssetSupport
} from "src/base/Roles/CrossChain/MultiChainCCIPTellerWithMultiAssetSupport.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import {
    MultiChainTellerBase_MessagesNotAllowedFrom,
    MultiChainTellerBase_MessagesNotAllowedFromSender
} from "src/base/Roles/CrossChain/MultiChainTellerBase.sol";
import { BridgeData } from "src/interfaces/ICrossChainTypes.sol";
import { MockRouterClient } from "test/ccipTeller/mocks/MockRouterClient.sol";

contract MultiChainCCIPTellerWithMultiAssetSupportTest is Test {

    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint8 internal constant MINTER_ROLE = 7;
    uint8 internal constant BURNER_ROLE = 8;
    uint32 internal constant SOURCE = 1;
    uint32 internal constant DESTINATION = 2;
    uint64 internal constant CCIP_SOURCE = 14_767_482_510_784_806_043;
    uint64 internal constant CCIP_DESTINATION = 16_015_286_601_757_825_753;

    MockRouterClient internal router;
    ERC20 internal asset;
    BoringVault internal vault;
    MultiChainCCIPTellerWithMultiAssetSupport internal adapter;

    address internal remoteTeller = address(0xBEEF);
    address internal receiver = address(0xCAFE);

    function setUp() public {
        router = new MockRouterClient(0.01 ether);
        vault = new BoringVault(address(this), "Boring Vault", "BV", 18);
        asset = ERC20(address(vault));
        AccountantWithRateProviders accountant = new AccountantWithRateProviders(
            address(this), address(vault), address(this), 1e18, address(asset), 1e4, 1e4, 0, 0, 0
        );
        adapter =
            new MultiChainCCIPTellerWithMultiAssetSupport(address(this), address(vault), address(accountant), router);

        RolesAuthority authority = new RolesAuthority(address(this), Authority(address(0)));
        vault.setAuthority(authority);
        authority.setRoleCapability(MINTER_ROLE, address(vault), BoringVault.enter.selector, true);
        authority.setRoleCapability(BURNER_ROLE, address(vault), BoringVault.exit.selector, true);
        authority.setUserRole(address(this), MINTER_ROLE, true);
        authority.setUserRole(address(adapter), MINTER_ROLE, true);
        authority.setUserRole(address(adapter), BURNER_ROLE, true);

        adapter.addChain(SOURCE, false, false, remoteTeller, 100_000, 0);
        adapter.addChain(DESTINATION, false, false, remoteTeller, 100_000, 0);
        adapter.setCcipChainSelector(SOURCE, CCIP_SOURCE);
        adapter.setCcipChainSelector(DESTINATION, CCIP_DESTINATION);
        adapter.allowMessagesFromChain(SOURCE, remoteTeller);
        adapter.allowMessagesToChain(SOURCE, remoteTeller, 100_000);
        adapter.allowMessagesFromChain(DESTINATION, remoteTeller);
        adapter.allowMessagesToChain(DESTINATION, remoteTeller, 100_000);

        vault.enter(address(0), ERC20(address(0)), 0, address(this), 100 ether);
        vm.deal(address(this), 10 ether);
    }

    function test_previewFee_returns_router_fee() public view {
        assertEq(adapter.previewFee(1 ether, _bridgeData(receiver, ERC20(NATIVE))), 0.01 ether);
    }

    function test_previewFee_is_fee_only_and_does_not_guarantee_bridgeability() public {
        adapter.pause();
        assertEq(adapter.previewFee(1 ether, _bridgeData(receiver, ERC20(NATIVE))), 0.01 ether);
        vm.expectRevert();
        adapter.bridge{ value: 0.01 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        adapter.unpause();
        adapter.stopMessagesToChain(DESTINATION);
        assertEq(adapter.previewFee(1 ether, _bridgeData(receiver, ERC20(NATIVE))), 0.01 ether);
        vm.expectRevert();
        adapter.bridge{ value: 0.01 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));
    }

    function test_constructor_reverts_for_zero_router() public {
        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.InvalidRouter.selector);
        new MultiChainCCIPTellerWithMultiAssetSupport(
            address(this), address(vault), address(0xACCA), MockRouterClient(address(0))
        );
    }

    function test_ccip_v2_receiver_interface_and_default_finality_config() public view {
        assertTrue(adapter.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(adapter.supportsInterface(type(IAny2EVMMessageReceiverV2).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0xffffffff));

        (address[] memory requiredCCVs, address[] memory optionalCCVs, uint8 optionalThreshold, bytes4 finalityConfig) =
            adapter.getCCVsAndFinalityConfig(CCIP_SOURCE, abi.encode(remoteTeller));

        assertEq(requiredCCVs.length, 0);
        assertEq(optionalCCVs.length, 0);
        assertEq(optionalThreshold, 0);
        assertEq(finalityConfig, FinalityCodec.WAIT_FOR_FINALITY_FLAG);
    }

    function test_setCcipInboundAndOutboundFinalityConfig_updates_policy_for_trusted_sender() public {
        bytes4 requestedFinalityConfig = FinalityCodec.WAIT_FOR_SAFE_FLAG;
        bytes4 allowedFinalityConfig = FinalityCodec._encodeBlockDepthAndSafeFlag(10);

        adapter.setCcipOutboundFinalityConfig(DESTINATION, requestedFinalityConfig);
        adapter.setCcipInboundFinalityConfig(SOURCE, allowedFinalityConfig);

        assertEq(adapter.ccipOutboundFinalityConfig(DESTINATION), requestedFinalityConfig);
        assertEq(adapter.ccipInboundFinalityConfig(SOURCE), allowedFinalityConfig);

        (,,, bytes4 trustedFinalityConfig) = adapter.getCCVsAndFinalityConfig(CCIP_SOURCE, abi.encode(remoteTeller));
        assertEq(trustedFinalityConfig, allowedFinalityConfig);

        (,,, bytes4 wrongSenderFinalityConfig) =
            adapter.getCCVsAndFinalityConfig(CCIP_SOURCE, abi.encode(address(0xBAD)));
        assertEq(wrongSenderFinalityConfig, FinalityCodec.WAIT_FOR_FINALITY_FLAG);

        (,,, bytes4 malformedSenderFinalityConfig) =
            adapter.getCCVsAndFinalityConfig(CCIP_SOURCE, abi.encodePacked(remoteTeller));
        assertEq(malformedSenderFinalityConfig, FinalityCodec.WAIT_FOR_FINALITY_FLAG);

        (,,, bytes4 unknownSourceFinalityConfig) =
            adapter.getCCVsAndFinalityConfig(CCIP_SOURCE + 1, abi.encode(remoteTeller));
        assertEq(unknownSourceFinalityConfig, FinalityCodec.WAIT_FOR_FINALITY_FLAG);
    }

    function test_setCcipInboundAndOutboundFinalityConfig_requires_auth_and_nonzero_selector() public {
        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.InvalidChainSelector.selector);
        adapter.setCcipOutboundFinalityConfig(0, FinalityCodec.WAIT_FOR_SAFE_FLAG);

        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.InvalidChainSelector.selector);
        adapter.setCcipInboundFinalityConfig(0, FinalityCodec.WAIT_FOR_SAFE_FLAG);

        vm.prank(address(0xBAD));
        vm.expectRevert("UNAUTHORIZED");
        adapter.setCcipOutboundFinalityConfig(DESTINATION, FinalityCodec.WAIT_FOR_SAFE_FLAG);

        vm.prank(address(0xBAD));
        vm.expectRevert("UNAUTHORIZED");
        adapter.setCcipInboundFinalityConfig(SOURCE, FinalityCodec.WAIT_FOR_SAFE_FLAG);
    }

    function test_setCcipOutboundFinalityConfig_reverts_for_multi_mode_request() public {
        bytes4 invalidRequestedFinalityConfig = FinalityCodec._encodeBlockDepthAndSafeFlag(10);

        vm.expectRevert(
            abi.encodeWithSelector(
                FinalityCodec.RequestedFinalityCanOnlyHaveOneMode.selector, invalidRequestedFinalityConfig
            )
        );
        adapter.setCcipOutboundFinalityConfig(DESTINATION, invalidRequestedFinalityConfig);
    }

    function test_setCcipRateLimiterConfig_updates_current_state() public {
        adapter.setCcipRateLimiterConfig(
            DESTINATION, _rateLimit(true, 10 ether, 1 ether), _rateLimit(true, 5 ether, 0.5 ether)
        );

        (RateLimiter.TokenBucket memory outboundState, RateLimiter.TokenBucket memory inboundState) =
            adapter.getCurrentCcipRateLimiterState(DESTINATION);
        assertTrue(outboundState.isEnabled);
        assertEq(outboundState.capacity, 10 ether);
        assertEq(outboundState.rate, 1 ether);
        assertEq(outboundState.tokens, 10 ether);
        assertEq(outboundState.lastUpdated, block.timestamp);

        assertTrue(inboundState.isEnabled);
        assertEq(inboundState.capacity, 5 ether);
        assertEq(inboundState.rate, 0.5 ether);
        assertEq(inboundState.tokens, 5 ether);
        assertEq(inboundState.lastUpdated, block.timestamp);
    }

    function test_setCcipRateLimiterConfig_requires_auth_nonzero_selector_and_valid_config() public {
        RateLimiter.Config memory enabledConfig = _rateLimit(true, 10 ether, 1 ether);
        RateLimiter.Config memory disabledConfig = _rateLimit(false, 0, 0);

        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.InvalidChainSelector.selector);
        adapter.setCcipRateLimiterConfig(0, enabledConfig, disabledConfig);

        vm.prank(address(0xBAD));
        vm.expectRevert("UNAUTHORIZED");
        adapter.setCcipRateLimiterConfig(DESTINATION, enabledConfig, disabledConfig);

        RateLimiter.Config memory invalidRateConfig = _rateLimit(true, 1 ether, 2 ether);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidRateLimitRate.selector, invalidRateConfig));
        adapter.setCcipRateLimiterConfig(DESTINATION, invalidRateConfig, disabledConfig);

        RateLimiter.Config memory invalidDisabledConfig = _rateLimit(false, 1 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.DisabledNonZeroRateLimit.selector, invalidDisabledConfig));
        adapter.setCcipRateLimiterConfig(SOURCE, disabledConfig, invalidDisabledConfig);
    }

    function test_resetCcipChainConfig_requires_auth_and_disabled_lane() public {
        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.InvalidChainSelector.selector);
        adapter.resetCcipChainConfig(0);

        vm.expectRevert(
            abi.encodeWithSelector(MultiChainCCIPTellerWithMultiAssetSupport.CcipChainStillActive.selector, DESTINATION)
        );
        adapter.resetCcipChainConfig(DESTINATION);

        adapter.stopMessagesFromChain(DESTINATION);
        adapter.stopMessagesToChain(DESTINATION);
        vm.prank(address(0xBAD));
        vm.expectRevert("UNAUTHORIZED");
        adapter.resetCcipChainConfig(DESTINATION);
    }

    function test_resetCcipChainConfig_clears_sidecars_without_affecting_other_lanes() public {
        adapter.setCcipOutboundFinalityConfig(DESTINATION, FinalityCodec.WAIT_FOR_SAFE_FLAG);
        adapter.setCcipInboundFinalityConfig(DESTINATION, FinalityCodec.WAIT_FOR_SAFE_FLAG);
        adapter.setCcipRateLimiterConfig(
            DESTINATION, _rateLimit(true, 10 ether, 1 ether), _rateLimit(true, 5 ether, 0.5 ether)
        );
        adapter.stopMessagesFromChain(DESTINATION);
        adapter.stopMessagesToChain(DESTINATION);

        adapter.resetCcipChainConfig(DESTINATION);

        assertEq(adapter.chainSelectorToCcipSelector(DESTINATION), 0);
        assertEq(adapter.ccipSelectorToChainSelector(CCIP_DESTINATION), 0);
        assertEq(adapter.ccipOutboundFinalityConfig(DESTINATION), bytes4(0));
        assertEq(adapter.ccipInboundFinalityConfig(DESTINATION), bytes4(0));
        (RateLimiter.TokenBucket memory outboundState, RateLimiter.TokenBucket memory inboundState) =
            adapter.getCurrentCcipRateLimiterState(DESTINATION);
        assertFalse(outboundState.isEnabled);
        assertEq(outboundState.tokens, 0);
        assertEq(outboundState.capacity, 0);
        assertEq(outboundState.rate, 0);
        assertFalse(inboundState.isEnabled);
        assertEq(inboundState.tokens, 0);
        assertEq(inboundState.capacity, 0);
        assertEq(inboundState.rate, 0);

        assertEq(adapter.chainSelectorToCcipSelector(SOURCE), CCIP_SOURCE);
        assertEq(adapter.ccipSelectorToChainSelector(CCIP_SOURCE), SOURCE);

        adapter.resetCcipChainConfig(DESTINATION);
    }

    function test_setCcipChainSelector_reverts_while_lane_is_active() public {
        vm.expectRevert(
            abi.encodeWithSelector(MultiChainCCIPTellerWithMultiAssetSupport.CcipChainStillActive.selector, SOURCE)
        );
        adapter.setCcipChainSelector(SOURCE, CCIP_SOURCE + 1);

        adapter.stopMessagesToChain(SOURCE);
        vm.expectRevert(
            abi.encodeWithSelector(MultiChainCCIPTellerWithMultiAssetSupport.CcipChainStillActive.selector, SOURCE)
        );
        adapter.setCcipChainSelector(SOURCE, CCIP_SOURCE + 1);
        adapter.stopMessagesFromChain(SOURCE);
        adapter.setCcipChainSelector(SOURCE, CCIP_SOURCE + 1);
        assertEq(adapter.chainSelectorToCcipSelector(SOURCE), CCIP_SOURCE + 1);
        assertEq(adapter.ccipSelectorToChainSelector(CCIP_SOURCE), 0);
    }

    function test_setCcipChainSelector_reprovisioning_after_disable_reenable_flow() public {
        adapter.stopMessagesFromChain(DESTINATION);
        adapter.stopMessagesToChain(DESTINATION);
        adapter.setCcipChainSelector(DESTINATION, CCIP_DESTINATION + 1);

        adapter.allowMessagesFromChain(DESTINATION, remoteTeller);
        adapter.allowMessagesToChain(DESTINATION, remoteTeller, 100_000);
        adapter.bridge{ value: 0.01 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));
        assertEq(vault.balanceOf(address(this)), 99 ether);
    }

    function test_setCcipChainSelector_reverts_for_zero_selector() public {
        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.InvalidChainSelector.selector);
        adapter.setCcipChainSelector(0, CCIP_DESTINATION);

        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.InvalidChainSelector.selector);
        adapter.setCcipChainSelector(DESTINATION, 0);
    }

    function test_setCcipChainSelector_rejects_stealing_selector_from_active_lane() public {
        uint32 thiefKey = DESTINATION + 7;
        adapter.addChain(thiefKey, false, false, remoteTeller, 100_000, 0);

        vm.expectRevert(
            abi.encodeWithSelector(MultiChainCCIPTellerWithMultiAssetSupport.CcipChainStillActive.selector, SOURCE)
        );
        adapter.setCcipChainSelector(thiefKey, CCIP_SOURCE);

        assertEq(adapter.chainSelectorToCcipSelector(SOURCE), CCIP_SOURCE);
        assertEq(adapter.ccipSelectorToChainSelector(CCIP_SOURCE), SOURCE);
        assertEq(adapter.chainSelectorToCcipSelector(thiefKey), 0);

        adapter.stopMessagesFromChain(SOURCE);
        adapter.stopMessagesToChain(SOURCE);
        adapter.setCcipChainSelector(thiefKey, CCIP_SOURCE);
        assertEq(adapter.chainSelectorToCcipSelector(SOURCE), 0);
        assertEq(adapter.ccipSelectorToChainSelector(CCIP_SOURCE), thiefKey);
    }

    function test_previewFee_reverts_for_non_native_fee_token_and_unmapped_destination() public {
        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.InvalidBridgeFeeToken.selector);
        adapter.previewFee(1 ether, _bridgeData(receiver, asset));

        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.InvalidChainSelector.selector);
        adapter.previewFee(1 ether, _bridgeData(DESTINATION + 1, receiver, ERC20(NATIVE)));
    }

    function test_previewFee_reverts_for_message_gas_above_ccip_v2_limit() public {
        BridgeData memory data = _bridgeData(receiver, ERC20(NATIVE));
        data.messageGas = uint64(type(uint32).max) + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                MultiChainCCIPTellerWithMultiAssetSupport.MessageGasLimitTooHigh.selector, data.messageGas
            )
        );
        adapter.previewFee(1 ether, data);
    }

    function test_previewFee_falls_back_to_legacy_v1_when_router_rejects_v3() public {
        router.setRejectedExtraArgsTag(ExtraArgsCodec.GENERIC_EXTRA_ARGS_V3_TAG);

        assertEq(adapter.previewFee(1 ether, _bridgeData(receiver, ERC20(NATIVE))), 0.01 ether);
    }

    function test_previewFee_bubbles_non_extraArgs_quote_reverts() public {
        router.setRevertFeeQuoteWithoutReason(true);

        vm.expectRevert();
        adapter.previewFee(1 ether, _bridgeData(receiver, ERC20(NATIVE)));
    }

    function test_previewFee_bubbles_malformed_extraArgs_tag_reverts() public {
        bytes memory reason = abi.encodePacked(MockRouterClient.InvalidExtraArgsTag.selector, bytes1(0));
        router.setFeeQuoteRevertReason(reason);
        vm.expectRevert(reason);
        adapter.previewFee(1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        reason = abi.encodePacked(ExtraArgsCodec.InvalidExtraArgsTag.selector);
        router.setFeeQuoteRevertReason(reason);
        vm.expectRevert(reason);
        adapter.previewFee(1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        reason = abi.encodeWithSelector(ExtraArgsCodec.InvalidExtraArgsTag.selector, bytes4(0), bytes4(0xdeadbeef));
        router.setFeeQuoteRevertReason(reason);
        vm.expectRevert(reason);
        adapter.previewFee(1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        reason = bytes.concat(
            abi.encodeWithSelector(
                ExtraArgsCodec.InvalidExtraArgsTag.selector, bytes4(0), ExtraArgsCodec.GENERIC_EXTRA_ARGS_V3_TAG
            ),
            hex"00"
        );
        router.setFeeQuoteRevertReason(reason);
        vm.expectRevert(reason);
        adapter.previewFee(1 ether, _bridgeData(receiver, ERC20(NATIVE)));
    }

    function test_bridge_sends_message_with_exact_native_fee() public {
        uint256 balanceBefore = address(this).balance;

        bytes32 messageId = adapter.bridge{ value: 0.01 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        assertEq(messageId, router.lastMessageId());
        assertEq(router.lastDestinationChainSelector(), CCIP_DESTINATION);
        assertEq(router.lastReceiver(), abi.encode(remoteTeller));
        assertEq(router.lastData(), abi.encode(1 ether, receiver));
        assertEq(router.lastExtraArgs(), ExtraArgsCodec._getBasicEncodedExtraArgsV3(80_000, bytes4(0)));
        assertEq(router.lastFeeToken(), address(0));
        assertEq(router.lastMsgValue(), 0.01 ether);
        assertEq(address(this).balance, balanceBefore - 0.01 ether);
        assertEq(vault.balanceOf(address(this)), 99 ether);
    }

    function test_bridge_sends_message_with_configured_requested_finality() public {
        adapter.setCcipOutboundFinalityConfig(DESTINATION, FinalityCodec.WAIT_FOR_SAFE_FLAG);

        adapter.bridge{ value: 0.01 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        assertEq(
            router.lastExtraArgs(), ExtraArgsCodec._getBasicEncodedExtraArgsV3(80_000, FinalityCodec.WAIT_FOR_SAFE_FLAG)
        );
    }

    function test_bridge_consumes_outbound_rate_limit_and_reverts_when_exceeded() public {
        adapter.setCcipRateLimiterConfig(DESTINATION, _rateLimit(true, 1 ether, 0), _rateLimit(false, 0, 0));

        adapter.bridge{ value: 0.01 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        (RateLimiter.TokenBucket memory outboundState,) = adapter.getCurrentCcipRateLimiterState(DESTINATION);
        assertEq(outboundState.tokens, 0);
        assertEq(vault.balanceOf(address(this)), 99 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                RateLimiter.TokenRateLimitReached.selector, type(uint256).max, uint256(0), address(vault)
            )
        );
        adapter.bridge{ value: 0.01 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        assertEq(vault.balanceOf(address(this)), 99 ether);
    }

    function test_bridge_refills_outbound_rate_limit() public {
        adapter.setCcipRateLimiterConfig(DESTINATION, _rateLimit(true, 2 ether, 1 ether), _rateLimit(false, 0, 0));

        adapter.bridge{ value: 0.01 ether }(2 ether, _bridgeData(receiver, ERC20(NATIVE)));
        (RateLimiter.TokenBucket memory outboundState,) = adapter.getCurrentCcipRateLimiterState(DESTINATION);
        assertEq(outboundState.tokens, 0);

        vm.warp(block.timestamp + 1);
        adapter.bridge{ value: 0.01 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        (outboundState,) = adapter.getCurrentCcipRateLimiterState(DESTINATION);
        assertEq(outboundState.tokens, 0);
        assertEq(vault.balanceOf(address(this)), 97 ether);
    }

    function test_bridge_falls_back_to_legacy_v1_when_router_rejects_v3() public {
        router.setRejectedExtraArgsTag(ExtraArgsCodec.GENERIC_EXTRA_ARGS_V3_TAG);

        adapter.bridge{ value: 0.01 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        assertEq(router.lastExtraArgs(), Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: 80_000 })));
        assertEq(router.lastMsgValue(), 0.01 ether);
        assertEq(vault.balanceOf(address(this)), 99 ether);
    }

    function test_bridge_falls_back_to_legacy_v1_when_router_rejects_v3_with_typed_error() public {
        router.setRejectedExtraArgsTag(ExtraArgsCodec.GENERIC_EXTRA_ARGS_V3_TAG);
        router.setUseTypedExtraArgsTagError(true);

        adapter.bridge{ value: 0.01 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        assertEq(router.lastExtraArgs(), Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: 80_000 })));
        assertEq(router.lastMsgValue(), 0.01 ether);
        assertEq(vault.balanceOf(address(this)), 99 ether);
    }

    function test_previewFee_reverts_instead_of_dropping_configured_fast_finality_to_legacy_v1() public {
        adapter.setCcipOutboundFinalityConfig(DESTINATION, FinalityCodec.WAIT_FOR_SAFE_FLAG);
        router.setRejectedExtraArgsTag(ExtraArgsCodec.GENERIC_EXTRA_ARGS_V3_TAG);

        vm.expectRevert(MockRouterClient.InvalidExtraArgsTag.selector);
        adapter.previewFee(1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        router.setUseTypedExtraArgsTagError(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExtraArgsCodec.InvalidExtraArgsTag.selector, bytes4(0), ExtraArgsCodec.GENERIC_EXTRA_ARGS_V3_TAG
            )
        );
        adapter.previewFee(1 ether, _bridgeData(receiver, ERC20(NATIVE)));
    }

    function test_bridge_reverts_for_non_native_fee_token() public {
        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.InvalidBridgeFeeToken.selector);
        adapter.bridge(1 ether, _bridgeData(receiver, asset));
    }

    function test_bridge_and_depositAndBridge_revert_for_nonzero_share_lock_period() public {
        adapter.setShareLockPeriod(1 days);
        vm.expectRevert(
            abi.encodeWithSelector(MultiChainCCIPTellerWithMultiAssetSupport.NonZeroShareLockPeriod.selector, 1 days)
        );
        adapter.bridge{ value: 0.01 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));
        assertEq(vault.balanceOf(address(this)), 100 ether);

        adapter.addDepositAsset(asset);
        vault.approve(address(vault), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(MultiChainCCIPTellerWithMultiAssetSupport.NonZeroShareLockPeriod.selector, 1 days)
        );
        adapter.depositAndBridge{ value: 0.01 ether }(asset, 1 ether, 1 ether, _bridgeData(receiver, ERC20(NATIVE)));

        assertEq(vault.balanceOf(address(this)), 100 ether);
        assertEq(adapter.depositNonce(), 1);
    }

    function test_bridge_reverts_for_insufficient_native_fee() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiChainCCIPTellerWithMultiAssetSupport.IncorrectNativeFee.selector, 0.01 ether, 0.009 ether
            )
        );
        adapter.bridge{ value: 0.009 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));
    }

    function test_bridge_reverts_for_excess_native_fee() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiChainCCIPTellerWithMultiAssetSupport.IncorrectNativeFee.selector, 0.01 ether, 0.02 ether
            )
        );
        adapter.bridge{ value: 0.02 ether }(1 ether, _bridgeData(receiver, ERC20(NATIVE)));
    }

    function test_ccipReceive_reverts_when_not_router() public {
        vm.expectRevert(
            abi.encodeWithSelector(MultiChainCCIPTellerWithMultiAssetSupport.CallerMustBeRouter.selector, address(this))
        );
        adapter.ccipReceive(_message(remoteTeller, receiver, 1 ether));
    }

    function test_ccipReceive_reverts_for_wrong_sender() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiChainTellerBase_MessagesNotAllowedFromSender.selector, uint256(SOURCE), address(0xBAD)
            )
        );
        router.routeMessage(address(adapter), _message(address(0xBAD), receiver, 1 ether));
    }

    function test_ccipReceive_reverts_for_unmapped_source_messages_disabled_bad_sender_and_zero_receiver() public {
        Client.Any2EVMMessage memory message = _message(remoteTeller, receiver, 1 ether);
        message.sourceChainSelector = CCIP_SOURCE + 1;
        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.InvalidChainSelector.selector);
        router.routeMessage(address(adapter), message);

        adapter.stopMessagesFromChain(SOURCE);
        vm.expectRevert(abi.encodeWithSelector(MultiChainTellerBase_MessagesNotAllowedFrom.selector, SOURCE));
        router.routeMessage(address(adapter), _message(remoteTeller, receiver, 1 ether));

        adapter.allowMessagesFromChain(SOURCE, remoteTeller);
        message = _message(remoteTeller, receiver, 1 ether);
        message.sender = abi.encodePacked(remoteTeller);
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiChainCCIPTellerWithMultiAssetSupport.InvalidSenderBytes.selector, message.sender
            )
        );
        router.routeMessage(address(adapter), message);

        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.ZeroAddressDestinationReceiver.selector);
        router.routeMessage(address(adapter), _message(remoteTeller, address(0), 1 ether));
    }

    function test_ccipReceive_mints_shares() public {
        Client.Any2EVMMessage memory message = _message(remoteTeller, receiver, 1 ether);
        router.routeMessage(address(adapter), message);

        assertEq(vault.balanceOf(receiver), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(MockRouterClient.MessageAlreadyRouted.selector, message.messageId));
        router.routeMessage(address(adapter), message);
        assertEq(vault.balanceOf(receiver), 1 ether);
    }

    function test_failed_ccipReceive_remains_retryable() public {
        Client.Any2EVMMessage memory message = _message(address(0xBAD), receiver, 1 ether);
        vm.expectRevert();
        router.routeMessage(address(adapter), message);
        assertFalse(router.routedMessages(message.messageId));

        adapter.allowMessagesFromChain(SOURCE, address(0xBAD));
        router.routeMessage(address(adapter), message);
        assertTrue(router.routedMessages(message.messageId));
        assertEq(vault.balanceOf(receiver), 1 ether);
    }

    function test_ccipReceive_reverts_for_token_amounts_without_consuming_rate_limit() public {
        adapter.setCcipRateLimiterConfig(SOURCE, _rateLimit(false, 0, 0), _rateLimit(true, 1 ether, 0));
        Client.Any2EVMMessage memory message = _message(remoteTeller, receiver, 1 ether);
        message.destTokenAmounts = new Client.EVMTokenAmount[](1);
        message.destTokenAmounts[0] = Client.EVMTokenAmount({ token: address(asset), amount: 1 ether });

        vm.expectRevert(MultiChainCCIPTellerWithMultiAssetSupport.UnexpectedTokenAmounts.selector);
        router.routeMessage(address(adapter), message);

        (, RateLimiter.TokenBucket memory inboundState) = adapter.getCurrentCcipRateLimiterState(SOURCE);
        assertEq(inboundState.tokens, 1 ether);
        assertEq(vault.balanceOf(receiver), 0);
    }

    function test_ccipReceive_consumes_inbound_rate_limit_and_reverts_when_exceeded() public {
        adapter.setCcipRateLimiterConfig(SOURCE, _rateLimit(false, 0, 0), _rateLimit(true, 1 ether, 0));

        router.routeMessage(address(adapter), _message(remoteTeller, receiver, 1 ether));

        (, RateLimiter.TokenBucket memory inboundState) = adapter.getCurrentCcipRateLimiterState(SOURCE);
        assertEq(inboundState.tokens, 0);
        assertEq(vault.balanceOf(receiver), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                RateLimiter.TokenRateLimitReached.selector, type(uint256).max, uint256(0), address(vault)
            )
        );
        Client.Any2EVMMessage memory secondMessage = _message(remoteTeller, receiver, 1 ether);
        secondMessage.messageId = keccak256("second message");
        router.routeMessage(address(adapter), secondMessage);

        assertEq(vault.balanceOf(receiver), 1 ether);
    }

    function _bridgeData(address destinationReceiver, ERC20 feeToken) internal pure returns (BridgeData memory) {
        return _bridgeData(DESTINATION, destinationReceiver, feeToken);
    }

    function _bridgeData(
        uint32 chainSelector,
        address destinationReceiver,
        ERC20 feeToken
    )
        internal
        pure
        returns (BridgeData memory)
    {
        return BridgeData({
            chainSelector: chainSelector,
            destinationChainReceiver: destinationReceiver,
            bridgeFeeToken: feeToken,
            messageGas: 80_000,
            data: ""
        });
    }

    function _message(
        address sender,
        address destinationReceiver,
        uint256 shareAmount
    )
        internal
        pure
        returns (Client.Any2EVMMessage memory message)
    {
        message.messageId = keccak256("message");
        message.sourceChainSelector = CCIP_SOURCE;
        message.sender = abi.encode(sender);
        message.data = abi.encode(shareAmount, destinationReceiver);
        message.destTokenAmounts = new Client.EVMTokenAmount[](0);
    }

    function _rateLimit(
        bool isEnabled,
        uint128 capacity,
        uint128 rate
    )
        internal
        pure
        returns (RateLimiter.Config memory)
    {
        return RateLimiter.Config({ isEnabled: isEnabled, capacity: capacity, rate: rate });
    }

}
