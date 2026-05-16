// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../src/TopicAccessManagerUpgradeable.sol";

interface VmScript {
    function envAddress(
        string calldata key
    ) external view returns (address);

    function envUint(
        string calldata key
    ) external view returns (uint256);

    function envString(
        string calldata key,
        string calldata delimiter
    ) external view returns (string[] memory value);

    function envUint(
        string calldata key,
        string calldata delimiter
    ) external view returns (uint256[] memory value);

    function envOr(
        string calldata key,
        string calldata defaultValue
    ) external view returns (string memory value);

    function startBroadcast() external;

    function stopBroadcast() external;
}

contract PostDeployConfigureScript {
    uint256 private constant BSC_MAINNET_CHAIN_ID = 56;

    address private constant WETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address private constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address private constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;

    address private constant ETH_USD_ORACLE = 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e;
    address private constant BTC_USD_ORACLE = 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf;
    address private constant USDT_USD_ORACLE = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    address private constant USDC_USD_ORACLE = 0x51597f405303C4377E36123cBc172b13269EA163;

    error ConfigArrayLengthMismatch(uint256 keysLength, uint256 endsAtLength);
    error InvalidBooleanString(string value);
    error InvalidUintString(string value);
    error TopicMissing(bytes32 topicId, string topicKey);

    VmScript internal constant vm = VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run()
        external
        returns (uint256 configuredTokens, uint256 configuredTopicTrials, uint256 globalTrialEndsAt)
    {
        address payable proxyAddress = payable(vm.envAddress("PROXY_ADDRESS"));
        TopicAccessManagerUpgradeable manager = TopicAccessManagerUpgradeable(proxyAddress);

        (address bnbUsdOracle,) = manager.getOracleConfig();

        bool configureBscPaymentTokens = _envOrBool("CONFIGURE_BSC_PAYMENT_TOKENS", true);
        string memory rambleDiscountRaw = vm.envOr("RAMBLE_DISCOUNT_BPS", string(""));
        bool hasRambleDiscount = bytes(rambleDiscountRaw).length != 0;
        string memory globalTrialRaw = vm.envOr("GLOBAL_TRIAL_ENDS_AT", string(""));
        bool hasGlobalTrial = bytes(globalTrialRaw).length != 0;

        vm.startBroadcast();

        if (configureBscPaymentTokens && block.chainid == BSC_MAINNET_CHAIN_ID) {
            configuredTokens += _setPaymentTokenIfNeeded(manager, WETH, ETH_USD_ORACLE);
            configuredTokens += _setPaymentTokenIfNeeded(manager, USDT, USDT_USD_ORACLE);
            configuredTokens += _setPaymentTokenIfNeeded(manager, USDC, USDC_USD_ORACLE);
            configuredTokens += _setPaymentTokenIfNeeded(manager, WBNB, bnbUsdOracle);
            configuredTokens += _setPaymentTokenIfNeeded(manager, BTCB, BTC_USD_ORACLE);
        }

        if (hasRambleDiscount) {
            uint16 rambleDiscountBps = _parseUint16(rambleDiscountRaw);
            if (manager.getRambleDiscountBps() != rambleDiscountBps) {
                manager.setRambleDiscountBps(rambleDiscountBps);
            }
        }

        if (hasGlobalTrial) {
            globalTrialEndsAt = _parseUint(globalTrialRaw);
            if (manager.getGlobalTrialEndsAt() != globalTrialEndsAt) {
                manager.setGlobalTrialEndsAt(globalTrialEndsAt);
            }
        }

        _configureTopic(manager);
        configuredTopicTrials = _configureTopicTrials(manager);

        vm.stopBroadcast();
    }

    function _configureTopic(
        TopicAccessManagerUpgradeable manager
    ) internal {
        string memory topicKey = vm.envOr("TOPIC_KEY", string(""));
        if (bytes(topicKey).length == 0) {
            return;
        }

        bytes32 topicId = keccak256(bytes(topicKey));
        uint256 monthlyPriceWad = vm.envUint("TOPIC_PRICE_WAD");

        if (!manager.topicExists(topicId)) {
            manager.createTopicByKey(topicKey, monthlyPriceWad);
        } else {
            if (manager.getTopicPriceWad(topicId) != monthlyPriceWad) {
                manager.setTopicPrice(topicId, monthlyPriceWad);
            }

            if (keccak256(bytes(manager.getTopicKey(topicId))) != keccak256(bytes(topicKey))) {
                manager.setTopicKey(topicId, topicKey);
            }
        }

        string memory annualPriceRaw = vm.envOr("TOPIC_ANNUAL_PRICE_WAD", string(""));
        if (bytes(annualPriceRaw).length != 0) {
            uint256 annualPriceWad = _parseUint(annualPriceRaw);
            if (manager.getTopicAnnualPriceWad(topicId) != annualPriceWad) {
                manager.setTopicAnnualPrice(topicId, annualPriceWad);
            }
        }
    }

    function _configureTopicTrials(
        TopicAccessManagerUpgradeable manager
    ) internal returns (uint256 configuredTopicTrials) {
        string memory topicKeysRaw = vm.envOr("TOPIC_TRIAL_KEYS", string(""));
        if (bytes(topicKeysRaw).length == 0) {
            return 0;
        }

        string[] memory topicKeys = vm.envString("TOPIC_TRIAL_KEYS", ",");
        uint256[] memory trialEndsAtValues = vm.envUint("TOPIC_TRIAL_ENDS_ATS", ",");

        if (topicKeys.length != trialEndsAtValues.length) {
            revert ConfigArrayLengthMismatch(topicKeys.length, trialEndsAtValues.length);
        }

        for (uint256 i = 0; i < topicKeys.length; ++i) {
            string memory topicKey = topicKeys[i];
            bytes32 topicId = keccak256(bytes(topicKey));
            if (!manager.topicExists(topicId)) {
                revert TopicMissing(topicId, topicKey);
            }

            uint256 trialEndsAt = trialEndsAtValues[i];
            if (manager.getTopicTrialEndsAt(topicId) == trialEndsAt) {
                continue;
            }

            manager.setTopicTrialEndsAt(topicId, trialEndsAt);
            ++configuredTopicTrials;
        }
    }

    function _setPaymentTokenIfNeeded(
        TopicAccessManagerUpgradeable manager,
        address token,
        address usdOracle
    ) internal returns (uint256 configured) {
        (bool enabled,, address currentOracle,) = manager.getPaymentTokenConfig(token);
        if (enabled && currentOracle == usdOracle) {
            return 0;
        }

        manager.setPaymentToken(token, true, usdOracle);
        return 1;
    }

    function _envOrBool(
        string memory key,
        bool defaultValue
    ) internal view returns (bool value) {
        string memory raw = vm.envOr(key, defaultValue ? string("true") : string("false"));
        bytes32 normalized = _normalizedStringHash(raw);

        if (
            normalized == keccak256(bytes("true")) || normalized == keccak256(bytes("1"))
                || normalized == keccak256(bytes("yes"))
        ) {
            return true;
        }
        if (
            normalized == keccak256(bytes("false")) || normalized == keccak256(bytes("0"))
                || normalized == keccak256(bytes("no"))
        ) {
            return false;
        }

        revert InvalidBooleanString(raw);
    }

    function _parseUint(
        string memory raw
    ) internal pure returns (uint256 value) {
        bytes memory rawBytes = bytes(raw);
        if (rawBytes.length == 0) {
            revert InvalidUintString(raw);
        }

        for (uint256 i = 0; i < rawBytes.length; ++i) {
            uint8 charCode = uint8(rawBytes[i]);
            if (charCode < 48 || charCode > 57) {
                revert InvalidUintString(raw);
            }

            value = (value * 10) + (charCode - 48);
        }
    }

    function _parseUint16(
        string memory raw
    ) internal pure returns (uint16 value) {
        uint256 parsed = _parseUint(raw);
        if (parsed > type(uint16).max) {
            revert InvalidUintString(raw);
        }

        // casting to uint16 is safe because parsed was range-checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        value = uint16(parsed);
    }

    function _normalizedStringHash(
        string memory value
    ) internal pure returns (bytes32) {
        bytes memory raw = bytes(value);
        bytes memory normalized = new bytes(raw.length);

        for (uint256 i = 0; i < raw.length; ++i) {
            uint8 charCode = uint8(raw[i]);
            if (charCode >= 65 && charCode <= 90) {
                normalized[i] = bytes1(charCode + 32);
            } else {
                normalized[i] = raw[i];
            }
        }

        return keccak256(normalized);
    }
}
