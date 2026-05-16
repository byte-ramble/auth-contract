// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../src/TopicAccessManagerUpgradeable.sol";

interface VmScript {
    function startBroadcast() external;

    function stopBroadcast() external;
}

contract DeployImplementationScript {
    VmScript internal constant vm = VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (address newImplementation) {
        vm.startBroadcast();

        TopicAccessManagerUpgradeable impl = new TopicAccessManagerUpgradeable();

        vm.stopBroadcast();

        newImplementation = address(impl);
    }
}
