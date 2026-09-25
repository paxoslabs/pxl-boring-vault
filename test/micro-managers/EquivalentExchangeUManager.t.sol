// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { EquivalentExchangeUManager } from "src/micro-managers/EquivalentExchangeUManager.sol";
import { MockManagerWithVault } from "./mocks/MockManagerWithVault.sol";

/// @notice Unit tests for EquivalentExchangeUManager's external/public surface.
contract EquivalentExchangeUManagerTest is Test {

    // Re-declared so the test can build the expected event for vm.expectEmit.
    event BasketTokensUpdated(EquivalentExchangeUManager.BasketToken[] tokens);

    EquivalentExchangeUManager internal uManager;
    address internal boringVault;

    ERC20 internal tokenA;
    ERC20 internal tokenB;
    ERC20 internal tokenC;
    ERC20 internal tokenD;

    IRateProvider internal oracleA;
    IRateProvider internal oracleB;

    function setUp() external {
        // owner = this test contract; with no Authority set, only the owner passes requiresAuth. The manager
        // is a mock whose vault() the UManager reads to derive boringVault; neither is exercised by basket
        // bookkeeping.
        boringVault = makeAddr("boringVault");
        uManager = new EquivalentExchangeUManager(address(this), address(new MockManagerWithVault(boringVault)));

        tokenA = ERC20(makeAddr("tokenA"));
        tokenB = ERC20(makeAddr("tokenB"));
        tokenC = ERC20(makeAddr("tokenC"));
        tokenD = ERC20(makeAddr("tokenD"));

        // These accessor/bookkeeping tests never call getRate(), so codeless stand-ins are sufficient.
        oracleA = IRateProvider(makeAddr("oracleA"));
        oracleB = IRateProvider(makeAddr("oracleB"));
    }

    // ============================== helpers ==============================

    /// @notice Wraps a token as a 1:1 USD basket entry (no oracle).
    function _usd(ERC20 token) internal pure returns (EquivalentExchangeUManager.BasketToken memory) {
        return EquivalentExchangeUManager.BasketToken({
            token: token,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
    }

    /// @notice Wraps a token as an oracle-priced basket entry. rateDecimals fixed at 18 for these config tests.
    function _priced(
        ERC20 token,
        IRateProvider oracle
    )
        internal
        pure
        returns (EquivalentExchangeUManager.BasketToken memory)
    {
        return EquivalentExchangeUManager.BasketToken({
            token: token,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: false, rateProvider: oracle, rateDecimals: 18
            })
        });
    }

    function _empty() internal pure returns (EquivalentExchangeUManager.BasketToken[] memory) {
        return new EquivalentExchangeUManager.BasketToken[](0);
    }

    function _arr(ERC20 t0) internal pure returns (EquivalentExchangeUManager.BasketToken[] memory a) {
        a = new EquivalentExchangeUManager.BasketToken[](1);
        a[0] = _usd(t0);
    }

    function _arr(ERC20 t0, ERC20 t1) internal pure returns (EquivalentExchangeUManager.BasketToken[] memory a) {
        a = new EquivalentExchangeUManager.BasketToken[](2);
        a[0] = _usd(t0);
        a[1] = _usd(t1);
    }

    function _arr(
        ERC20 t0,
        ERC20 t1,
        ERC20 t2
    )
        internal
        pure
        returns (EquivalentExchangeUManager.BasketToken[] memory a)
    {
        a = new EquivalentExchangeUManager.BasketToken[](3);
        a[0] = _usd(t0);
        a[1] = _usd(t1);
        a[2] = _usd(t2);
    }

    // ============================== setBasketTokens: happy paths ==============================

    function test_SetBasketTokens_StoresTokensInOrder() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB, tokenC));

        EquivalentExchangeUManager.BasketToken[] memory stored = uManager.getBasketTokens();
        assertEq(stored.length, 3);
        // EnumerableSet preserves insertion order when there have been no removals.
        assertEq(address(stored[0].token), address(tokenA));
        assertEq(address(stored[1].token), address(tokenB));
        assertEq(address(stored[2].token), address(tokenC));

        assertTrue(uManager.isBasketToken(tokenA));
        assertTrue(uManager.isBasketToken(tokenB));
        assertTrue(uManager.isBasketToken(tokenC));
        assertFalse(uManager.isBasketToken(tokenD));
    }

    function test_SetBasketTokens_ReplacesPreviousBasket() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB, tokenC));

        // Overwrite with a disjoint set; exercises the removal loop that clears the old set.
        uManager.setBasketTokens(_arr(tokenD));

        EquivalentExchangeUManager.BasketToken[] memory stored = uManager.getBasketTokens();
        assertEq(stored.length, 1);
        assertEq(address(stored[0].token), address(tokenD));

        // All previous tokens must be gone.
        assertFalse(uManager.isBasketToken(tokenA));
        assertFalse(uManager.isBasketToken(tokenB));
        assertFalse(uManager.isBasketToken(tokenC));
        assertTrue(uManager.isBasketToken(tokenD));
    }

    function test_SetBasketTokens_OverlappingReplacementKeepsMembership() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB));
        // New basket shares tokenB and adds tokenC; tokenA must drop out.
        uManager.setBasketTokens(_arr(tokenB, tokenC));

        assertFalse(uManager.isBasketToken(tokenA));
        assertTrue(uManager.isBasketToken(tokenB));
        assertTrue(uManager.isBasketToken(tokenC));
        assertEq(uManager.getBasketTokens().length, 2);
    }

    function test_SetBasketTokens_EmptiesSizeOneBasket() external {
        uManager.setBasketTokens(_arr(tokenA));

        uManager.setBasketTokens(_empty());

        assertEq(uManager.getBasketTokens().length, 0);
        assertFalse(uManager.isBasketToken(tokenA));
    }

    function test_SetBasketTokens_EmptiesSizeTwoBasket() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB));

        uManager.setBasketTokens(_empty());

        assertEq(uManager.getBasketTokens().length, 0);
        assertFalse(uManager.isBasketToken(tokenA));
        assertFalse(uManager.isBasketToken(tokenB));
    }

    function test_SetBasketTokens_EmptiesSizeThreeBasket() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB, tokenC));

        uManager.setBasketTokens(_empty());

        assertEq(uManager.getBasketTokens().length, 0);
        assertFalse(uManager.isBasketToken(tokenA));
        assertFalse(uManager.isBasketToken(tokenB));
        assertFalse(uManager.isBasketToken(tokenC));
    }

    function test_SetBasketTokens_RevertWhen_DuplicateToken() external {
        // Duplicates in the input are rejected rather than silently collapsed.
        EquivalentExchangeUManager.BasketToken[] memory tokens = new EquivalentExchangeUManager.BasketToken[](3);
        tokens[0] = _usd(tokenA);
        tokens[1] = _usd(tokenA);
        tokens[2] = _usd(tokenB);

        vm.expectRevert(abi.encodeWithSelector(EquivalentExchangeUManager.DuplicateToken.selector, address(tokenA)));
        uManager.setBasketTokens(tokens);
    }

    function test_SetBasketTokens_RevertWhen_DuplicateTokenDiffersOnlyByOracle() external {
        // The same address as USD and as oracle-priced is still a duplicate address and must be rejected.
        EquivalentExchangeUManager.BasketToken[] memory tokens = new EquivalentExchangeUManager.BasketToken[](2);
        tokens[0] = _usd(tokenA);
        tokens[1] = _priced(tokenA, oracleA);

        vm.expectRevert(abi.encodeWithSelector(EquivalentExchangeUManager.DuplicateToken.selector, address(tokenA)));
        uManager.setBasketTokens(tokens);
    }

    function test_SetBasketTokens_RevertWhen_BasketTooLarge() external {
        // One past the bitmap width (256) has no flag bit to bind to, so it is rejected.
        EquivalentExchangeUManager.BasketToken[] memory tokens = new EquivalentExchangeUManager.BasketToken[](257);
        for (uint256 i; i < 257; ++i) {
            tokens[i] = _usd(ERC20(address(uint160(i + 1))));
        }

        vm.expectRevert(EquivalentExchangeUManager.BasketTooLarge.selector);
        uManager.setBasketTokens(tokens);
    }

    function test_SetBasketTokens_AllowsMaxBasketSize() external {
        // Exactly the bitmap width (256) is allowed; the last token maps to bit 255.
        EquivalentExchangeUManager.BasketToken[] memory tokens = new EquivalentExchangeUManager.BasketToken[](256);
        for (uint256 i; i < 256; ++i) {
            tokens[i] = _usd(ERC20(address(uint160(i + 1))));
        }

        uManager.setBasketTokens(tokens);
        assertEq(uManager.getBasketTokens().length, 256);
    }

    function test_SetBasketTokens_IdempotentWhenReapplyingSameSet() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB));
        uManager.setBasketTokens(_arr(tokenA, tokenB));

        EquivalentExchangeUManager.BasketToken[] memory stored = uManager.getBasketTokens();
        assertEq(stored.length, 2);
        assertEq(address(stored[0].token), address(tokenA));
        assertEq(address(stored[1].token), address(tokenB));
    }

    // ============================== setBasketTokens: oracle config ==============================

    function test_SetBasketTokens_StoresOracleForPricedToken() external {
        EquivalentExchangeUManager.BasketToken[] memory tokens = new EquivalentExchangeUManager.BasketToken[](2);
        tokens[0] = _usd(tokenA);
        tokens[1] = _priced(tokenB, oracleA);

        uManager.setBasketTokens(tokens);

        // getBasketTokens is the source of truth: a USD token pairs with the zero oracle, an oracle-priced
        // token with its provider, in stored order.
        EquivalentExchangeUManager.BasketToken[] memory stored = uManager.getBasketTokens();
        assertEq(stored.length, 2);
        assertEq(address(stored[0].token), address(tokenA));
        assertEq(address(stored[0].config.rateProvider), address(0));
        assertEq(stored[0].config.rateDecimals, 0);
        assertEq(address(stored[1].token), address(tokenB));
        assertEq(address(stored[1].config.rateProvider), address(oracleA));
        assertEq(stored[1].config.rateDecimals, 18);
        assertTrue(uManager.isBasketToken(tokenB));
    }

    function test_SetBasketTokens_RevertWhen_OracleSetButRateDecimalsZero() external {
        // A priced token (isPeggedToken: false) with no rate decimals is a config mistake (the rate would be
        // scaled wrong).
        EquivalentExchangeUManager.BasketToken[] memory tokens = new EquivalentExchangeUManager.BasketToken[](1);
        tokens[0] = EquivalentExchangeUManager.BasketToken({
            token: tokenA,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: false, rateProvider: oracleA, rateDecimals: 0
            })
        });

        vm.expectRevert(
            abi.encodeWithSelector(EquivalentExchangeUManager.InvalidRateProviderConfig.selector, address(tokenA))
        );
        uManager.setBasketTokens(tokens);
    }

    function test_SetBasketTokens_RevertWhen_RateDecimalsSetButNoOracle() external {
        // A pegged token (isPeggedToken: true) carrying stray rate decimals is a config mistake; decimals only
        // apply with an oracle.
        EquivalentExchangeUManager.BasketToken[] memory tokens = new EquivalentExchangeUManager.BasketToken[](1);
        tokens[0] = EquivalentExchangeUManager.BasketToken({
            token: tokenA,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 8
            })
        });

        vm.expectRevert(
            abi.encodeWithSelector(EquivalentExchangeUManager.InvalidRateProviderConfig.selector, address(tokenA))
        );
        uManager.setBasketTokens(tokens);
    }

    function test_SetBasketTokens_RevertWhen_PeggedButOracleProvided() external {
        // isPeggedToken must be false when an oracle + decimals are supplied; a mismatched flag is rejected so
        // a priced token can never be mislabeled as 1:1.
        EquivalentExchangeUManager.BasketToken[] memory tokens = new EquivalentExchangeUManager.BasketToken[](1);
        tokens[0] = EquivalentExchangeUManager.BasketToken({
            token: tokenA,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: oracleA, rateDecimals: 18
            })
        });

        vm.expectRevert(
            abi.encodeWithSelector(EquivalentExchangeUManager.InvalidRateProviderConfig.selector, address(tokenA))
        );
        uManager.setBasketTokens(tokens);
    }

    function test_SetBasketTokens_RevertWhen_NotPeggedButNoOracle() external {
        // isPeggedToken must be true when no oracle is supplied; declaring a token priced while leaving its
        // fields zero is rejected so a forgotten oracle can never be silently treated as 1:1.
        EquivalentExchangeUManager.BasketToken[] memory tokens = new EquivalentExchangeUManager.BasketToken[](1);
        tokens[0] = EquivalentExchangeUManager.BasketToken({
            token: tokenA,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: false, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });

        vm.expectRevert(
            abi.encodeWithSelector(EquivalentExchangeUManager.InvalidRateProviderConfig.selector, address(tokenA))
        );
        uManager.setBasketTokens(tokens);
    }

    function test_SetBasketTokens_DropsOracleWhenTokenRemoved() external {
        EquivalentExchangeUManager.BasketToken[] memory tokens = new EquivalentExchangeUManager.BasketToken[](1);
        tokens[0] = _priced(tokenB, oracleA);
        uManager.setBasketTokens(tokens);
        assertEq(address(uManager.getBasketTokens()[0].config.rateProvider), address(oracleA));

        // Replacing the basket without tokenB must drop it entirely, oracle included.
        uManager.setBasketTokens(_arr(tokenA));
        EquivalentExchangeUManager.BasketToken[] memory stored = uManager.getBasketTokens();
        assertEq(stored.length, 1);
        assertEq(address(stored[0].token), address(tokenA));
        assertEq(address(stored[0].config.rateProvider), address(0));
        assertFalse(uManager.isBasketToken(tokenB));
    }

    function test_SetBasketTokens_UpdatesOracleForSameToken() external {
        EquivalentExchangeUManager.BasketToken[] memory first = new EquivalentExchangeUManager.BasketToken[](1);
        first[0] = _priced(tokenB, oracleA);
        uManager.setBasketTokens(first);
        assertEq(address(uManager.getBasketTokens()[0].config.rateProvider), address(oracleA));

        // Re-set the same token with a different oracle; the stored pairing must reflect the latest provider.
        EquivalentExchangeUManager.BasketToken[] memory second = new EquivalentExchangeUManager.BasketToken[](1);
        second[0] = _priced(tokenB, oracleB);
        uManager.setBasketTokens(second);
        assertEq(address(uManager.getBasketTokens()[0].config.rateProvider), address(oracleB));
    }

    function test_SetBasketTokens_DropsOracleWhenTokenBecomesUsd() external {
        EquivalentExchangeUManager.BasketToken[] memory first = new EquivalentExchangeUManager.BasketToken[](1);
        first[0] = _priced(tokenB, oracleA);
        uManager.setBasketTokens(first);

        // Same token re-added as a USD asset must no longer report an oracle: the stale provider must not
        // be inherited.
        uManager.setBasketTokens(_arr(tokenB));
        assertEq(address(uManager.getBasketTokens()[0].config.rateProvider), address(0));
    }

    function test_SetBasketTokens_OracleFlagsBindByPosition() external {
        // Only the middle token is oracle-priced: the flag must attach to index 1, not leak to its
        // neighbors.
        EquivalentExchangeUManager.BasketToken[] memory tokens = new EquivalentExchangeUManager.BasketToken[](3);
        tokens[0] = _usd(tokenA);
        tokens[1] = _priced(tokenB, oracleA);
        tokens[2] = _usd(tokenC);
        uManager.setBasketTokens(tokens);

        EquivalentExchangeUManager.BasketToken[] memory stored = uManager.getBasketTokens();
        assertEq(address(stored[0].config.rateProvider), address(0));
        assertEq(address(stored[1].config.rateProvider), address(oracleA));
        assertEq(address(stored[2].config.rateProvider), address(0));
    }

    // ============================== setBasketTokens: events ==============================

    function test_SetBasketTokens_EmitsResultingSet() external {
        vm.expectEmit(true, true, true, true, address(uManager));
        emit BasketTokensUpdated(_arr(tokenA, tokenB));

        uManager.setBasketTokens(_arr(tokenA, tokenB));
    }

    // ============================== setBasketTokens: access control ==============================

    function test_SetBasketTokens_RevertWhen_CallerNotAuthorized() external {
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        uManager.setBasketTokens(_arr(tokenA));
    }

    // ============================== execute: guard reverts ==============================
    // These paths revert before execute reaches the manager/vault, so they need no integration
    // stack: the basket tokens are never called and _manageVaultWithMerkleVerification is unreachable.

    function _noCalls() internal pure returns (EquivalentExchangeUManager.ManageCalls memory) {
        return EquivalentExchangeUManager.ManageCalls({
            manageProofs: new bytes32[][](0),
            decodersAndSanitizers: new address[](0),
            targets: new address[](0),
            targetData: new bytes[](0),
            values: new uint256[](0)
        });
    }

    /// @notice `length` bounds, each pinned to {0, 0}. Only the length matters to the guards below.
    function _zeroDeltas(uint256 length) internal pure returns (int256[] memory d) {
        d = new int256[](length);
    }

    function _noDeltas() internal pure returns (int256[] memory) {
        return _zeroDeltas(0);
    }

    function test_Execute_RevertWhen_BasketEmpty() external {
        // No basket configured, so execute reverts at the first guard before any token is touched.
        vm.expectRevert(EquivalentExchangeUManager.EmptyBasket.selector);
        uManager.execute(_noCalls(), makeAddr("payer"), tokenA, _noDeltas());
    }

    function test_Execute_RevertWhen_SubsidyTokenNotInBasket() external {
        uManager.setBasketTokens(_arr(tokenA));

        // tokenB is not part of the basket; the guard fires before any balance is read, so the codeless
        // dummy basket token is never called.
        vm.expectRevert(EquivalentExchangeUManager.TokenNotInBasket.selector);
        uManager.execute(_noCalls(), makeAddr("payer"), tokenB, _noDeltas());
    }

    function test_Execute_RevertWhen_CallerNotAuthorized() external {
        uManager.setBasketTokens(_arr(tokenA));

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        uManager.execute(_noCalls(), makeAddr("payer"), tokenA, _noDeltas());
    }

    function test_Execute_RevertWhen_DeltaLengthDoesNotMatchBasket() external {
        // Bounds bind to basket tokens by position, so only an exactly basket-length array is accepted.
        uManager.setBasketTokens(_arr(tokenA));

        vm.expectRevert(EquivalentExchangeUManager.TokenDeltaLengthMismatch.selector);
        uManager.execute(_noCalls(), makeAddr("payer"), tokenA, _zeroDeltas(0));

        vm.expectRevert(EquivalentExchangeUManager.TokenDeltaLengthMismatch.selector);
        uManager.execute(_noCalls(), makeAddr("payer"), tokenA, _zeroDeltas(2));
    }

    function test_Execute_RevertWhen_SubsidyPayerIsBoringVault() external {
        uManager.setBasketTokens(_arr(tokenA));

        // boringVault is the mock manager's vault(), captured in setUp. Paying the subsidy from the vault
        // itself would be a self-transfer that leaves the balance unchanged while inflating the accounting, so
        // it must revert. The guard fires before any balance is read, so the codeless dummy token is never
        // called.
        vm.expectRevert(EquivalentExchangeUManager.InvalidSubsidyPayer.selector);
        uManager.execute(_noCalls(), boringVault, tokenA, _zeroDeltas(1));
    }

    // ============================== isBasketToken ==============================

    function test_IsBasketToken_TrueForMember() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB));

        assertTrue(uManager.isBasketToken(tokenA));
        assertTrue(uManager.isBasketToken(tokenB));
    }

    function test_IsBasketToken_FalseForNonMember() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB));

        assertFalse(uManager.isBasketToken(tokenC));
        assertFalse(uManager.isBasketToken(tokenD));
    }

    function test_IsBasketToken_FalseForZeroAddress() external {
        uManager.setBasketTokens(_arr(tokenA));

        // The zero address is never added, so it must never be reported as a basket token.
        assertFalse(uManager.isBasketToken(ERC20(address(0))));
    }

    function test_IsBasketToken_ReflectsRemoval() external {
        uManager.setBasketTokens(_arr(tokenA, tokenB));
        assertTrue(uManager.isBasketToken(tokenA));

        // tokenA is dropped from the new basket and must no longer register as a member.
        uManager.setBasketTokens(_arr(tokenB, tokenC));

        assertFalse(uManager.isBasketToken(tokenA));
        assertTrue(uManager.isBasketToken(tokenB));
        assertTrue(uManager.isBasketToken(tokenC));
    }

    function test_IsBasketToken_FalseWhenBasketEmpty() external view {
        assertFalse(uManager.isBasketToken(tokenA));
    }

    // ============================== read accessors on empty state ==============================

    function test_GetBasketTokens_EmptyByDefault() external view {
        assertEq(uManager.getBasketTokens().length, 0);
        assertFalse(uManager.isBasketToken(tokenA));
    }

}
