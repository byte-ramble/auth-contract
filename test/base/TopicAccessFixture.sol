// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../src/TopicAccessManagerUpgradeable.sol";
import "../../src/mocks/MockERC20.sol";
import "../../src/mocks/MockAggregatorV3.sol";
import "../../src/mocks/MockPancakePairV2.sol";
import "../../src/mocks/MockWBNB.sol";
import "../../src/mocks/TestERC1967Proxy.sol";
import "../../src/mocks/WadScaleHarness.sol";
import "./TestBase.sol";

abstract contract TopicAccessFixture is TestBase {
    uint256 internal constant ONE_MONTH = 30 days;
    address internal constant RAMBLE_TOKEN = 0x1A8C391f6c603894108fcE14A52E9Bf804c67777;

    address internal owner = address(0x1001);
    address internal user = address(0x1002);
    address internal user2 = address(0x1003);
    address internal executorA = address(0x1004);
    address internal executorB = address(0x1005);
    address internal recipient = address(0x1006);
    address internal attacker = address(0x1007);

    TopicAccessManagerUpgradeable internal manager;
    TopicAccessManagerUpgradeable internal implementation;

    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockERC20 internal ramble;
    MockWBNB internal wbnb;
    MockERC20 internal usdc24;

    MockAggregatorV3 internal oracle;
    MockPancakePairV2 internal pair;

    WadScaleHarness internal wadHarness;

    function setUp() public virtual {
        vm.chainId(56);

        vm.deal(owner, 100 ether);
        vm.deal(user, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(executorA, 100 ether);
        vm.deal(executorB, 100 ether);
        vm.deal(attacker, 100 ether);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether", "USDT", 18);
        MockERC20 rambleTemplate = new MockERC20("Ramble", "RAMBLE", 18);
        vm.etch(RAMBLE_TOKEN, address(rambleTemplate).code);
        ramble = MockERC20(RAMBLE_TOKEN);
        wbnb = new MockWBNB();
        usdc24 = new MockERC20("USD24", "USD24", 24);

        oracle = new MockAggregatorV3(8);
        oracle.setLatestRoundData(1, int256(30_000_000_000), block.timestamp, block.timestamp, 1); // 300 USD

        pair = new MockPancakePairV2(address(ramble), address(wbnb));
        uint112 reserveRamble = uint112(1_000_000e18);
        uint112 reserveWbnb = uint112(10_000e18);
        pair.setReserves(reserveRamble, reserveWbnb, uint32(block.timestamp));
        ramble.mint(address(pair), reserveRamble);
        wbnb.mint(address(pair), reserveWbnb);
        vm.deal(address(wbnb), 100_000 ether);

        implementation = new TopicAccessManagerUpgradeable();
        bytes memory initData = abi.encodeCall(TopicAccessManagerUpgradeable.initialize, (owner, address(oracle), 3600));

        TestERC1967Proxy proxy = new TestERC1967Proxy(address(implementation), initData);
        manager = TopicAccessManagerUpgradeable(payable(address(proxy)));

        vm.startPrank(owner);
        manager.setStableToken(address(usdc), true);
        manager.setStableToken(address(usdt), true);
        manager.setRamblePair(address(pair));
        vm.stopPrank();

        wadHarness = new WadScaleHarness();
    }

    function _createTopic(
        bytes32 topicId,
        uint256 priceWad
    ) internal {
        vm.prank(owner);
        manager.createTopic(topicId, priceWad);
    }

    function _approveAndMint(
        address token,
        address to,
        uint256 amount
    ) internal {
        MockERC20(token).mint(to, amount);
        vm.prank(to);
        MockERC20(token).approve(address(manager), amount);
    }

    function _hashTopic(
        string memory topicKey
    ) internal pure returns (bytes32) {
        return keccak256(bytes(topicKey));
    }
}
