// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { console2 } from "forge-std/console2.sol";

import { PaxgyDynamicDepositFeeModule } from "src/helper/PaxgyDynamicDepositFeeModule.sol";
import { PaxgyDynamicWithdrawalFeeModule } from "src/helper/PaxgyDynamicWithdrawalFeeModule.sol";
import { PaxgXauRateProvider } from "src/oracles/PaxgXauRateProvider.sol";
import { IPriceFeed } from "src/interfaces/IPriceFeed.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { BaseScript } from "../Base.s.sol";

/**
 * @notice Deploys the PAXGy pricing stack in one run: the {PaxgXauRateProvider} composite oracle
 * (XAU per PAXG) followed by the {PaxgyDynamicDepositFeeModule} and {PaxgyDynamicWithdrawalFeeModule}
 * that price against it, all via CreateX CREATE3.
 * @dev The Chainlink PAXG/USD and XAU/USD feeds and the PAXG token only exist on Ethereum mainnet, so the
 * run is gated to chain id 1. Every input is a constant below, including {BORING_VAULT}: the modules can
 * only be wired to a vault that has already been deployed. Deploying the oracle in the same run removes the
 * cross-script address handoff: the modules always bind to the oracle this run produced and verified.
 */
contract PaxgyOracleFeeModuleSetup is BaseScript {

    address constant BORING_VAULT = 0x6c6494Fd9962eB98B94ffA48F6679058F820700e;

    string constant RATE_PROVIDER_NAME_ENTROPY = "Paxgy:PaxgXauRateProvider";
    string constant DEPOSIT_FEE_MODULE_NAME_ENTROPY = "Paxgy:DynamicDepositFeeModule";
    string constant WITHDRAWAL_FEE_MODULE_NAME_ENTROPY = "Paxgy:DynamicWithdrawalFeeModule";

    // Chainlink Ethereum mainnet feeds. Verify against docs.chain.link before broadcasting.
    address constant PAXG_USD_FEED = 0x9944D86CEB9160aF5C5feB251FD671923323f8C3;
    address constant XAU_USD_FEED = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;

    string constant PAXG_USD_DESCRIPTION = "PAXG / USD";
    string constant XAU_USD_DESCRIPTION = "XAU / USD";

    // PAXG token (18 decimals): its decimals define the oracle's output precision, and it is the only
    // asset either fee module prices.
    address constant PAXG_TOKEN = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;

    // The Chainlink PAXG/USD feed's heartbeat is 86400s (24h); we add 100s to account for block delay.
    uint256 constant MAX_TIME_FROM_LAST_UPDATE = 86_500;

    // Fixed withdrawal fee in basis points: 10 = 0.10%.
    uint256 constant WITHDRAWAL_FIXED_FEE_BPS = 10;
    uint256 constant BPS_DIVISOR = 10_000;

    // Used for checking that the output fees are accurate
    uint256 constant PEG_PRICE = 1e18;

    // Equal to PEG_PRICE so each module's mulDivUp divides evenly: the expected probe fee is exact, not a
    // rounded band.
    uint256 constant FEE_PROBE_AMOUNT = PEG_PRICE;

    // Launch gate, not a safety property: PAXG tracks gold spot well inside 1% in an ordinary market, so a
    // depeg fee past 2% of the probe means the market is wrong, not the wiring.
    uint256 constant MAX_DEPEG_FEE = 0.02e18;

    /// @notice Deploys the oracle and both fee modules, then verifies each one's wiring before returning.
    function run()
        public
        broadcast
        returns (address rateProvider, address depositFeeModule, address withdrawalFeeModule)
    {
        if (block.chainid != 1) {
            revert("PaxgyOracleFeeModuleSetup: PAXG/XAU feeds and PAXG only exist on Ethereum mainnet (chainid 1)");
        }
        require(BORING_VAULT != address(0), "PaxgyOracleFeeModuleSetup: BORING_VAULT is unset");
        require(BORING_VAULT.code.length != 0, "PaxgyOracleFeeModuleSetup: boring vault has no code on this chain");

        rateProvider = _deployRateProvider();
        depositFeeModule = _deployDepositFeeModule(rateProvider, BORING_VAULT);
        withdrawalFeeModule = _deployWithdrawalFeeModule(rateProvider, BORING_VAULT);

        console2.log("PAXGy shares (BoringVault): ", BORING_VAULT);
        console2.log("PaxgXauRateProvider: ", rateProvider);
        console2.log("PaxgyDynamicDepositFeeModule: ", depositFeeModule);
        console2.log("PaxgyDynamicWithdrawalFeeModule: ", withdrawalFeeModule);
    }

    function _deployRateProvider() internal returns (address rateProvider) {
        bytes32 salt = makeSalt(broadcaster, false, RATE_PROVIDER_NAME_ENTROPY);

        rateProvider = CREATEX.deployCreate3(
            salt,
            abi.encodePacked(
                type(PaxgXauRateProvider).creationCode,
                abi.encode(
                    PAXG_USD_DESCRIPTION,
                    XAU_USD_DESCRIPTION,
                    ERC20(PAXG_TOKEN),
                    IPriceFeed(PAXG_USD_FEED),
                    IPriceFeed(XAU_USD_FEED),
                    MAX_TIME_FROM_LAST_UPDATE
                )
            )
        );

        // The constructor validates each feed's description and decimals, but it does not confirm the
        // wiring produced a usable composite oracle. Fail here rather than ship an oracle that reverts or
        // mis-scales at the consumer's first getRate().
        PaxgXauRateProvider oracle = PaxgXauRateProvider(rateProvider);

        // Output precision must be 18: the fee modules and accountant compare getRate() against a hardcoded
        // 1e18 peg, so any other precision silently mis-scales every downstream fee.
        require(oracle.RATE_DECIMALS() == 18, "PaxgyOracleFeeModuleSetup: RATE_DECIMALS != 18");

        // Guards against a swapped or edited constant that still happens to share a description.
        require(address(oracle.PAXG_USD_FEED()) == PAXG_USD_FEED, "PaxgyOracleFeeModuleSetup: PAXG/USD feed mismatch");
        require(address(oracle.XAU_USD_FEED()) == XAU_USD_FEED, "PaxgyOracleFeeModuleSetup: XAU/USD feed mismatch");

        // Exercises the staleness and positivity guards against the real feeds; the band catches gross
        // scaling/wiring errors: PAXG is backed 1:1 by one troy ounce of gold, so XAU per PAXG sits within
        // ~10% of 1e18 in any normal market.
        uint256 rate = oracle.getRate();
        require(rate >= 0.9e18 && rate <= 1.1e18, "PaxgyOracleFeeModuleSetup: getRate() outside sane band");

        console2.log("PaxgXauRateProvider getRate(): ", rate);
    }

    function _deployDepositFeeModule(address rateProvider, address shares) internal returns (address feeModule) {
        bytes32 salt = makeSalt(broadcaster, false, DEPOSIT_FEE_MODULE_NAME_ENTROPY);

        feeModule = CREATEX.deployCreate3(
            salt,
            abi.encodePacked(
                type(PaxgyDynamicDepositFeeModule).creationCode,
                abi.encode(IRateProvider(rateProvider), IERC20(PAXG_TOKEN), IERC20(shares))
            )
        );

        PaxgyDynamicDepositFeeModule module = PaxgyDynamicDepositFeeModule(feeModule);
        require(
            address(module.RATE_PROVIDER()) == rateProvider, "PaxgyOracleFeeModuleSetup: deposit rate provider mismatch"
        );
        require(address(module.PAXG()) == PAXG_TOKEN, "PaxgyOracleFeeModuleSetup: deposit PAXG mismatch");
        require(address(module.SHARES()) == shares, "PaxgyOracleFeeModuleSetup: deposit shares mismatch");

        // Equality pins the module's math to the live oracle end-to-end; the immutable checks above only
        // compare stored addresses and never execute the fee path.
        uint256 rate = IRateProvider(rateProvider).getRate();
        uint256 fee = module.calculateOfferFees(FEE_PROBE_AMOUNT, IERC20(PAXG_TOKEN), IERC20(shares), address(0));
        require(
            fee == (rate >= PEG_PRICE ? 0 : PEG_PRICE - rate), "PaxgyOracleFeeModuleSetup: deposit fee != peg shortfall"
        );
        require(fee <= MAX_DEPEG_FEE, "PaxgyOracleFeeModuleSetup: deposit depeg fee above launch cap");

        console2.log("PaxgyDynamicDepositFeeModule fee on 1e18 PAXG: ", fee);
    }

    function _deployWithdrawalFeeModule(address rateProvider, address shares) internal returns (address feeModule) {
        bytes32 salt = makeSalt(broadcaster, false, WITHDRAWAL_FEE_MODULE_NAME_ENTROPY);

        feeModule = CREATEX.deployCreate3(
            salt,
            abi.encodePacked(
                type(PaxgyDynamicWithdrawalFeeModule).creationCode,
                abi.encode(IRateProvider(rateProvider), IERC20(PAXG_TOKEN), IERC20(shares), WITHDRAWAL_FIXED_FEE_BPS)
            )
        );

        PaxgyDynamicWithdrawalFeeModule module = PaxgyDynamicWithdrawalFeeModule(feeModule);
        require(
            address(module.RATE_PROVIDER()) == rateProvider,
            "PaxgyOracleFeeModuleSetup: withdrawal rate provider mismatch"
        );
        require(address(module.PAXG()) == PAXG_TOKEN, "PaxgyOracleFeeModuleSetup: withdrawal PAXG mismatch");
        require(address(module.SHARES()) == shares, "PaxgyOracleFeeModuleSetup: withdrawal shares mismatch");
        require(
            module.FIXED_FEE_BPS() == WITHDRAWAL_FIXED_FEE_BPS,
            "PaxgyOracleFeeModuleSetup: withdrawal fixed fee mismatch"
        );

        // The fixed fee is charged at any price, so it floors the total. A total below it means the fixed
        // component never took, which the FIXED_FEE_BPS check above cannot see: that reads storage, not the
        // fee path.
        uint256 fixedFee = (FEE_PROBE_AMOUNT * WITHDRAWAL_FIXED_FEE_BPS) / BPS_DIVISOR;
        uint256 fee = module.calculateOfferFees(FEE_PROBE_AMOUNT, IERC20(shares), IERC20(PAXG_TOKEN), address(0));
        require(fee >= fixedFee, "PaxgyOracleFeeModuleSetup: withdrawal fee below fixed floor");
        require(fee <= fixedFee + MAX_DEPEG_FEE, "PaxgyOracleFeeModuleSetup: withdrawal depeg fee above launch cap");

        console2.log("PaxgyDynamicWithdrawalFeeModule fee on 1e18 shares: ", fee);
    }

}
