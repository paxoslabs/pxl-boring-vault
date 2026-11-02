// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { console2 } from "@forge-std/console2.sol";

import { GenericRateProvider } from "src/helper/GenericRateProvider.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BaseScript } from "../Base.s.sol";

/**
 * @notice Deploys the rate provider that prices PAXGy for vaults whose base is PAXG, and records its address in the
 * chain config so `TellerSetup` can wire it.
 * @dev Reads PAXGy's own accountant, `getRateInQuoteSafe(PAXG)`, rather than the Chainlink PAXGy / Gold feed: the feed
 * mirrors that accountant on a delay, so it adds lag and a heartbeat dependency without adding an independent source.
 * @custom:security The rate is set by PAXGy's accountant, governed by Paxos Labs. It reverts while that accountant is
 * paused, which halts PAXGy deposits and all withdrawal processing in the consuming vault.
 */
contract DeployPaxgyRateProvider is BaseScript {

    using StdJson for string;
    using Strings for address;

    address constant PAXGY = 0x6c6494Fd9962eB98B94ffA48F6679058F820700e;
    address constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    string constant NAME_ENTROPY = "LiquidGold:PaxgyRateProvider";

    function run() public broadcast returns (address rateProvider) {
        require(block.chainid == 1, "PAXGy only exists on Ethereum mainnet");

        string memory chainConfig = getChainConfigFile();
        string memory assetKey = string.concat(".assetToRateProviderAndPriceFeed.", PAXGY.toHexString());
        address target = chainConfig.readAddress(string.concat(assetKey, ".target"));
        bytes4 selector = bytes4(keccak256(bytes(chainConfig.readString(string.concat(assetKey, ".signature")))));

        // Any Nucleus accountant returns a plausible ~1e18 here, so the band check alone cannot catch a wrong target.
        require(address(AccountantWithRateProviders(target).vault()) == PAXGY, "target is not the PAXGy accountant");
        require(selector == AccountantWithRateProviders.getRateInQuoteSafe.selector, "unexpected signature");

        rateProvider = CREATEX.deployCreate3(
            makeSalt(broadcaster, false, NAME_ENTROPY),
            abi.encodePacked(
                type(GenericRateProvider).creationCode,
                abi.encode(target, selector, bytes32(uint256(uint160(PAXG))), 0, 0, 0, 0, 0, 0, 0)
            )
        );

        uint256 rate = GenericRateProvider(rateProvider).getRate();
        require(rate >= chainConfig.readUint(string.concat(assetKey, ".expectedMin")), "rate below expectedMin");
        require(rate <= chainConfig.readUint(string.concat(assetKey, ".expectedMax")), "rate above expectedMax");
        require(
            rate == AccountantWithRateProviders(target).getRateInQuoteSafe(ERC20(PAXG)),
            "rate does not match accountant"
        );

        rateProvider.toHexString()
            .write(
                string.concat(CONFIG_CHAIN_ROOT, Strings.toString(block.chainid), ".json"),
                string.concat(assetKey, ".rateProvider")
            );

        console2.log("PAXGy rate provider: ", rateProvider);
        console2.log("getRate(): ", rate);
    }

}
