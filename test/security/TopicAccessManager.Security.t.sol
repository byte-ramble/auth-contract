// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../base/TopicAccessFixture.sol";
import "../../src/mocks/ReentrantExecutorTarget.sol";

contract TopicAccessManagerSecurityTest is TopicAccessFixture {
    function testOnlyOwnerRestrictedFunctions() external {
        bytes32 topicId = _hashTopic("security.owner.only");

        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(attacker);
        manager.createTopic(topicId, 1e18);

        _createTopic(topicId, 1e18);

        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(attacker);
        manager.setTopicPrice(topicId, 2e18);

        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(attacker);
        manager.setWhitelist(topicId, user, true);

        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(attacker);
        manager.setRambleDiscountBps(9000);
    }

    function testPauseBlocksTopupAndUnpauseRecovers() external {
        bytes32 topicId = _hashTopic("security.pause");
        _createTopic(topicId, 100e18);

        _approveAndMint(address(usdc), user, 100e6);

        vm.prank(owner);
        manager.pause();

        vm.expectRevert(bytes("Pausable: paused"));
        vm.prank(user);
        manager.topup(topicId, address(usdc), 100e6, user);

        vm.prank(owner);
        manager.unpause();

        vm.prank(user);
        manager.topup(topicId, address(usdc), 100e6, user);

        assertTrue(manager.getExpiry(topicId, user) > block.timestamp, "expiry should be set after unpause");
    }

    function testOracleStaleRejectsBNBPath() external {
        bytes32 topicId = _hashTopic("security.oracle.stale");
        _createTopic(topicId, 100e18);

        uint256 nowTs = 10_000;
        vm.warp(nowTs);
        uint256 staleAt = nowTs - 3700;
        oracle.setLatestRoundData(2, int256(30_000_000_000), staleAt, staleAt, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.OraclePriceStale.selector, staleAt, nowTs, uint256(3600)
            )
        );
        vm.prank(user);
        manager.topup{ value: 1 ether }(topicId, address(0), 1 ether, user);
    }

    function testOracleRoundInvalidRejectsBNBPath() external {
        bytes32 topicId = _hashTopic("security.oracle.round.invalid");
        _createTopic(topicId, 100e18);

        oracle.setLatestRoundData(3, int256(30_000_000_000), block.timestamp, block.timestamp, 2);

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.OracleRoundInvalid.selector, uint80(3), uint80(2))
        );
        vm.prank(user);
        manager.topup{ value: 1 ether }(topicId, address(0), 1 ether, user);
    }

    function testPrivilegedCallRequiresExecutor() external {
        vm.expectRevert(abi.encodeWithSelector(TopicAccessManagerUpgradeable.NotExecutor.selector, attacker));
        vm.prank(attacker);
        manager.executePrivilegedCall(recipient, 0, "");
    }

    function testPrivilegedCallRejectsZeroAndSelfTarget() external {
        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.InvalidPrivilegedTarget.selector, address(0))
        );
        vm.prank(owner);
        manager.executePrivilegedCall(address(0), 0, "");

        vm.expectRevert(
            abi.encodeWithSelector(TopicAccessManagerUpgradeable.InvalidPrivilegedTarget.selector, address(manager))
        );
        vm.prank(owner);
        manager.executePrivilegedCall(address(manager), 0, "");
    }

    function testOwnerHasPrivilegedCallByDefault() external {
        uint256 value = 0.2 ether;
        vm.deal(address(manager), value);
        uint256 beforeBalance = recipient.balance;

        vm.prank(owner);
        (bool success,) = manager.executePrivilegedCall(recipient, value, "");

        assertEq(success, true, "owner privileged call should succeed");
        assertEq(recipient.balance - beforeBalance, value, "recipient should receive native token");
    }

    function testExecutorCanCallAfterOwnerConfiguresExecutors() external {
        (address configuredA, address configuredB) = manager.getExecutors();
        assertEq(configuredA, address(0), "executorA should default to zero");
        assertEq(configuredB, address(0), "executorB should default to zero");

        vm.prank(owner);
        manager.setExecutors(executorA, executorB);

        uint256 value = 0.2 ether;
        vm.deal(address(manager), value);
        uint256 beforeBalance = recipient.balance;

        vm.prank(executorA);
        (bool success,) = manager.executePrivilegedCall(recipient, value, "");

        assertEq(success, true, "configured executor call should succeed");
        assertEq(recipient.balance - beforeBalance, value, "recipient should receive native token");
    }

    function testReentrancyAttemptDuringPrivilegedCallFails() external {
        ReentrantExecutorTarget reentrant = new ReentrantExecutorTarget();

        vm.prank(owner);
        manager.setExecutors(executorA, address(reentrant));

        bytes memory attackData =
            abi.encodeCall(ReentrantExecutorTarget.reenter, (address(manager), recipient, bytes("")));

        vm.prank(executorA);
        (bool success,) = manager.executePrivilegedCall(address(reentrant), 0, attackData);

        assertFalse(success, "reentrant privileged call should fail");
    }
}
