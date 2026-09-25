// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { stdJson as StdJson } from "@forge-std/StdJson.sol";

interface IAuthority {

    function setAuthority(address newAuthority) external;
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);

}

library ConfigReader {

    using StdJson for string;

    struct Config {
        string nameEntropy;
        address protocolAdmin;
        address base;
        uint8 boringVaultAndBaseDecimals;
        address boringVault;
        address payoutAddress;
        uint16 allowedExchangeRateChangeUpper;
        uint16 allowedExchangeRateChangeLower;
        uint32 minimumUpdateDelayInSeconds;
        uint16 managementFee;
        uint16 performanceFee;
        string boringVaultName;
        string boringVaultSymbol;
        bool setBeforeTransferHook;
        address balancerVault;
        uint32 peerEid;
        bool setupLZConfigs;
        address[] requiredDvns;
        address[] optionalDvns;
        uint64 dvnBlockConfirmationsRequired;
        uint8 optionalDvnThreshold;
        address accountant;
        address opMessenger;
        uint64 maxGasForPeer;
        uint64 minGasForPeer;
        address lzEndpoint;
        address mailbox;
        uint32 peerDomainId;
        address ccipRouter;
        uint32 peerChainId;
        uint64 peerCcipChainSelector;
        bool setupCCIPConfigs;
        uint32 ccipOutboundFinality;
        uint32 ccipInboundFinality;
        bool ccipOutboundRateLimitEnabled;
        uint128 ccipOutboundRateLimitCapacity;
        uint128 ccipOutboundRateLimitRate;
        bool ccipInboundRateLimitEnabled;
        uint128 ccipInboundRateLimitCapacity;
        uint128 ccipInboundRateLimitRate;
        address manager;
        address teller;
        string tellerContractName;
        address strategist;
        address exchangeRateBot;
        address rolesAuthority;
        uint256 maxTimeFromLastUpdate;
        // Per-asset fees are stored as parallel arrays rather than a struct array, because Solidity
        // 0.8.21 does not support copying a memory dynamic array of structs into storage (which
        // happens when `Config memory` is assigned to `Config storage` in deployAll). Indices line
        // up: withdrawAssets[i] pairs with withdrawAssetFlatFees[i] and withdrawAssetPercentFees[i].
        // The author of the config json must be sure these arrays are the same length
        address[] withdrawAssets;
        uint256[] withdrawAssetFlatFees;
        uint256[] withdrawAssetPercentFees;
        address[] depositAssets;
        uint256[] depositAssetFlatFees;
        uint256[] depositAssetPercentFees;
        address[] rateProviders;
        address[] priceFeeds;
        bool distributorCodeDepositorDeploy;
        bool distributorCodeDepositorIsNativeDepositSupported;
        address distributorCodeDepositor;
        address nativeWrapper;
        address uniswapV3NonFungiblePositionManager;
        uint256 distributorCodeDepositorSupplyCap;
        address registry;
        string policyID;
        string withdrawQueueName;
        string withdrawQueueSymbol;
        address withdrawQueueFeeRecipient;
        uint256 withdrawQueueMinimumOrderSize;
        address withdrawQueue;
        address withdrawQueueProcessorAddress;
        address genericDecoderAndSanitizer;
        string boringVaultModuleSpecificNameEntropy;
        string managerModuleSpecificNameEntropy;
        string accountantModuleSpecificNameEntropy;
        string tellerModuleSpecificNameEntropy;
        string rolesAuthorityModuleSpecificNameEntropy;
        string distributorCodeDepositorModuleSpecificNameEntropy;
        string withdrawQueueModuleSpecificNameEntropy;
        string genericDecoderAndSanitizerModuleSpecificNameEntropy;
    }

    function toConfig(string memory _config, string memory _chainConfig) internal view returns (Config memory config) {
        // Reading the 'nameEntropy`
        config.nameEntropy = _config.readString(".nameEntropy");

        // Reading the 'protocolAdmin'
        config.protocolAdmin = _config.readAddress(".protocolAdmin");
        config.base = _config.readAddress(".base");
        config.boringVaultAndBaseDecimals = uint8(_config.readUint(".boringVaultAndBaseDecimals"));

        // Reading from the 'accountant' section
        config.accountant = _config.readAddress(".accountant.address");
        config.payoutAddress = _config.readAddress(".accountant.payoutAddress");
        config.allowedExchangeRateChangeUpper = uint16(_config.readUint(".accountant.allowedExchangeRateChangeUpper"));
        config.allowedExchangeRateChangeLower = uint16(_config.readUint(".accountant.allowedExchangeRateChangeLower"));
        config.minimumUpdateDelayInSeconds = uint32(_config.readUint(".accountant.minimumUpdateDelayInSeconds"));
        config.managementFee = uint16(_config.readUint(".accountant.managementFee"));
        config.performanceFee = uint16(_config.readUint(".accountant.performanceFee"));
        config.accountantModuleSpecificNameEntropy = _config.readStringOr(".accountant.moduleSpecificNameEntropy", "");

        // Reading from the 'boringVault' section
        config.boringVault = _config.readAddress(".boringVault.address");
        config.boringVaultName = _config.readString(".boringVault.boringVaultName");
        config.boringVaultSymbol = _config.readString(".boringVault.boringVaultSymbol");
        config.setBeforeTransferHook = _config.readBoolOr(".boringVault.setBeforeTransferHookAddress", true);
        config.boringVaultModuleSpecificNameEntropy = _config.readStringOr(".boringVault.moduleSpecificNameEntropy", "");

        // Reading from the 'manager' section
        config.manager = _config.readAddress(".manager.address");
        config.managerModuleSpecificNameEntropy = _config.readStringOr(".manager.moduleSpecificNameEntropy", "");

        // Reading from the 'teller' section
        config.teller = _config.readAddress(".teller.address");
        config.maxGasForPeer = uint64(_config.readUint(".teller.maxGasForPeer"));
        config.minGasForPeer = uint64(_config.readUint(".teller.minGasForPeer"));
        config.tellerContractName = _config.readString(".teller.tellerContractName");
        config.tellerModuleSpecificNameEntropy = _config.readStringOr(".teller.moduleSpecificNameEntropy", "");
        config.withdrawAssets = _config.readAddressArray(".teller.withdrawAssets");
        config.withdrawAssetFlatFees =
            _config.readUintArrayOr(".teller.withdrawAssetFlatFees", new uint256[](config.withdrawAssets.length));
        config.withdrawAssetPercentFees =
            _config.readUintArrayOr(".teller.withdrawAssetPercentFees", new uint256[](config.withdrawAssets.length));
        require(
            config.withdrawAssets.length == config.withdrawAssetFlatFees.length
                && config.withdrawAssets.length == config.withdrawAssetPercentFees.length,
            "ConfigReader: withdrawAssets fee arrays length mismatch"
        );

        config.depositAssets = _config.readAddressArray(".teller.depositAssets");
        config.depositAssetFlatFees =
            _config.readUintArrayOr(".teller.depositAssetFlatFees", new uint256[](config.depositAssets.length));
        config.depositAssetPercentFees =
            _config.readUintArrayOr(".teller.depositAssetPercentFees", new uint256[](config.depositAssets.length));
        require(
            config.depositAssets.length == config.depositAssetFlatFees.length
                && config.depositAssets.length == config.depositAssetPercentFees.length,
            "ConfigReader: depositAssets fee arrays length mismatch"
        );

        // layerzero
        if (compareStrings(config.tellerContractName, "MultiChainLayerZeroTellerWithMultiAssetSupport")) {
            config.lzEndpoint = _chainConfig.readAddress(".lzEndpoint");

            config.peerEid = uint32(_config.readUint(".teller.peerEid"));
            config.setupLZConfigs = _config.readBool(".teller.setupLZConfigs");
            config.requiredDvns = _config.readAddressArray(".teller.dvnIfNoDefault.required");
            config.optionalDvns = _config.readAddressArray(".teller.dvnIfNoDefault.optional");
            config.dvnBlockConfirmationsRequired =
                uint64(_config.readUint(".teller.dvnIfNoDefault.blockConfirmationsRequiredIfNoDefault"));
            config.optionalDvnThreshold = uint8(_config.readUint(".teller.dvnIfNoDefault.optionalThreshold"));
        } else if (compareStrings(config.tellerContractName, "MultiChainHyperlaneTellerWithMultiAssetSupport")) {
            config.mailbox = _chainConfig.readAddress(".mailbox");
            config.peerDomainId = uint32(_config.readUint(".teller.peerDomainId"));
        } else if (compareStrings(config.tellerContractName, "MultiChainCCIPTellerWithMultiAssetSupport")) {
            config.ccipRouter = _chainConfig.readAddress(".ccipRouter");

            config.setupCCIPConfigs = _config.readBool(".teller.setupCCIPConfigs");
            // The uint32 key MultiChainTellerBase uses for this lane is the peer's EVM chain id; CCIP's own uint64
            // selector for that chain is carried separately and mapped by setCcipChainSelector.
            config.peerChainId = uint32(_config.readUint(".teller.peerChainId"));
            config.peerCcipChainSelector = uint64(_config.readUint(".teller.peerCcipChainSelector"));

            // Unset means WAIT_FOR_FINALITY (bytes4(0)) and disabled rate limiters, which are the safe defaults.
            config.ccipOutboundFinality = uint32(_config.readUintOr(".teller.ccipOutboundFinality", 0));
            config.ccipInboundFinality = uint32(_config.readUintOr(".teller.ccipInboundFinality", 0));
            config.ccipOutboundRateLimitEnabled = _config.readBoolOr(".teller.ccipOutboundRateLimit.isEnabled", false);
            config.ccipOutboundRateLimitCapacity =
                uint128(_config.readUintOr(".teller.ccipOutboundRateLimit.capacity", 0));
            config.ccipOutboundRateLimitRate = uint128(_config.readUintOr(".teller.ccipOutboundRateLimit.rate", 0));
            config.ccipInboundRateLimitEnabled = _config.readBoolOr(".teller.ccipInboundRateLimit.isEnabled", false);
            config.ccipInboundRateLimitCapacity =
                uint128(_config.readUintOr(".teller.ccipInboundRateLimit.capacity", 0));
            config.ccipInboundRateLimitRate = uint128(_config.readUintOr(".teller.ccipInboundRateLimit.rate", 0));
        }

        // Reading from the 'rolesAuthority' section
        config.rolesAuthority = _config.readAddress(".rolesAuthority.address");
        config.strategist = _config.readAddress(".rolesAuthority.strategist");
        config.exchangeRateBot = _config.readAddress(".rolesAuthority.exchangeRateBot");
        config.rolesAuthorityModuleSpecificNameEntropy =
            _config.readStringOr(".rolesAuthority.moduleSpecificNameEntropy", "");

        // Reading from the 'distributorCodeDepositor' section
        config.distributorCodeDepositorDeploy = _config.readBool(".distributorCodeDepositor.deploy");
        config.distributorCodeDepositorIsNativeDepositSupported =
            _config.readBool(".distributorCodeDepositor.nativeSupported");
        config.distributorCodeDepositorSupplyCap = _config.readUint(".distributorCodeDepositor.supplyCap");
        config.registry = _config.readAddress(".distributorCodeDepositor.registry");
        config.policyID = _config.readString(".distributorCodeDepositor.policyID");
        config.distributorCodeDepositorModuleSpecificNameEntropy =
            _config.readStringOr(".distributorCodeDepositor.moduleSpecificNameEntropy", "");

        // Reading from the 'withdrawQueue' section
        config.withdrawQueueName = _config.readString(".withdrawQueue.name");
        config.withdrawQueueSymbol = _config.readString(".withdrawQueue.symbol");
        config.withdrawQueueFeeRecipient = _config.readAddress(".withdrawQueue.feeRecipient");
        config.withdrawQueueMinimumOrderSize = uint256(_config.readUint(".withdrawQueue.minimumOrderSize"));
        config.withdrawQueueProcessorAddress = _config.readAddress(".withdrawQueue.processorAddress");
        config.withdrawQueueModuleSpecificNameEntropy =
            _config.readStringOr(".withdrawQueue.moduleSpecificNameEntropy", "");

        // Reading from the 'chainConfig' section
        config.balancerVault = _chainConfig.readAddress(".balancerVault");
        config.nativeWrapper = _chainConfig.readAddress(".nativeWrapper");
        // Optional: only required by chains that deploy a Uniswap-V3-aware decoder/sanitizer.
        config.uniswapV3NonFungiblePositionManager =
            _chainConfig.readAddressOr(".uniswapV3NonFungiblePositionManager", address(0));

        config.genericDecoderAndSanitizerModuleSpecificNameEntropy =
            _config.readStringOr(".genericDecoderAndSanitizer.moduleSpecificNameEntropy", "");

        return config;
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b)));
    }

}
