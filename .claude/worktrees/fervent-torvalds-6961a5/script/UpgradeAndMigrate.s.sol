// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../src/TopicAccessManagerUpgradeable.sol";

interface VmScript {
    function envAddress(
        string calldata key
    ) external view returns (address);

    function startBroadcast() external;

    function stopBroadcast() external;
}

contract UpgradeAndMigrateScript {
    VmScript internal constant vm = VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (address newImplementation, address migratedUsdc, address migratedUsdt) {
        address payable proxyAddress = payable(vm.envAddress("PROXY_ADDRESS"));

        vm.startBroadcast();

        TopicAccessManagerUpgradeable impl = new TopicAccessManagerUpgradeable();
        TopicAccessManagerUpgradeable manager = TopicAccessManagerUpgradeable(proxyAddress);

        manager.upgradeToAndCall(address(impl), "");

        (address legacyUsdc, address legacyUsdt) = manager.getLegacyStableTokens();
        _enableStableIfNeeded(manager, legacyUsdc);

        if (legacyUsdt != legacyUsdc) {
            _enableStableIfNeeded(manager, legacyUsdt);
        }

        vm.stopBroadcast();

        return (address(impl), legacyUsdc, legacyUsdt);
    }

    function _enableStableIfNeeded(
        TopicAccessManagerUpgradeable manager,
        address token
    ) internal {
        if (token == address(0) || token == manager.RAMBLE_TOKEN() || token.code.length == 0) {
            return;
        }

        (bool enabled,) = manager.getStableTokenConfig(token);
        if (!enabled) {
            manager.setStableToken(token, true);
        }
    }
}

