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

contract UpgradeScript {
    VmScript internal constant vm = VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (address newImplementation) {
        address payable proxyAddress = payable(vm.envAddress("PROXY_ADDRESS"));

        vm.startBroadcast();

        TopicAccessManagerUpgradeable impl = new TopicAccessManagerUpgradeable();
        TopicAccessManagerUpgradeable(proxyAddress).upgradeToAndCall(address(impl), "");

        vm.stopBroadcast();

        newImplementation = address(impl);
    }
}
