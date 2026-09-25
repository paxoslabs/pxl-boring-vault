// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";

import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { PaxgXauRateProvider } from "src/oracles/PaxgXauRateProvider.sol";
import { IPriceFeed } from "src/interfaces/IPriceFeed.sol";

import { MockPriceFeed } from "test/mocks/MockPriceFeed.sol";
import { MockToken } from "test/mocks/MockToken.sol";

/**
 * @title PaxgyDynamicFeeModuleIntegrationBase
 * @notice Shared harness for the PAXGy fee module integration tests. Deploys a real BoringVault +
 * Accountant + Teller wired to an 18-decimal PAXG asset, plus a real {PaxgXauRateProvider} backed by
 * mock Chainlink feeds whose PAXG:XAU market price the tests can move at will.
 * @dev The accountant pegs PAXG to the vault base 1:1 (1 share = 1 PAXG) in both directions; the fee
 * modules layer the market-vs-peg correction on top. That split — accountant pegs, module corrects — is
 * the exact production wiring these tests exercise end-to-end. The oracle feeds start at peg (both
 * $3400), so a test that never calls {_setPaxgXauPrice} runs at exactly 1.0.
 */
abstract contract PaxgyDynamicFeeModuleIntegrationBase is Test {

    uint8 internal constant FEED_DECIMALS = 8;
    uint256 internal constant PEG_PRICE = 1e18;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant MAX_STALE = 1 days;
    uint256 internal constant NOW = 1_753_000_000;

    // RolesAuthority role ids. The teller mints (enter) and burns (exit) vault shares.
    uint8 internal constant MINTER_ROLE = 1;
    uint8 internal constant BURNER_ROLE = 2;
    uint8 internal constant QUEUE_ROLE = 8;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal payoutAddress = makeAddr("payout");

    MockPriceFeed internal paxgUsdFeed;
    MockPriceFeed internal xauUsdFeed;
    MockToken internal paxg;
    PaxgXauRateProvider internal oracle;

    BoringVault internal boringVault;
    AccountantWithRateProviders internal accountant;
    TellerWithMultiAssetSupport internal teller;
    RolesAuthority internal rolesAuthority;

    /// @dev Deploys the oracle, the 18-decimal PAXG token, and the vault architecture pegged to PAXG 1:1.
    /// Subclasses call this from setUp, then wire in their consuming contract (depositor or queue).
    function _deployVaultAndOracle() internal {
        vm.warp(NOW);

        paxgUsdFeed = new MockPriceFeed(FEED_DECIMALS, "PAXG / USD", int256(3400e8), NOW);
        xauUsdFeed = new MockPriceFeed(FEED_DECIMALS, "XAU / USD", int256(3400e8), NOW);
        paxg = new MockToken("PAX Gold", "PAXG", 18);

        oracle = new PaxgXauRateProvider(
            "PAXG / USD",
            "XAU / USD",
            ERC20(address(paxg)),
            IPriceFeed(address(paxgUsdFeed)),
            IPriceFeed(address(xauUsdFeed)),
            MAX_STALE
        );

        vm.startPrank(owner);

        boringVault = new BoringVault(owner, "PAXGy", "PAXGy", 18);
        // base = PAXG, starting exchange rate = 1e18: shares and PAXG are 1:1 in the accountant's view.
        accountant = new AccountantWithRateProviders(
            owner, address(boringVault), payoutAddress, uint96(ONE), address(paxg), 1.001e4, 0.999e4, 1, 0, 0
        );
        teller = new TellerWithMultiAssetSupport(owner, address(boringVault), address(accountant));
        rolesAuthority = new RolesAuthority(owner, Authority(address(0)));

        boringVault.setAuthority(rolesAuthority);
        accountant.setAuthority(rolesAuthority);
        teller.setAuthority(rolesAuthority);

        rolesAuthority.setRoleCapability(MINTER_ROLE, address(boringVault), BoringVault.enter.selector, true);
        rolesAuthority.setRoleCapability(BURNER_ROLE, address(boringVault), BoringVault.exit.selector, true);
        rolesAuthority.setUserRole(address(teller), MINTER_ROLE, true);
        rolesAuthority.setUserRole(address(teller), BURNER_ROLE, true);
        rolesAuthority.setPublicCapability(address(teller), TellerWithMultiAssetSupport.deposit.selector, true);

        teller.addDepositAsset(ERC20(address(paxg)));
        teller.addWithdrawAsset(ERC20(address(paxg)));
        // PAXG is the accountant base, so getRateInQuote(PAXG) returns the exchange rate directly; no
        // setRateProviderData call is needed (and the base branch never reads one).

        vm.stopPrank();
    }

    /// @dev Sets the reported PAXG:XAU market price by moving the PAXG/USD feed, holding XAU/USD at $3400.
    /// @param price PAXG:XAU price in 18-decimal fixed point (PEG_PRICE = 1.0). Round multiples of 0.01
    /// map exactly; other values may floor slightly, so read oracle.getRate() back when exactness matters.
    function _setPaxgXauPrice(uint256 price) internal {
        // p = paxgUsd / xauUsd  =>  paxgUsd = p * xauUsd
        paxgUsdFeed.setAnswer(int256(price * uint256(3400e8) / PEG_PRICE));
    }

    /// @dev Mints `amount` PAXG to `to` and deposits it through the teller, minting `amount` shares 1:1
    /// and funding the vault with `amount` PAXG. Returns the shares minted.
    function _depositForShares(address to, uint256 amount) internal returns (uint256 sharesOut) {
        deal(address(paxg), to, amount);
        vm.startPrank(to);
        paxg.approve(address(boringVault), amount);
        sharesOut = teller.deposit(ERC20(address(paxg)), amount, 0);
        vm.stopPrank();
    }

}
