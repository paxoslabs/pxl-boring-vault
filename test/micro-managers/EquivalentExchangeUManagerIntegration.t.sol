// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";

import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { EquivalentExchangeUManager } from "src/micro-managers/EquivalentExchangeUManager.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";

import { MockRateProvider } from "./mocks/MockRateProvider.sol";

/// @notice Minimal mintable ERC20 used to stand up baskets at arbitrary decimals.
contract MockERC20 is ERC20 {

    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Non-standard-but-common allowance bump; solmate's ERC20 omits it, so the mock adds it.
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        allowance[msg.sender][spender] += addedValue;
        return true;
    }

}

/// @notice Stand-in swap route: pulls `amountIn` of `tokenIn` from the caller (the vault) and sends
///         `amountOut` of `tokenOut` to `recipient`. Setting amountOut < amountIn simulates slippage.
contract MockSwap {

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient) external {
        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        ERC20(tokenOut).transfer(recipient, amountOut);
    }

}

/// @notice Decoder/sanitizer that recognizes the basket-token approve (from the base) plus the mock
///         swap route, extracting the address arguments the merkle tree gates on.
contract MockDecoderAndSanitizer is BaseDecoderAndSanitizer {

    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256,
        uint256,
        address recipient
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(tokenIn, tokenOut, recipient);
    }

    function increaseAllowance(address spender, uint256) external pure returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(spender);
    }

}

