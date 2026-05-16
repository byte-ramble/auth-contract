// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../src/TopicAccessManagerUpgradeable.sol";
import "../../src/mocks/TestERC1967Proxy.sol";
import "../base/TestBase.sol";

contract TopicAccessManagerForkTest is TestBase {
    uint256 private constant ONE_MONTH = 30 days;

    address private constant WETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address private constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address private constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;

    address private constant BNB_USD_ORACLE = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address private constant ETH_USD_ORACLE = 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e;
    address private constant BTC_USD_ORACLE = 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf;
    address private constant USDT_USD_ORACLE = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    address private constant USDC_USD_ORACLE = 0x51597f405303C4377E36123cBc172b13269EA163;

    address private owner = address(0x1001);
    address private user = address(0x1002);

    bytes32 private constant TOPIC_ID = keccak256("fork.real.tokens.vip");

    TopicAccessManagerUpgradeable private manager;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            return;
        }

        vm.createSelectFork(rpcUrl);
        vm.deal(owner, 100 ether);
        vm.deal(user, 100 ether);

        TopicAccessManagerUpgradeable implementation = new TopicAccessManagerUpgradeable();
        bytes memory initData = abi.encodeCall(TopicAccessManagerUpgradeable.initialize, (owner, BNB_USD_ORACLE, 3600));

        TestERC1967Proxy proxy = new TestERC1967Proxy(address(implementation), initData);
        manager = TopicAccessManagerUpgradeable(payable(address(proxy)));

        vm.startPrank(owner);
        manager.setPaymentToken(WETH, true, ETH_USD_ORACLE);
        manager.setPaymentToken(USDT, true, USDT_USD_ORACLE);
        manager.setPaymentToken(USDC, true, USDC_USD_ORACLE);
        manager.setPaymentToken(WBNB, true, BNB_USD_ORACLE);
        manager.setPaymentToken(BTCB, true, BTC_USD_ORACLE);
        manager.createTopicByKey("fork.real.tokens.vip", 100e18);
        vm.stopPrank();
    }

    function testBscForkQuotesConfiguredRealTokens() external {
        if (address(manager) == address(0)) {
            return;
        }

        _assertQuoteCoversTopicPrice(WETH);
        _assertQuoteCoversTopicPrice(USDT);
        _assertQuoteCoversTopicPrice(USDC);
        _assertQuoteCoversTopicPrice(WBNB);
        _assertQuoteCoversTopicPrice(BTCB);
    }

    function testBscForkTopicTrialBlocksThenAllowsRealBnbTopup() external {
        if (address(manager) == address(0)) {
            return;
        }

        uint256 trialEndsAt = block.timestamp + 1;

        vm.prank(owner);
        manager.setTopicTrialEndsAt(TOPIC_ID, trialEndsAt);

        assertEq(manager.hasAccess(TOPIC_ID, user), true, "trial should grant access on fork");

        vm.expectRevert(
            abi.encodeWithSelector(
                TopicAccessManagerUpgradeable.TrialPeriodNoPaymentRequired.selector, TOPIC_ID, trialEndsAt
            )
        );
        vm.prank(user);
        manager.topup(TOPIC_ID, WETH, 1e18, user);

        vm.warp(trialEndsAt + 1);

        uint256 minQuote = manager.quoteMinBnbForOneMonth(TOPIC_ID);
        uint256 minEffectiveValueWad = manager.getTopicPriceWad(TOPIC_ID);
        vm.prank(user);
        uint256 newExpiry = manager.topup{ value: minQuote }(
            TOPIC_ID, address(0), minQuote, user, minEffectiveValueWad, block.timestamp
        );

        assertGte(newExpiry, block.timestamp + ONE_MONTH, "real BNB topup should extend expiry");
    }

    function _assertQuoteCoversTopicPrice(
        address token
    ) internal view {
        uint256 minQuote = manager.quoteMinTokenForOneMonth(TOPIC_ID, token);
        assertTrue(minQuote > 0, "fork quote should be positive");

        (, uint256 effectiveValueWad,) = manager.previewTopup(TOPIC_ID, token, minQuote);
        assertGte(effectiveValueWad, manager.getTopicPriceWad(TOPIC_ID), "fork quote should cover topic price");
    }
}
