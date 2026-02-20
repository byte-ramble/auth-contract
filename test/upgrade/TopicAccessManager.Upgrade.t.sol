// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../base/TopicAccessFixture.sol";
import "../../src/mocks/TopicAccessManagerUpgradeableV2.sol";

contract TopicAccessManagerUpgradeTest is TopicAccessFixture {
    function testOwnerUpgradePreservesState() external {
        bytes32 topicId = _hashTopic("upgrade.state");
        _createTopic(topicId, 100e18);

        vm.prank(owner);
        manager.setWhitelist(topicId, user2, true);

        _approveAndMint(address(usdc), user, 100e6);

        vm.prank(user);
        manager.topup(topicId, address(usdc), 100e6, user);

        uint256 oldExpiry = manager.getExpiry(topicId, user);
        bool oldWhitelist = manager.isWhitelisted(topicId, user2);

        TopicAccessManagerUpgradeableV2 newImplementation = new TopicAccessManagerUpgradeableV2();

        vm.prank(owner);
        manager.upgradeTo(address(newImplementation));

        TopicAccessManagerUpgradeableV2 upgraded = TopicAccessManagerUpgradeableV2(payable(address(manager)));

        assertEq(upgraded.topicExists(topicId), true, "topic should remain");
        assertEq(upgraded.getTopicPriceWad(topicId), 100e18, "price should remain");
        assertEq(upgraded.getExpiry(topicId, user), oldExpiry, "expiry should remain");
        assertEq(upgraded.isWhitelisted(topicId, user2), oldWhitelist, "whitelist should remain");
        assertEq(upgraded.hasAccess(topicId, user2), true, "whitelisted access should remain");
        assertEq(upgraded.version(), 2, "version should be v2");

        vm.prank(owner);
        upgraded.setV2Flag(777);
        assertEq(upgraded.v2Flag(), 777, "new state should work");
    }

    function testNonOwnerCannotUpgrade() external {
        TopicAccessManagerUpgradeableV2 newImplementation = new TopicAccessManagerUpgradeableV2();

        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(attacker);
        manager.upgradeTo(address(newImplementation));
    }
}
