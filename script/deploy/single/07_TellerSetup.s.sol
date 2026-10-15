// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { ManagerWithMerkleVerification } from "./../../../src/base/Roles/ManagerWithMerkleVerification.sol";
import { BoringVault } from "./../../../src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "./../../../src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "./../../../src/base/Roles/AccountantWithRateProviders.sol";
import { BaseScript } from "../../Base.s.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { CrossChainTellerBase } from "../../../src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { console } from "forge-std/console.sol";

contract TellerSetup is BaseScript {

    using Strings for address;
    using StdJson for string;

    function run() public virtual {
        deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public virtual override broadcast returns (address) {
        TellerWithMultiAssetSupport teller = TellerWithMultiAssetSupport(config.teller);

        // NOTE: Unlike previous versions of these scripts, the base asset is NOT given default support for deposit OR
        // withdrawals. The base asset must be configured in the file under the teller key for deposit/withdrawal
        // support

        // add the withdraw assets specified in the array of config
        for (uint256 i; i < config.withdrawAssets.length; ++i) {
            // add asset
            teller.addWithdrawAsset(ERC20(config.withdrawAssets[i]));

            string memory isPeggedKey = string(
                abi.encodePacked(
                    ".assetToRateProviderAndPriceFeed.", config.withdrawAssets[i].toHexString(), ".isPegged"
                )
            );

            bool isPegged = getChainConfigFile().readBool(isPeggedKey);

            console.log("WITHDRAW ASSET: ", config.withdrawAssets[i]);
            if (isPegged) {
                teller.accountant().setRateProviderData(ERC20(config.withdrawAssets[i]), true, address(0));
                console.log("- PEGGED");
            } else {
                // set the corresponding rate provider
                string memory key = string(
                    abi.encodePacked(
                        ".assetToRateProviderAndPriceFeed.", config.withdrawAssets[i].toHexString(), ".rateProvider"
                    )
                );
                address rateProvider = getChainConfigFile().readAddress(key);
                teller.accountant().setRateProviderData(ERC20(config.withdrawAssets[i]), false, rateProvider);
                console.log("- RATE PROVIDER: ", rateProvider);
            }
            _requireUsableRate(teller.accountant(), config.withdrawAssets[i]);
        }

        // add the deposit assets specified in the array of config
        for (uint256 i; i < config.depositAssets.length; ++i) {
            // add asset
            teller.addDepositAsset(ERC20(config.depositAssets[i]));

            string memory isPeggedKey = string(
                abi.encodePacked(
                    ".assetToRateProviderAndPriceFeed.", config.depositAssets[i].toHexString(), ".isPegged"
                )
            );

            bool isPegged = getChainConfigFile().readBool(isPeggedKey);

            console.log("DEPOSIT ASSET: ", config.depositAssets[i]);
            if (isPegged) {
                teller.accountant().setRateProviderData(ERC20(config.depositAssets[i]), true, address(0));
                console.log("- PEGGED");
            } else {
                // set the corresponding rate provider
                string memory key = string(
                    abi.encodePacked(
                        ".assetToRateProviderAndPriceFeed.", config.depositAssets[i].toHexString(), ".rateProvider"
                    )
                );
                address rateProvider = getChainConfigFile().readAddress(key);
                teller.accountant().setRateProviderData(ERC20(config.depositAssets[i]), false, rateProvider);
                console.log("- RATE PROVIDER: ", rateProvider);
            }
            _requireUsableRate(teller.accountant(), config.depositAssets[i]);
        }
    }

    /// @dev Checks the wiring just set, since setRateProviderData accepts any address and a bad entry would otherwise
    /// only surface at the first deposit or withdrawal.
    function _requireUsableRate(AccountantWithRateProviders accountant, address asset) internal view {
        (bool isPegged, IRateProvider rateProvider) = accountant.rateProviderData(ERC20(asset));
        if (!isPegged) {
            require(address(rateProvider).code.length != 0, "rate provider has no code");

            // Optional: entries for Chainlink and Redstone providers carry no band.
            string memory chainConfig = getChainConfigFile();
            string memory assetKey = string.concat(".assetToRateProviderAndPriceFeed.", asset.toHexString());
            if (vm.keyExistsJson(chainConfig, string.concat(assetKey, ".expectedMin"))) {
                uint256 rate = rateProvider.getRate();
                require(rate >= chainConfig.readUint(string.concat(assetKey, ".expectedMin")), "rate below expectedMin");
                require(rate <= chainConfig.readUint(string.concat(assetKey, ".expectedMax")), "rate above expectedMax");
            }
        }

        // The path deposits and withdrawals take, including the rate provider's own staleness check.
        require(accountant.getRateInQuoteSafe(ERC20(asset)) != 0, "rate in quote is zero");
    }

}
