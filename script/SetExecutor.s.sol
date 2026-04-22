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

contract SetExecutorScript {
    VmScript internal constant vm = VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (address executor_) {
        address payable proxyAddress = payable(vm.envAddress("PROXY_ADDRESS"));
        executor_ = vm.envAddress("EXECUTOR");
        TopicAccessManagerUpgradeable manager = TopicAccessManagerUpgradeable(proxyAddress);

        vm.startBroadcast();

        if (manager.getExecutor() != executor_) {
            manager.setExecutor(executor_);
        }

        vm.stopBroadcast();
    }
}
