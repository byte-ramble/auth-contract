// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../src/TopicAccessManagerUpgradeable.sol";

interface VmScript {
    function envAddress(
        string calldata key
    ) external view returns (address);

    function envOr(
        string calldata key,
        string calldata defaultValue
    ) external view returns (string memory value);

    function envUint(
        string calldata key
    ) external view returns (uint256);

    function startBroadcast() external;

    function stopBroadcast() external;
}

contract SetupTopicExpiryScript {
    error MissingTopicKey();

    VmScript internal constant vm = VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (bytes32 topicId, bool createdTopic, bool updatedPrice, bool updatedExpiry) {
        address payable proxyAddress = payable(vm.envAddress("PROXY_ADDRESS"));
        address expiryUser = vm.envAddress("EXPIRY_USER");
        uint256 topicPriceWad = vm.envUint("TOPIC_PRICE_WAD");
        uint256 expiryTimestamp = vm.envUint("EXPIRY_TIMESTAMP");
        string memory topicKey = vm.envOr("TOPIC_KEY", string(""));

        if (bytes(topicKey).length == 0) {
            revert MissingTopicKey();
        }

        TopicAccessManagerUpgradeable manager = TopicAccessManagerUpgradeable(proxyAddress);
        topicId = keccak256(bytes(topicKey));

        vm.startBroadcast();

        if (!manager.topicExists(topicId)) {
            manager.createTopicByKey(topicKey, topicPriceWad);
            createdTopic = true;
        } else if (manager.getTopicPriceWad(topicId) != topicPriceWad) {
            manager.setTopicPrice(topicId, topicPriceWad);
            updatedPrice = true;
        }

        if (manager.getExpiry(topicId, expiryUser) != expiryTimestamp) {
            manager.setExpiry(topicId, expiryUser, expiryTimestamp);
            updatedExpiry = true;
        }

        vm.stopBroadcast();
    }
}
