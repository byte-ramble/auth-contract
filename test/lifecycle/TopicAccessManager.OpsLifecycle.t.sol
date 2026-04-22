// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../base/TopicAccessFixture.sol";
import "../../src/mocks/TopicAccessManagerLegacySeeder.sol";
import "../../src/mocks/TopicAccessManagerUpgradeableV2.sol";

contract TopicAccessManagerOpsLifecycleTest is TopicAccessFixture {
    uint256 private constant PAID_MONTHLY_PRICE_WAD = 180e18;

    function testOpsLifecycleCoversDeployRunPauseUpgradeAndMigrate() external {
        bytes32 paidTopicId = _hashTopic("ops.lifecycle.paid");
        bytes32 freeTopicId = _hashTopic("ops.lifecycle.free");

        _configureExecutorAndTopics(paidTopicId, freeTopicId);
        uint256 expiryAfterUsdc = _runStableAndFreeTopicChecks(paidTopicId, freeTopicId);
        uint256 expiryAfterRamble = _runPauseAndMultiTokenTopups(paidTopicId, expiryAfterUsdc);
        _runPrivilegedCallFlow();
        _runUpgradeAndMigrationFlow(paidTopicId, expiryAfterRamble);
    }

    function _configureExecutorAndTopics(
        bytes32 paidTopicId,
        bytes32 freeTopicId
    ) internal {
        vm.prank(owner);
        manager.setExecutor(executor);

        assertEq(manager.getExecutor(), executor, "executor should be set");

        _createTopic(paidTopicId, PAID_MONTHLY_PRICE_WAD);
        _createTopic(freeTopicId, 0);

        assertTrue(manager.hasAccess(freeTopicId, user), "free topic should be accessible");
        assertFalse(manager.hasAccess(paidTopicId, user), "paid topic should require topup");
    }

    function _runStableAndFreeTopicChecks(
        bytes32 paidTopicId,
        bytes32 freeTopicId
    ) internal returns (uint256 expiryAfterUsdc) {
        _approveAndMint(address(usdc), user, 180e6);

        vm.prank(user);
        manager.topup(paidTopicId, address(usdc), 180e6, user);

        expiryAfterUsdc = manager.getExpiry(paidTopicId, user);
        assertTrue(expiryAfterUsdc > block.timestamp, "expiry should be set after stable topup");

        _approveAndMint(address(usdc), user, 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.FreeTopicNoPaymentRequired.selector, freeTopicId)
        );
        vm.prank(user);
        manager.topup(freeTopicId, address(usdc), 1e6, user);
    }

    function _runPauseAndMultiTokenTopups(
        bytes32 paidTopicId,
        uint256 expiryAfterUsdc
    ) internal returns (uint256 expiryAfterRamble) {
        vm.prank(owner);
        manager.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(user);
        manager.topup{ value: 1 ether }(paidTopicId, address(0), 1 ether, user);

        vm.prank(owner);
        manager.unpause();

        vm.prank(user);
        manager.topup{ value: 1 ether }(paidTopicId, address(0), 1 ether, user);

        uint256 expiryAfterBnb = manager.getExpiry(paidTopicId, user);
        assertTrue(expiryAfterBnb > expiryAfterUsdc, "bnb topup should increase expiry");

        _approveAndMint(address(ramble), user, 200e18);
        vm.prank(user);
        manager.topup(paidTopicId, address(ramble), 200e18, user, 1, block.timestamp + 1 hours);

        expiryAfterRamble = manager.getExpiry(paidTopicId, user);
        assertTrue(expiryAfterRamble > expiryAfterBnb, "ramble topup should increase expiry");
    }

    function _runPrivilegedCallFlow() internal {
        vm.deal(address(manager), 0.15 ether);
        usdc.mint(address(manager), 25e6);
        uint256 beforeRecipientBalance = recipient.balance;
        uint256 beforeRecipientUsdcBalance = usdc.balanceOf(recipient);

        vm.prank(executor);
        manager.withdrawNative(recipient, 0.15 ether);

        assertEq(recipient.balance - beforeRecipientBalance, 0.15 ether, "recipient should receive native token");

        vm.prank(executor);
        manager.withdrawERC20(address(usdc), recipient, 25e6);

        assertEq(usdc.balanceOf(recipient) - beforeRecipientUsdcBalance, 25e6, "recipient should receive usdc");
    }

    function _runUpgradeAndMigrationFlow(
        bytes32 paidTopicId,
        uint256 expectedExpiryBeforeUpgrade
    ) internal {
        vm.startPrank(owner);
        manager.setStableToken(address(usdc), false);
        manager.setStableToken(address(usdt), false);
        vm.stopPrank();

        (bool usdcEnabledBefore,) = manager.getStableTokenConfig(address(usdc));
        (bool usdtEnabledBefore,) = manager.getStableTokenConfig(address(usdt));
        assertFalse(usdcEnabledBefore, "usdc should be disabled before migration");
        assertFalse(usdtEnabledBefore, "usdt should be disabled before migration");

        TopicAccessManagerLegacySeeder seederImplementation = new TopicAccessManagerLegacySeeder();
        vm.prank(owner);
        manager.upgradeToAndCall(address(seederImplementation), "");

        TopicAccessManagerLegacySeeder seeded = TopicAccessManagerLegacySeeder(payable(address(manager)));
        vm.prank(owner);
        seeded.seedLegacyStableTokens(address(usdc), address(usdt));

        (address seededUsdc, address seededUsdt) = seeded.getLegacyStableTokens();
        assertEq(seededUsdc, address(usdc), "legacy usdc should be seeded before migration");
        assertEq(seededUsdt, address(usdt), "legacy usdt should be seeded before migration");

        TopicAccessManagerUpgradeableV2 newImplementation = new TopicAccessManagerUpgradeableV2();
        vm.prank(owner);
        seeded.upgradeToAndCall(address(newImplementation), "");

        TopicAccessManagerUpgradeableV2 upgraded = TopicAccessManagerUpgradeableV2(payable(address(manager)));
        assertEq(upgraded.version(), 2, "should upgrade to v2");
        assertTrue(upgraded.topicExists(paidTopicId), "topic should remain after upgrade");
        assertEq(
            upgraded.getExpiry(paidTopicId, user), expectedExpiryBeforeUpgrade, "expiry should remain after upgrade"
        );

        (address legacyUsdc, address legacyUsdt) = upgraded.getLegacyStableTokens();
        assertEq(legacyUsdc, address(usdc), "legacy usdc should be readable");
        assertEq(legacyUsdt, address(usdt), "legacy usdt should be readable");

        vm.startPrank(owner);
        _enableLegacyStableIfNeeded(upgraded, legacyUsdc);
        if (legacyUsdt != legacyUsdc) {
            _enableLegacyStableIfNeeded(upgraded, legacyUsdt);
        }
        vm.stopPrank();

        (bool usdcEnabledAfter,) = upgraded.getStableTokenConfig(address(usdc));
        (bool usdtEnabledAfter,) = upgraded.getStableTokenConfig(address(usdt));
        assertTrue(usdcEnabledAfter, "usdc should be enabled after migration");
        assertTrue(usdtEnabledAfter, "usdt should be enabled after migration");

        _approveAndMint(address(usdt), user, 180e18);
        vm.prank(user);
        upgraded.topup(paidTopicId, address(usdt), 180e18, user);

        uint256 expiryAfterUpgradeTopup = upgraded.getExpiry(paidTopicId, user);
        assertTrue(expiryAfterUpgradeTopup > expectedExpiryBeforeUpgrade, "topup should continue after upgrade");
        assertTrue(upgraded.hasAccess(paidTopicId, user), "access should remain valid");
    }

    function _enableLegacyStableIfNeeded(
        TopicAccessManagerUpgradeableV2 upgraded,
        address token
    ) internal {
        if (token == address(0) || token == upgraded.RAMBLE_TOKEN() || token.code.length == 0) {
            return;
        }

        (bool enabled,) = upgraded.getStableTokenConfig(token);
        if (!enabled) {
            upgraded.setStableToken(token, true);
        }
    }
}
