// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { AccountantWithRateProviders } from "./../../../src/base/Roles/AccountantWithRateProviders.sol";
import { BaseScript } from "./../../Base.s.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";

contract DeployAccountantWithRateProviders is BaseScript {

    using StdJson for string;

    function run() public returns (address accountant) {
        return deploy(getConfig());
    }

    function _deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require Config Values
        uint256 startingExchangeRate = 10 ** ERC20(config.base).decimals();
        {
            require(config.boringVault.code.length != 0, "boringVault must have code");
            require(config.base.code.length != 0, "base must have code");
            require(config.boringVault != address(0), "boring vault address must not be zero");
            require(config.payoutAddress != address(0), "payout address must not be zero");
            require(config.base != address(0), "base address must not be zero");
            require(config.allowedExchangeRateChangeUpper >= 1e4, "allowedExchangeRateChangeUpper");
            require(config.allowedExchangeRateChangeUpper <= 1.003e4, "allowedExchangeRateChangeUpper upper bound");
            require(config.allowedExchangeRateChangeLower <= 1e4, "allowedExchangeRateChangeLower");
            require(config.allowedExchangeRateChangeLower >= 0.997e4, "allowedExchangeRateChangeLower lower bound");
            require(config.minimumUpdateDelayInSeconds >= 3600, "minimumUpdateDelayInSeconds");
            require(config.managementFee < 1e4, "managementFee");
            require(
                startingExchangeRate == 10 ** config.boringVaultAndBaseDecimals,
                "starting exchange rate must be equal to the boringVault and base decimals"
            );
        }
        // Create Contract
        bytes memory creationCode = type(AccountantWithRateProviders).creationCode;
        AccountantWithRateProviders accountant;

        bytes memory params;
        {
            params = abi.encode(
                broadcaster,
                config.boringVault,
                config.payoutAddress,
                startingExchangeRate,
                config.base,
                config.allowedExchangeRateChangeUpper,
                config.allowedExchangeRateChangeLower,
                config.minimumUpdateDelayInSeconds,
                config.managementFee,
                config.performanceFee
            );
        }

        bytes memory initCode;
        {
            initCode = abi.encodePacked(creationCode, params);
        }

        {
            bytes32 accountantSalt = makeSalt(
                broadcaster,
                false,
                string(
                    abi.encodePacked(
                        config.nameEntropy, ":AccountantWithRateProviders", config.accountantModuleSpecificNameEntropy
                    )
                )
            );
            accountant = AccountantWithRateProviders(CREATEX.deployCreate3(accountantSalt, initCode));
        }

        _accountantStateCheck(accountant, config, startingExchangeRate);
        return address(accountant);
    }

    function _accountantStateCheck(
        AccountantWithRateProviders accountant,
        ConfigReader.Config memory config,
        uint256 startingExchangeRate
    )
        internal
    {
        {
            (
                address _payoutAddress,
                uint128 _feesOwedInBase,
                uint128 _totalSharesLastUpdate,
                uint96 _exchangeRate,
                uint96 _highestExchangeRate,
                uint16 _allowedExchangeRateChangeUpper,
                uint16 _allowedExchangeRateChangeLower,
                uint64 _lastUpdateTimestamp,
                bool _isPaused,
                uint32 _minimumUpdateDelayInSeconds,
                uint16 _managementFee,
                uint16 _performanceFee
            ) = accountant.accountantState();

            // Post Deploy Checks
            require(_payoutAddress == config.payoutAddress, "payout address");
            require(_feesOwedInBase == 0, "fees owed in base");
            require(_totalSharesLastUpdate == 0, "total shares last update");
            require(_exchangeRate == startingExchangeRate, "exchange rate");
            require(
                _allowedExchangeRateChangeUpper == config.allowedExchangeRateChangeUpper,
                "allowed exchange rate change upper"
            );
            require(
                _allowedExchangeRateChangeLower == config.allowedExchangeRateChangeLower,
                "allowed exchange rate change lower"
            );
            require(_lastUpdateTimestamp == uint64(block.timestamp), "last update timestamp");
            require(_isPaused == false, "is paused");
            require(
                _minimumUpdateDelayInSeconds == config.minimumUpdateDelayInSeconds, "minimum update delay in seconds"
            );
            require(_managementFee == config.managementFee, "management fee");
            require(address(accountant.vault()) == config.boringVault, "vault");
            require(address(accountant.base()) == config.base, "base");
            require(accountant.decimals() == ERC20(config.base).decimals(), "decimals");
        }
    }

}