/// @notice End-to-end tests for EquivalentExchangeUManager.execute against a real BoringVault +
///         ManagerWithMerkleVerification + merkle-gated decoder. No mainnet fork required.
contract EquivalentExchangeUManagerIntegrationTest is Test {

    // Mirror of the contract's event for vm.expectEmit.
    event Executed(
        address indexed caller,
        ERC20 indexed subsidyToken,
        uint256 totalBeforeNormalized,
        uint256 totalAfterNormalized,
        uint256 subsidyAmount,
        uint256 subsidyAmountNormalized
    );

    uint8 internal constant MANAGER_ROLE = 1;
    uint8 internal constant STRATEGIST_ROLE = 2;

    BoringVault internal boringVault;
    ManagerWithMerkleVerification internal manager;
    RolesAuthority internal rolesAuthority;
    EquivalentExchangeUManager internal uManager;
    address internal rawDataDecoderAndSanitizer;
    MockSwap internal mockSwap;

    MockERC20 internal usdc; // 6 decimals
    MockERC20 internal dai; //  18 decimals
    MockERC20 internal gold; // 8 decimals, oracle-priced (non-USD)

    MockRateProvider internal goldOracle; // USD per whole gold token, 18-dec (1e18 == $1.00)

    /// @notice Gold oracle price used across the oracle tests: $2000 per whole token.
    uint256 internal constant GOLD_USD_PRICE = 2000e18;

    // Production basket (mirrors DeployBoringVaultAndManager): USDC + USDG (1:1 USD, 6-dec) and PAXG
    // (18-dec, oracle-priced in USD through an 8-dec Chainlink-style feed).
    MockERC20 internal usdg; // 6 decimals, 1:1 USD
    MockERC20 internal paxg; // 18 decimals, oracle-priced
    MockRateProvider internal paxgUsdOracle; // USD per whole PAXG, 8-dec (Chainlink-style)

    /// @notice PAXG oracle price used across the production-basket tests: $4000 per whole token, 8-dec.
    uint256 internal constant PAXG_USD_PRICE = 4000e8;

    address internal payer = makeAddr("subsidyPayer");

    function setUp() external {
        boringVault = new BoringVault(address(this), "Boring Vault", "BV", 18);
        manager = new ManagerWithMerkleVerification(address(this), address(boringVault), address(0));
        uManager = new EquivalentExchangeUManager(address(this), address(manager));
        rawDataDecoderAndSanitizer = address(new MockDecoderAndSanitizer(address(boringVault)));
        mockSwap = new MockSwap();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        gold = new MockERC20("Gold", "GLD", 8);
        goldOracle = new MockRateProvider(GOLD_USD_PRICE);

        // Wire up auth: the manager may manage the vault, and the uManager may drive the manager.
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
        rolesAuthority.setUserRole(address(uManager), STRATEGIST_ROLE, true);

        // Basket = { USDC, DAI }, both treated 1:1 with USD after decimal normalization (no oracle).
        EquivalentExchangeUManager.BasketToken[] memory basket = new EquivalentExchangeUManager.BasketToken[](2);
        basket[0] = EquivalentExchangeUManager.BasketToken({
            token: usdc,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        basket[1] = EquivalentExchangeUManager.BasketToken({
            token: dai,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        uManager.setBasketTokens(basket);

        // Deltas bind to basket tokens by position, so every test's bounds are written against this exact
        // order. Pin it here: if the basket ever changes, these assertions fail loudly rather than letting
        // the suite silently apply USDC bounds to DAI and vice versa.
        EquivalentExchangeUManager.BasketToken[] memory storedBasket = uManager.getBasketTokens();
        assertEq(storedBasket.length, 2, "basket size");
        assertEq(address(storedBasket[0].token), address(usdc), "basket[0] is USDC");
        assertEq(address(storedBasket[1].token), address(dai), "basket[1] is DAI");

        // Seed the vault with USDC to spend, and the swap route with DAI liquidity to hand back.
        usdc.mint(address(boringVault), 1000e6);
        dai.mint(address(mockSwap), 1_000_000e18);

        // Fund the subsidy payer and approve the uManager to pull DAI subsidy.
        dai.mint(payer, 1000e18);
        vm.prank(payer);
        dai.approve(address(uManager), type(uint256).max);

        // Seed the swap route with gold liquidity and fund the payer with gold for oracle-subsidy tests.
        // The default basket excludes gold; the oracle tests reconfigure the basket to include it.
        gold.mint(address(mockSwap), 1_000_000e8);
        gold.mint(payer, 1000e8);
        vm.prank(payer);
        gold.approve(address(uManager), type(uint256).max);

        // Production basket tokens. Created here but NOT added to the default basket; the production tests
        // call _setProductionBasket(). Seed swap-route liquidity and fund the payer for subsidy. USDG/PAXG
        // are untouched by every other test, so this is purely additive.
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        paxg = new MockERC20("Pax Gold", "PAXG", 18);
        paxgUsdOracle = new MockRateProvider(PAXG_USD_PRICE);

        usdg.mint(address(mockSwap), 1_000_000e6);
        paxg.mint(address(mockSwap), 1_000_000e18);
        usdg.mint(payer, 1_000_000e6);
        paxg.mint(payer, 1000e18);
        vm.startPrank(payer);
        usdg.approve(address(uManager), type(uint256).max);
        paxg.approve(address(uManager), type(uint256).max);
        vm.stopPrank();
    }

    // ============================== happy paths ==============================

    function test_Execute_ValueNeutralSwap_NoSubsidy() external {
        // Approve exactly what the swap consumes, and receive an equal-normalized amount of DAI back.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), dai, 1000e18, 1000e18, 0, 0);

        uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());

        assertEq(usdc.balanceOf(address(boringVault)), 0, "vault USDC spent");
        assertEq(dai.balanceOf(address(boringVault)), 1000e18, "vault received DAI");
        assertEq(usdc.allowance(address(boringVault), address(mockSwap)), 0, "no dangling approval");
        assertEq(dai.balanceOf(payer), 1000e18, "payer untouched when no subsidy needed");
    }

    function test_Execute_SlippageCoveredBySubsidy() external {
        // Swap returns 1 DAI less than value-neutral -> 1e18 normalized shortfall, covered by the payer.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, 999e18);

        vm.expectEmit(true, true, true, true, address(uManager));
        // DAI is 18-decimal, so the native and normalized subsidy fields coincide here.
        emit Executed(address(this), dai, 1000e18, 1000e18, 1e18, 1e18);

        uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());

        assertEq(dai.balanceOf(address(boringVault)), 1000e18, "vault made whole (999 swap + 1 subsidy)");
        assertEq(dai.balanceOf(payer), 999e18, "payer covered exactly the 1 DAI shortfall");
    }

    function test_Execute_SubsidyRoundsUpAndIsUncapped() external {
        // Subsidize with a 6-decimal token so the subsidy conversion's round-up is observable. Nothing caps
        // the subsidy beyond the shortfall it covers, so the rounded-up over-pull is accepted, not rejected.
        usdc.mint(payer, 1000e6);
        vm.prank(payer);
        usdc.approve(address(uManager), type(uint256).max);

        // Engineer a shortfall of exactly 1e12 + 1 normalized units. It is NOT a multiple of the USDC
        // 1e12 scale, so the subsidy conversion rounds it up from ~1 native unit to 2 (= 2e12 normalized).
        uint256 shortfall = 1e12 + 1;
        uint256 amountOut = 1000e18 - shortfall; // vault ends 1e12+1 short of value-neutral
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, amountOut);

        // The batch spends all 1000e6 USDC (a 1000e6 decrease) and receives DAI; the subsidy is pulled in
        // USDC AFTER the snapshot, so it is not counted against USDC's batch bound.
        int256[] memory allowableTokenDelta = _allowableTokenDeltas(-1000e6, type(int256).min);

        // The only case where the event's two subsidy fields diverge: 2 native USDC units against 2e12
        // normalized. Every other emit assertion subsidizes in 18-decimal DAI, where the two coincide and
        // a mix-up would go unnoticed. The rounded-up over-pull lands in totalAfterNormalized, which ends
        // 1e12 - 1 above totalBeforeNormalized rather than exactly equal to it.
        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), usdc, 1000e18, 1000e18 + 1e12 - 1, 2, 2e12);

        uManager.execute(calls, payer, usdc, allowableTokenDelta);

        // 2 native USDC units (2e12 normalized) were pulled to cover a 1e12+1 shortfall: rounding up.
        assertEq(usdc.balanceOf(address(boringVault)), 2, "vault received 2 native USDC subsidy units");
        assertEq(usdc.balanceOf(payer), 1000e6 - 2, "payer over-pulled by rounding, uncapped");
    }

    // ============================== execute return value ==============================
    // The return reports the subsidy in the subsidy token's NATIVE units, which is what actually left the
    // payer's wallet. The event's subsidyNormalized field reports the same transfer in 18-decimal units;
    // the two agree only for 18-decimal subsidy tokens, so the 6-decimal case below pins them apart.

    function test_Execute_ReturnsZeroWhenNoSubsidyNeeded() external {
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18);

        uint256 subsidyAmount = uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());

        assertEq(subsidyAmount, 0, "value-neutral swap pulls no subsidy");
        assertEq(dai.balanceOf(payer), 1000e18, "payer untouched, matching the zero return");
    }

    function test_Execute_ReturnsSubsidyPulledFromPayer() external {
        // Swap returns 1 DAI less than value-neutral; the payer covers exactly that.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, 999e18);

        uint256 payerBefore = dai.balanceOf(payer);
        uint256 subsidyAmount = uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());

        assertEq(subsidyAmount, 1e18, "return reports the 1 DAI subsidy");
        // The return must equal the payer's realized spend, not merely the shortfall it was derived from.
        assertEq(payerBefore - dai.balanceOf(payer), subsidyAmount, "return matches payer's actual spend");
    }

    function test_Execute_ReturnsNativeUnitsInclusiveOfRoundUp() external {
        // Mirrors test_Execute_SubsidyRoundsUpAndIsUncapped, asserting on the return instead of balances.
        // This is the case that distinguishes the return from the event: 2 native USDC units are pulled to
        // cover a 1e12+1 normalized shortfall, so the return is 2 while subsidyNormalized would be 2e12.
        usdc.mint(payer, 1000e6);
        vm.prank(payer);
        usdc.approve(address(uManager), type(uint256).max);

        uint256 shortfall = 1e12 + 1;
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18 - shortfall);
        int256[] memory allowableTokenDelta = _allowableTokenDeltas(-1000e6, type(int256).min);

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 subsidyAmount = uManager.execute(calls, payer, usdc, allowableTokenDelta);

        // Native units, rounded up from ~1 unit to 2 -- NOT the 2e12 normalized figure.
        assertEq(subsidyAmount, 2, "return is native USDC units, inclusive of the round-up");
        assertEq(payerBefore - usdc.balanceOf(payer), subsidyAmount, "return matches payer's actual spend");
    }

    // ============================== subsidy guards ==============================

    function test_Execute_RevertWhen_SubsidyAllowanceInsufficient() external {
        // Payer revokes approval, so the shortfall cannot be covered.
        vm.prank(payer);
        dai.approve(address(uManager), 0);

        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, 999e18);

        vm.expectRevert(EquivalentExchangeUManager.InsufficientSubsidy.selector);
        uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());
    }

    function test_Execute_RevertWhen_SubsidyBalanceInsufficient() external {
        // Payer keeps the (max) approval but has no DAI, so available = min(balance, allowance) = 0.
        // Read the balance before pranking; otherwise the balanceOf call would consume the prank.
        uint256 payerBalance = dai.balanceOf(payer);
        vm.prank(payer);
        dai.transfer(address(0xdead), payerBalance);

        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, 999e18);

        vm.expectRevert(EquivalentExchangeUManager.InsufficientSubsidy.selector);
        uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());
    }

    // ============================== per-token delta bounds ==============================

    function test_Execute_TightDeltaBounds_Passes() external {
        // Value-neutral swap: USDC falls by exactly 1000e6, DAI rises by exactly 1000e18. Bounds set to the
        // exact inclusive floors -- USDC's max loss and DAI's min gain -- must still pass.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18);

        int256[] memory allowableTokenDelta = _allowableTokenDeltas(-1000e6, 1000e18);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), dai, 1000e18, 1000e18, 0, 0);

        uManager.execute(calls, payer, dai, allowableTokenDelta);

        assertEq(usdc.balanceOf(address(boringVault)), 0, "vault USDC spent");
        assertEq(dai.balanceOf(address(boringVault)), 1000e18, "vault received DAI");
    }

    function test_Execute_UnmovedTokenPassesZeroBounds() external {
        // Swap consumes the USDC but returns no DAI, so one basket token moves and the other does not.
        // DAI's bound is zero (must not decrease): an unmoved token passes at that inclusive floor, and
        // must not inherit the moving token's delta.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, 0);

        int256[] memory allowableTokenDelta = _allowableTokenDeltas(-1000e6, 0);

        // The whole 1000e18 of value is recovered from the payer. The subsidy lands in DAI after the
        // bounds are checked, so it does not count against DAI's zero floor.
        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), dai, 1000e18, 1000e18, 1000e18, 1000e18);

        uManager.execute(calls, payer, dai, allowableTokenDelta);

        assertEq(usdc.balanceOf(address(boringVault)), 0, "vault USDC spent");
        assertEq(dai.balanceOf(address(boringVault)), 1000e18, "vault made whole entirely by subsidy");
        assertEq(dai.balanceOf(payer), 0, "payer covered the full shortfall");
    }

    function test_Execute_RevertWhen_LossExceedsMaxLoss() external {
        // USDC drops by 1000e6, but the caller only tolerates a 999e6 loss (a -999e6 floor).
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18);

        int256[] memory allowableTokenDelta = _allowableTokenDeltas(-999e6, type(int256).min);

        // USDC falls 1000e6 -> 0: balanceBefore 1000e6, balanceAfter 0, delta -1000e6, allowed -999e6.
        vm.expectRevert(
            abi.encodeWithSelector(
                EquivalentExchangeUManager.TokenDeltaViolation.selector,
                address(usdc),
                uint256(1000e6),
                uint256(0),
                int256(-1000e6),
                int256(-999e6)
            )
        );
        uManager.execute(calls, payer, dai, allowableTokenDelta);
    }

    function test_Execute_RevertWhen_GainBelowMinGain() external {
        // DAI rises by 1000e18, but the caller requires a gain of at least 1001e18 (a +1001e18 floor).
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18);

        int256[] memory allowableTokenDelta = _allowableTokenDeltas(type(int256).min, 1001e18);

        // DAI rises 0 -> 1000e18: balanceBefore 0, balanceAfter 1000e18, delta 1000e18, allowed 1001e18.
        vm.expectRevert(
            abi.encodeWithSelector(
                EquivalentExchangeUManager.TokenDeltaViolation.selector,
                address(dai),
                uint256(0),
                uint256(1000e18),
                int256(1000e18),
                int256(1001e18)
            )
        );
        uManager.execute(calls, payer, dai, allowableTokenDelta);
    }

    // ============================== dangling approval ==============================

    function test_Execute_RevertWhen_DanglingApprovalLeft() external {
        // Approve more USDC than the swap consumes, leaving a non-zero allowance to the swap route.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(2000e6, 1000e6, 1000e18);

        vm.expectRevert(EquivalentExchangeUManager.DanglingApproval.selector);
        uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());
    }

    function test_Execute_ApprovalResetToZero_Passes() external {
        // Approve the swap, then explicitly reset the same allowance to zero in the same batch.
        (bytes32[] memory approveProof, bytes32[] memory increaseProof) = _setApprovalTestRoot();

        EquivalentExchangeUManager.ManageCalls memory calls = _batch(
            _actions(
                _mc(
                    approveProof,
                    address(usdc),
                    abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), 500e6)
                ),
                _mc(approveProof, address(usdc), abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), 0))
            )
        );
        increaseProof; // unused in this case

        // No tokens move, so the value invariant holds and the reset clears the allowance: no revert.
        uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());
        assertEq(usdc.allowance(address(boringVault), address(mockSwap)), 0, "allowance fully reset");
    }

    function test_Execute_RevertWhen_DanglingApprovalViaIncreaseAllowance() external {
        // A non-zero increaseAllowance that is never reset must be caught as a dangling approval.
        (, bytes32[] memory increaseProof) = _setApprovalTestRoot();

        EquivalentExchangeUManager.ManageCalls memory calls = _batch(
            _actions(
                _mc(
                    increaseProof,
                    address(usdc),
                    abi.encodeWithSignature("increaseAllowance(address,uint256)", address(mockSwap), 500e6)
                )
            )
        );

        vm.expectRevert(EquivalentExchangeUManager.DanglingApproval.selector);
        uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());
    }

    function test_Execute_IncreaseAllowanceResetToZero_Passes() external {
        // increaseAllowance then reset to zero via approve(spender, 0) in the same batch.
        (bytes32[] memory approveProof, bytes32[] memory increaseProof) = _setApprovalTestRoot();

        EquivalentExchangeUManager.ManageCalls memory calls = _batch(
            _actions(
                _mc(
                    increaseProof,
                    address(usdc),
                    abi.encodeWithSignature("increaseAllowance(address,uint256)", address(mockSwap), 500e6)
                ),
                _mc(approveProof, address(usdc), abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), 0))
            )
        );

        uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());
        assertEq(usdc.allowance(address(boringVault), address(mockSwap)), 0, "allowance fully reset");
    }

    function test_Execute_RevertWhen_DanglingApprovalLeft_NonBasketToken() external {
        // gold is held by the vault but is NOT in the basket {USDC, DAI}. A leftover approval on it is a
        // standing drain vector, so the dangling-approval guard must catch it even though it is not a basket
        // token. No basket balance moves, so the value invariant holds and this guard is the only thing that
        // can revert.
        gold.mint(address(boringVault), 1000e8);

        bytes32[] memory approveProof = _setNonBasketApprovalRoot();

        EquivalentExchangeUManager.ManageCalls memory calls = _batch(
            _actions(
                _mc(
                    approveProof,
                    address(gold),
                    abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), 1000e8)
                )
            )
        );

        vm.expectRevert(EquivalentExchangeUManager.DanglingApproval.selector);
        uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());
    }

    function test_Execute_NonBasketApprovalResetToZero_Passes() external {
        // The widened guard must not reject a legitimate non-basket approve+reset. The gold approve leaf gates
        // only the spender, so one proof serves both the nonzero set and the reset-to-zero.
        gold.mint(address(boringVault), 1000e8);

        bytes32[] memory approveProof = _setNonBasketApprovalRoot();

        EquivalentExchangeUManager.ManageCalls memory calls = _batch(
            _actions(
                _mc(
                    approveProof,
                    address(gold),
                    abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), 1000e8)
                ),
                _mc(approveProof, address(gold), abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), 0))
            )
        );

        uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());
        assertEq(gold.allowance(address(boringVault), address(mockSwap)), 0, "non-basket allowance fully reset");
    }

    // ============================== merkle gating ==============================

    function test_Execute_RevertWhen_ProofInvalid() external {
        // Build a legitimate route, then tamper with the swap target so its proof no longer verifies.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapCalls(1000e6, 1000e6, 1000e18);
        calls.targets[1] = address(dai); // not the gated swap target

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerWithMerkleVerification.ManagerWithMerkleVerification__FailedToVerifyManageProof.selector,
                calls.targets[1],
                calls.targetData[1],
                calls.values[1]
            )
        );
        uManager.execute(calls, payer, dai, _wideAllowableTokenDeltas());
    }

    // ============================== oracle-priced tokens ==============================
    // These tests reconfigure the basket to { USDC (1:1 USD), GLD (oracle-priced at $2000) } so the value
    // invariant and subsidy conversion must go through the gold oracle. GLD is 8-decimal, so its
    // normalization interacts with the oracle price. 1000e6 USDC == $1000; $1000 of gold == 0.5 GLD == 5e7.

    function test_Execute_OraclePricedSwap_ValueNeutral_NoSubsidy() external {
        _setUsdcGoldBasket();

        // Swap $1000 of USDC for exactly $1000 of gold (5e7 GLD at $2000/token): value-neutral, no subsidy.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapUsdcForGold(1000e6, 1000e6, 5e7);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), usdc, 1000e18, 1000e18, 0, 0);

        uint256 subsidyAmount = uManager.execute(calls, payer, usdc, _wideUsdcGoldDeltas());

        assertEq(subsidyAmount, 0, "value-neutral oracle swap pulls no subsidy");
        assertEq(usdc.balanceOf(address(boringVault)), 0, "vault USDC spent");
        assertEq(gold.balanceOf(address(boringVault)), 5e7, "vault received gold");
    }

    function test_Execute_OraclePricedSwap_EightDecimalOracle_ValueNeutral() external {
        // A Chainlink-style oracle reports $2000 as an 8-decimal number (2000e8). Declaring rateDecimals = 8
        // must value gold identically to the 18-decimal oracle: the contract rescales 8 -> 18 internally.
        MockRateProvider gold8Oracle = new MockRateProvider(2000e8);

        EquivalentExchangeUManager.BasketToken[] memory basket = new EquivalentExchangeUManager.BasketToken[](2);
        basket[0] = EquivalentExchangeUManager.BasketToken({
            token: usdc,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        basket[1] = EquivalentExchangeUManager.BasketToken({
            token: gold,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: false, rateProvider: gold8Oracle, rateDecimals: 8
            })
        });
        uManager.setBasketTokens(basket);

        // Swap $1000 USDC for exactly $1000 of gold (5e7 GLD at $2000/token): value-neutral, no subsidy --
        // the same outcome as the 18-decimal oracle case.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapUsdcForGold(1000e6, 1000e6, 5e7);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), usdc, 1000e18, 1000e18, 0, 0);

        uint256 subsidyAmount = uManager.execute(calls, payer, usdc, _wideUsdcGoldDeltas());

        assertEq(subsidyAmount, 0, "value-neutral 8-dec oracle swap pulls no subsidy");
        assertEq(gold.balanceOf(address(boringVault)), 5e7, "vault received gold valued via the 8-dec oracle");
    }

    function test_Execute_MixedBasket_HeterogeneousRateDecimals() external {
        // One valuation pass over three tokens that differ in BOTH token decimals and oracle config:
        //   - USDC: 1:1, no oracle, 6-dec token
        //   - DAI:  oracle @ 18-dec rate, 18-dec token, priced at $1
        //   - GLD:  oracle @ 8-dec rate,  8-dec token,  priced at $2000
        // Each token must be valued from its own rateDecimals; a bug that reused one token's decimals for
        // another would throw off the aggregate, which this pins via the Executed event.
        MockRateProvider daiOracle = new MockRateProvider(1e18); // $1, 18-dec
        MockRateProvider gold8Oracle = new MockRateProvider(2000e8); // $2000, 8-dec

        EquivalentExchangeUManager.BasketToken[] memory basket = new EquivalentExchangeUManager.BasketToken[](3);
        basket[0] = EquivalentExchangeUManager.BasketToken({
            token: usdc,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        basket[1] = EquivalentExchangeUManager.BasketToken({
            token: dai,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: false, rateProvider: daiOracle, rateDecimals: 18
            })
        });
        basket[2] = EquivalentExchangeUManager.BasketToken({
            token: gold,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: false, rateProvider: gold8Oracle, rateDecimals: 8
            })
        });
        uManager.setBasketTokens(basket);

        // Vault already holds 1000e6 USDC from setUp; add 500 DAI and 1 GLD.
        dai.mint(address(boringVault), 500e18);
        gold.mint(address(boringVault), 1e8);

        // Expected value = $1000 (USDC) + $500 (DAI) + $2000 (GLD) = $3500, each token via its own decimals.
        int256[] memory deltas = new int256[](3);
        deltas[0] = type(int256).min;
        deltas[1] = type(int256).min;
        deltas[2] = type(int256).min;

        // Empty batch: a no-op that changes no balances, so value is neutral and no subsidy is pulled. The
        // point is the valuation of the heterogeneous basket, reported in the totals below.
        EquivalentExchangeUManager.ManageCalls memory calls;

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), usdc, 3500e18, 3500e18, 0, 0);

        uint256 subsidyAmount = uManager.execute(calls, payer, usdc, deltas);
        assertEq(subsidyAmount, 0, "value-neutral no-op pulls no subsidy");
    }

    function test_Execute_OraclePricedSwap_ShortfallCoveredByUsdSubsidy() external {
        _setUsdcGoldBasket();

        // Fund the payer with USDC to subsidize with (payer is only seeded with DAI/GLD in setUp).
        usdc.mint(payer, 1000e6);
        vm.prank(payer);
        usdc.approve(address(uManager), type(uint256).max);

        // Swap $1000 USDC for only $999 of gold (4.995e7 GLD): a $1 shortfall, priced through the oracle
        // and covered by 1 native USDC unit (1e6).
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapUsdcForGold(1000e6, 1000e6, 4.995e7);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), usdc, 1000e18, 1000e18, 1e6, 1e18);

        uManager.execute(calls, payer, usdc, _wideUsdcGoldDeltas());

        assertEq(gold.balanceOf(address(boringVault)), 4.995e7, "vault received the $999 of gold");
        assertEq(usdc.balanceOf(address(boringVault)), 1e6, "vault topped up with $1 of USDC subsidy");
    }

    function test_Execute_ShortfallCoveredByOracleSubsidy() external {
        _setUsdcGoldBasket();

        // Swap $1000 of USDC for no gold at all: the entire $1000 must be recovered from the payer, paid in
        // the oracle-priced gold token. $1000 / $2000 == 0.5 GLD == 5e7 native units.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapUsdcForGold(1000e6, 1000e6, 0);

        uint256 payerGoldBefore = gold.balanceOf(payer);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), gold, 1000e18, 1000e18, 5e7, 1000e18);

        uint256 subsidyAmount = uManager.execute(calls, payer, gold, _wideUsdcGoldDeltas());

        // subsidyAmount is native GLD units (5e7), NOT the $1000 normalized figure.
        assertEq(subsidyAmount, 5e7, "subsidy is 0.5 GLD in native units");
        assertEq(gold.balanceOf(address(boringVault)), 5e7, "vault made whole in gold");
        assertEq(payerGoldBefore - gold.balanceOf(payer), 5e7, "payer spent exactly the converted gold");
    }

    function test_Execute_DirtyOracleMappingNotUsedForUsdSubsidyToken() external {
        // First make gold oracle-priced, populating its tokenOracles entry.
        _setUsdcGoldBasket();

        // Then reconfigure gold as a 1:1 USD asset. Its tokenOracles entry is intentionally left "dirty"
        // (not deleted), but its oracleFlags bit is now clear, so gold must be priced 1:1 in USD
        // everywhere -- including when it is the subsidy token, which is what this test pins.
        EquivalentExchangeUManager.BasketToken[] memory basket = new EquivalentExchangeUManager.BasketToken[](2);
        basket[0] = EquivalentExchangeUManager.BasketToken({
            token: usdc,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        basket[1] = EquivalentExchangeUManager.BasketToken({
            token: gold,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        uManager.setBasketTokens(basket);

        // Swap $1000 USDC for only $999 of gold priced 1:1 (999e8 GLD): a $1 shortfall subsidized in gold.
        // As a USD asset $1 == 1 whole GLD (1e8); if the stale $2000 oracle were wrongly used it would be
        // ~5e4 instead.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapUsdcForGold(1000e6, 1000e6, 999e8);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), gold, 1000e18, 1000e18, 1e8, 1e18);

        uint256 subsidyAmount = uManager.execute(calls, payer, gold, _wideUsdcGoldDeltas());

        assertEq(subsidyAmount, 1e8, "gold subsidized 1:1 as USD, not via the stale oracle");
    }

    function test_Execute_RevertWhen_OracleRateZero() external {
        _setUsdcGoldBasket();

        // A zero oracle rate cannot value gold, so execute must revert rather than mis-price the basket.
        goldOracle.setRate(0);

        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapUsdcForGold(1000e6, 1000e6, 5e7);

        vm.expectRevert(abi.encodeWithSelector(EquivalentExchangeUManager.InvalidRate.selector, address(gold)));
        uManager.execute(calls, payer, usdc, _wideUsdcGoldDeltas());
    }

    function test_Execute_RevertWhen_RateDecimalsExceedMax() external {
        // rateDecimals + tokenDecimals > 2 * NORMALIZED_DECIMALS (36) is rejected up front, because _unitRate
        // would otherwise divide and lose precision. Gold is 8-decimal; rateDecimals = 36 makes the sum
        // 44 > 36. baseRate here (1) would floor all the way to zero, but the guard fires on the decimals
        // alone, before the rate is even computed.
        MockRateProvider oracle = new MockRateProvider(1);
        EquivalentExchangeUManager.BasketToken[] memory basket = new EquivalentExchangeUManager.BasketToken[](2);
        basket[0] = EquivalentExchangeUManager.BasketToken({
            token: usdc,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        basket[1] = EquivalentExchangeUManager.BasketToken({
            token: gold,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: false, rateProvider: oracle, rateDecimals: 36
            })
        });
        uManager.setBasketTokens(basket);

        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapUsdcForGold(1000e6, 1000e6, 5e7);

        vm.expectRevert(abi.encodeWithSelector(EquivalentExchangeUManager.InvalidRate.selector, address(gold)));
        uManager.execute(calls, payer, usdc, _wideUsdcGoldDeltas());
    }

    function test_Execute_RevertWhen_RateWouldFloorButNonZero() external {
        // The case the old rate == 0 guard missed: a large baseRate whose folded unit rate floors to a
        // NON-zero value (lossy, and not conservative across a mixed basket). Gold is 8-decimal; rateDecimals
        // = 30 makes the sum 38 > 36, so _unitRate would divide by 10**2 -- baseRate 2000e30 would floor to
        // 20e30, nonzero. The decimals guard rejects it regardless of the rate's magnitude.
        MockRateProvider oracle = new MockRateProvider(2000e30);
        EquivalentExchangeUManager.BasketToken[] memory basket = new EquivalentExchangeUManager.BasketToken[](2);
        basket[0] = EquivalentExchangeUManager.BasketToken({
            token: usdc,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        basket[1] = EquivalentExchangeUManager.BasketToken({
            token: gold,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: false, rateProvider: oracle, rateDecimals: 30
            })
        });
        uManager.setBasketTokens(basket);

        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapUsdcForGold(1000e6, 1000e6, 5e7);

        vm.expectRevert(abi.encodeWithSelector(EquivalentExchangeUManager.InvalidRate.selector, address(gold)));
        uManager.execute(calls, payer, usdc, _wideUsdcGoldDeltas());
    }

    // ==================== production basket (USDC + USDG + PAXG), mirrors deploy ====================
    // Two 1:1 USD stablecoins (6-dec) plus PAXG (18-dec) priced through an 8-dec Chainlink-style USD oracle.
    // Confirms every token is valued correctly in USD and that stablecoin<->PAXG transfers preserve value or
    // pull correctly-priced subsidy. PAXG's 18 decimals exercise the rate/decimal folding differently from
    // the 8-decimal gold used above. Math at $4000/PAXG: 1 PAXG == $4000; 1e6 USDC == 1e6 USDG == $1.

    function test_Paxg_ValuesFullBasketInUsd() external {
        _setProductionBasket();

        // Vault: 1000 USDC (from setUp) + 1000 USDG + 1 PAXG => $1000 + $1000 + $4000 = $6000.
        usdg.mint(address(boringVault), 1000e6);
        paxg.mint(address(boringVault), 1e18);

        // Empty batch: pure valuation, no movement, no subsidy.
        EquivalentExchangeUManager.ManageCalls memory calls;

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), usdc, 6000e18, 6000e18, 0, 0);

        uint256 subsidyAmount = uManager.execute(calls, payer, usdc, _wideProductionDeltas());
        assertEq(subsidyAmount, 0, "value-neutral valuation pulls no subsidy");
    }

    function test_Paxg_StableToPaxg_ValueNeutral_NoSubsidy() external {
        _setProductionBasket();

        // Vault holds 1000e6 USDC ($1000). Swap it for $1000 of PAXG == 0.25 PAXG (25e16) at $4000.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapTokens(usdc, paxg, 1000e6, 1000e6, 25e16);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), usdc, 1000e18, 1000e18, 0, 0);

        uint256 subsidyAmount = uManager.execute(calls, payer, usdc, _wideProductionDeltas());

        assertEq(subsidyAmount, 0, "value-neutral USDC->PAXG swap pulls no subsidy");
        assertEq(usdc.balanceOf(address(boringVault)), 0, "vault USDC spent");
        assertEq(paxg.balanceOf(address(boringVault)), 25e16, "vault received 0.25 PAXG");
    }

    function test_Paxg_PaxgToStable_ValueNeutral_NoSubsidy() external {
        _setProductionBasket();

        // Vault also holds 1000e6 USDC ($1000) from setUp, unchanged across the swap. Give it 1 PAXG ($4000)
        // and swap that for $4000 of USDG (4000e6). before: $1000 + $0 + $4000; after: $1000 + $4000 + $0.
        paxg.mint(address(boringVault), 1e18);

        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapTokens(paxg, usdg, 1e18, 1e18, 4000e6);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), usdg, 5000e18, 5000e18, 0, 0);

        uint256 subsidyAmount = uManager.execute(calls, payer, usdg, _wideProductionDeltas());

        assertEq(subsidyAmount, 0, "value-neutral PAXG->USDG swap pulls no subsidy");
        assertEq(paxg.balanceOf(address(boringVault)), 0, "vault PAXG spent");
        assertEq(usdg.balanceOf(address(boringVault)), 4000e6, "vault received 4000 USDG");
    }

    function test_Paxg_StableToStable_OneForOne_NoSubsidy() external {
        _setProductionBasket();

        // 1000 USDC -> 1000 USDG: both 1:1 USD, value-neutral, no oracle involved.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapTokens(usdc, usdg, 1000e6, 1000e6, 1000e6);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), usdc, 1000e18, 1000e18, 0, 0);

        uint256 subsidyAmount = uManager.execute(calls, payer, usdc, _wideProductionDeltas());

        assertEq(subsidyAmount, 0, "1:1 stablecoin swap pulls no subsidy");
        assertEq(usdg.balanceOf(address(boringVault)), 1000e6, "vault received USDG");
    }

    function test_Paxg_Shortfall_CoveredByPaxgSubsidy() external {
        _setProductionBasket();

        // Give the vault $4000 of USDC total: 1000 (setUp) + 3000 more.
        usdc.mint(address(boringVault), 3000e6);

        // Swap $4000 USDC for only 0.999 PAXG ($3996): a $4 shortfall, subsidized in PAXG through the same
        // oracle. $4 / $4000 == 0.001 PAXG == 1e15 native units.
        EquivalentExchangeUManager.ManageCalls memory calls = _approveAndSwapTokens(usdc, paxg, 4000e6, 4000e6, 999e15);

        uint256 payerPaxgBefore = paxg.balanceOf(payer);

        vm.expectEmit(true, true, true, true, address(uManager));
        emit Executed(address(this), paxg, 4000e18, 4000e18, 1e15, 4e18);

        uint256 subsidyAmount = uManager.execute(calls, payer, paxg, _wideProductionDeltas());

        assertEq(subsidyAmount, 1e15, "subsidy is 0.001 PAXG in native units");
        assertEq(paxg.balanceOf(address(boringVault)), 999e15 + 1e15, "vault made whole: 0.999 + 0.001 PAXG");
        assertEq(payerPaxgBefore - paxg.balanceOf(payer), 1e15, "payer spent exactly the converted PAXG");
    }

    // ============================== helpers ==============================

    /// @notice Reconfigures the basket to the deployed layout { USDC (1:1 USD), USDG (1:1 USD), PAXG
    ///         (oracle-priced at PAXG_USD_PRICE, 8-dec) }, matching DeployBoringVaultAndManager.
    function _setProductionBasket() internal {
        EquivalentExchangeUManager.BasketToken[] memory basket = new EquivalentExchangeUManager.BasketToken[](3);
        basket[0] = EquivalentExchangeUManager.BasketToken({
            token: usdc,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        basket[1] = EquivalentExchangeUManager.BasketToken({
            token: usdg,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        basket[2] = EquivalentExchangeUManager.BasketToken({
            token: paxg,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: false, rateProvider: paxgUsdOracle, rateDecimals: 8
            })
        });
        uManager.setBasketTokens(basket);
    }

    /// @notice Wide (non-binding) bounds for the 3-token production basket.
    function _wideProductionDeltas() internal pure returns (int256[] memory d) {
        d = new int256[](3);
        d[0] = type(int256).min;
        d[1] = type(int256).min;
        d[2] = type(int256).min;
    }

    /// @notice Generic approve+swap route for an arbitrary basket pair, gating both leaves under a fresh root.
    function _approveAndSwapTokens(
        ERC20 tokenIn,
        ERC20 tokenOut,
        uint256 approveAmount,
        uint256 amountIn,
        uint256 amountOut
    )
        internal
        returns (EquivalentExchangeUManager.ManageCalls memory)
    {
        ManageLeaf[] memory leafs = new ManageLeaf[](2);

        leafs[0] = ManageLeaf(address(tokenIn), false, "approve(address,uint256)", new address[](1));
        leafs[0].argumentAddresses[0] = address(mockSwap);

        leafs[1] =
            ManageLeaf(address(mockSwap), false, "swap(address,address,uint256,uint256,address)", new address[](3));
        leafs[1].argumentAddresses[0] = address(tokenIn);
        leafs[1].argumentAddresses[1] = address(tokenOut);
        leafs[1].argumentAddresses[2] = address(boringVault);

        bytes32[][] memory tree = _generateMerkleTree(leafs);
        manager.setManageRoot(address(uManager), tree[tree.length - 1][0]);
        bytes32[][] memory proofs = _getProofsUsingTree(leafs, tree);

        return _batch(
            _actions(
                _mc(
                    proofs[0],
                    address(tokenIn),
                    abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), approveAmount)
                ),
                _mc(
                    proofs[1],
                    address(mockSwap),
                    abi.encodeWithSelector(
                        MockSwap.swap.selector,
                        address(tokenIn),
                        address(tokenOut),
                        amountIn,
                        amountOut,
                        address(boringVault)
                    )
                )
            )
        );
    }

    /// @notice Reconfigures the basket to { USDC (1:1 USD), GLD (oracle-priced) }, in that order.
    function _setUsdcGoldBasket() internal {
        EquivalentExchangeUManager.BasketToken[] memory basket = new EquivalentExchangeUManager.BasketToken[](2);
        basket[0] = EquivalentExchangeUManager.BasketToken({
            token: usdc,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: true, rateProvider: IRateProvider(address(0)), rateDecimals: 0
            })
        });
        basket[1] = EquivalentExchangeUManager.BasketToken({
            token: gold,
            config: EquivalentExchangeUManager.RateProviderConfig({
                isPeggedToken: false, rateProvider: goldOracle, rateDecimals: 18
            })
        });
        uManager.setBasketTokens(basket);
    }

    /// @notice Wide bounds for the { USDC, GLD } basket, so oracle tests isolate value/subsidy behavior.
    function _wideUsdcGoldDeltas() internal pure returns (int256[] memory allowableTokenDelta) {
        allowableTokenDelta = new int256[](2);
        allowableTokenDelta[0] = type(int256).min;
        allowableTokenDelta[1] = type(int256).min;
    }

    /// @notice Builds the two-call route (approve USDC -> swap, then swap USDC->GLD to the vault), sets the
    ///         corresponding merkle root, and returns the batch.
    function _approveAndSwapUsdcForGold(
        uint256 approveAmount,
        uint256 amountIn,
        uint256 amountOut
    )
        internal
        returns (EquivalentExchangeUManager.ManageCalls memory)
    {
        ManageLeaf[] memory leafs = new ManageLeaf[](2);

        leafs[0] = ManageLeaf(address(usdc), false, "approve(address,uint256)", new address[](1));
        leafs[0].argumentAddresses[0] = address(mockSwap);

        leafs[1] =
            ManageLeaf(address(mockSwap), false, "swap(address,address,uint256,uint256,address)", new address[](3));
        leafs[1].argumentAddresses[0] = address(usdc);
        leafs[1].argumentAddresses[1] = address(gold);
        leafs[1].argumentAddresses[2] = address(boringVault);

        bytes32[][] memory tree = _generateMerkleTree(leafs);
        manager.setManageRoot(address(uManager), tree[tree.length - 1][0]);
        bytes32[][] memory proofs = _getProofsUsingTree(leafs, tree);

        return _batch(
            _actions(
                _mc(
                    proofs[0],
                    address(usdc),
                    abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), approveAmount)
                ),
                _mc(
                    proofs[1],
                    address(mockSwap),
                    abi.encodeWithSelector(
                        MockSwap.swap.selector, address(usdc), address(gold), amountIn, amountOut, address(boringVault)
                    )
                )
            )
        );
    }

    /// @notice Builds a minimum-signed-delta bound set for the { USDC, DAI } basket.
    /// @dev Bounds attach to basket tokens by position, so `usdc` lands at index 0 and `dai` at index 1.
    ///      setUp asserts the live basket matches that layout. Each entry is the minimum signed change the
    ///      token may undergo: a negative value is a max loss, a positive value a min gain, zero forbids any
    ///      net decrease.
    function _allowableTokenDeltas(int256 usdc, int256 dai)
        internal
        pure
        returns (int256[] memory allowableTokenDelta)
    {
        allowableTokenDelta = new int256[](2);
        allowableTokenDelta[0] = usdc;
        allowableTokenDelta[1] = dai;
    }

    /// @notice Bounds that cannot bind, so tests can isolate other behavior.
    function _wideAllowableTokenDeltas() internal pure returns (int256[] memory) {
        return _allowableTokenDeltas(type(int256).min, type(int256).min);
    }

    /// @notice One action, in the readable per-action shape. `_batch` pivots a list of these into the
    ///         column-oriented layout `execute` takes, so tests can still author calls one at a time.
    struct Action {
        bytes32[] proof;
        address target;
        bytes data;
    }

    /// @notice Wraps calldata into a single merkle-verified action against the shared decoder.
    function _mc(bytes32[] memory proof, address target, bytes memory data) internal pure returns (Action memory) {
        return Action({ proof: proof, target: target, data: data });
    }

    /// @notice Pivots per-action authoring into the parallel arrays `execute` takes. Every action uses the
    ///         shared decoder and sends no ETH.
    function _batch(Action[] memory actions) internal view returns (EquivalentExchangeUManager.ManageCalls memory) {
        uint256 length = actions.length;

        bytes32[][] memory manageProofs = new bytes32[][](length);
        address[] memory decodersAndSanitizers = new address[](length);
        address[] memory targets = new address[](length);
        bytes[] memory targetData = new bytes[](length);

        for (uint256 i; i < length; ++i) {
            manageProofs[i] = actions[i].proof;
            decodersAndSanitizers[i] = rawDataDecoderAndSanitizer;
            targets[i] = actions[i].target;
            targetData[i] = actions[i].data;
        }

        return EquivalentExchangeUManager.ManageCalls({
            manageProofs: manageProofs,
            decodersAndSanitizers: decodersAndSanitizers,
            targets: targets,
            targetData: targetData,
            values: new uint256[](length)
        });
    }

    function _actions(Action memory a0) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = a0;
    }

    function _actions(Action memory a0, Action memory a1) internal pure returns (Action[] memory a) {
        a = new Action[](2);
        a[0] = a0;
        a[1] = a1;
    }

    /// @notice Gates approve(USDC -> swap) and increaseAllowance(USDC -> swap) under one root, returning
    ///         each leaf's proof. Two leaves keep the tree even, as the builder requires.
    function _setApprovalTestRoot() internal returns (bytes32[] memory approveProof, bytes32[] memory increaseProof) {
        ManageLeaf[] memory leafs = new ManageLeaf[](2);

        leafs[0] = ManageLeaf(address(usdc), false, "approve(address,uint256)", new address[](1));
        leafs[0].argumentAddresses[0] = address(mockSwap);

        leafs[1] = ManageLeaf(address(usdc), false, "increaseAllowance(address,uint256)", new address[](1));
        leafs[1].argumentAddresses[0] = address(mockSwap);

        bytes32[][] memory tree = _generateMerkleTree(leafs);
        manager.setManageRoot(address(uManager), tree[tree.length - 1][0]);
        bytes32[][] memory proofs = _getProofsUsingTree(leafs, tree);

        approveProof = proofs[0];
        increaseProof = proofs[1];
    }

    /// @notice Gates approve(GLD -> swap) on the non-basket gold token, returning its proof. A second
    ///         (unused) approve leaf keeps the tree even, as the builder requires.
    function _setNonBasketApprovalRoot() internal returns (bytes32[] memory approveProof) {
        ManageLeaf[] memory leafs = new ManageLeaf[](2);

        leafs[0] = ManageLeaf(address(gold), false, "approve(address,uint256)", new address[](1));
        leafs[0].argumentAddresses[0] = address(mockSwap);

        leafs[1] = ManageLeaf(address(usdc), false, "approve(address,uint256)", new address[](1));
        leafs[1].argumentAddresses[0] = address(mockSwap);

        bytes32[][] memory tree = _generateMerkleTree(leafs);
        manager.setManageRoot(address(uManager), tree[tree.length - 1][0]);
        bytes32[][] memory proofs = _getProofsUsingTree(leafs, tree);

        approveProof = proofs[0];
    }

    /// @notice Builds the two-call route (approve USDC -> swap, then swap USDC->DAI to the vault),
    ///         sets the corresponding merkle root on the manager, and returns the batch.
    function _approveAndSwapCalls(
        uint256 approveAmount,
        uint256 amountIn,
        uint256 amountOut
    )
        internal
        returns (EquivalentExchangeUManager.ManageCalls memory)
    {
        ManageLeaf[] memory leafs = new ManageLeaf[](2);

        leafs[0] = ManageLeaf(address(usdc), false, "approve(address,uint256)", new address[](1));
        leafs[0].argumentAddresses[0] = address(mockSwap);

        leafs[1] =
            ManageLeaf(address(mockSwap), false, "swap(address,address,uint256,uint256,address)", new address[](3));
        leafs[1].argumentAddresses[0] = address(usdc);
        leafs[1].argumentAddresses[1] = address(dai);
        leafs[1].argumentAddresses[2] = address(boringVault);

        bytes32[][] memory tree = _generateMerkleTree(leafs);
        manager.setManageRoot(address(uManager), tree[tree.length - 1][0]);
        bytes32[][] memory proofs = _getProofsUsingTree(leafs, tree);

        return _batch(
            _actions(
                _mc(
                    proofs[0],
                    address(usdc),
                    abi.encodeWithSelector(ERC20.approve.selector, address(mockSwap), approveAmount)
                ),
                _mc(
                    proofs[1],
                    address(mockSwap),
                    abi.encodeWithSelector(
                        MockSwap.swap.selector, address(usdc), address(dai), amountIn, amountOut, address(boringVault)
                    )
                )
            )
        );
    }

    // ---- merkle tree helpers (same construction as the other UManager integration tests) ----

    struct ManageLeaf {
        address target;
        bool canSendValue;
        string signature;
        address[] argumentAddresses;
    }

    function _generateMerkleTree(ManageLeaf[] memory manageLeafs) internal view returns (bytes32[][] memory tree) {
        uint256 leafsLength = manageLeafs.length;
        bytes32[][] memory leafs = new bytes32[][](1);
        leafs[0] = new bytes32[](leafsLength);
        for (uint256 i; i < leafsLength; ++i) {
            bytes4 selector = bytes4(keccak256(abi.encodePacked(manageLeafs[i].signature)));
            bytes memory rawDigest = abi.encodePacked(
                rawDataDecoderAndSanitizer, manageLeafs[i].target, manageLeafs[i].canSendValue, selector
            );
            uint256 argumentAddressesLength = manageLeafs[i].argumentAddresses.length;
            for (uint256 j; j < argumentAddressesLength; ++j) {
                rawDigest = abi.encodePacked(rawDigest, manageLeafs[i].argumentAddresses[j]);
            }
            leafs[0][i] = keccak256(rawDigest);
        }
        tree = _buildTrees(leafs);
    }

    function _getProofsUsingTree(
        ManageLeaf[] memory manageLeafs,
        bytes32[][] memory tree
    )
        internal
        view
        returns (bytes32[][] memory proofs)
    {
        proofs = new bytes32[][](manageLeafs.length);
        for (uint256 i; i < manageLeafs.length; ++i) {
            bytes4 selector = bytes4(keccak256(abi.encodePacked(manageLeafs[i].signature)));
            bytes memory rawDigest = abi.encodePacked(
                rawDataDecoderAndSanitizer, manageLeafs[i].target, manageLeafs[i].canSendValue, selector
            );
            uint256 argumentAddressesLength = manageLeafs[i].argumentAddresses.length;
            for (uint256 j; j < argumentAddressesLength; ++j) {
                rawDigest = abi.encodePacked(rawDigest, manageLeafs[i].argumentAddresses[j]);
            }
            proofs[i] = _generateProof(keccak256(rawDigest), tree);
        }
    }

    function _generateProof(bytes32 leaf, bytes32[][] memory tree) internal pure returns (bytes32[] memory proof) {
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
        uint256 merkleTreeInLength = merkleTreeIn.length;
        merkleTreeOut = new bytes32[][](merkleTreeInLength + 1);
        uint256 layerLength;
        for (uint256 i; i < merkleTreeInLength; ++i) {
            layerLength = merkleTreeIn[i].length;
            merkleTreeOut[i] = new bytes32[](layerLength);
            for (uint256 j; j < layerLength; ++j) {
                merkleTreeOut[i][j] = merkleTreeIn[i][j];
            }
        }

        uint256 nextLayerLength = layerLength % 2 != 0 ? (layerLength + 1) / 2 : layerLength / 2;
        merkleTreeOut[merkleTreeInLength] = new bytes32[](nextLayerLength);
        uint256 count;
        for (uint256 i; i < layerLength; i += 2) {
            merkleTreeOut[merkleTreeInLength][count] =
                _hashPair(merkleTreeIn[merkleTreeInLength - 1][i], merkleTreeIn[merkleTreeInLength - 1][i + 1]);
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
