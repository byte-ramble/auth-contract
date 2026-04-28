// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/Math.sol";

library TopicAccessPolicyLib {
    function hasAccess(
        bool topicExists,
        bool isWhitelisted,
        uint256 trialEndsAt,
        uint256 monthlyPriceWad,
        uint256 expiry,
        uint256 nowTimestamp
    ) internal pure returns (bool) {
        if (!topicExists) {
            return false;
        }
        if (isWhitelisted) {
            return true;
        }
        if (trialEndsAt > nowTimestamp) {
            return true;
        }
        if (monthlyPriceWad == 0) {
            return true;
        }

        return expiry >= nowTimestamp;
    }

    function isNoPaymentRequired(
        uint256 monthlyPriceWad,
        uint256 trialEndsAt,
        uint256 nowTimestamp
    ) internal pure returns (bool) {
        return monthlyPriceWad == 0 || trialEndsAt > nowTimestamp;
    }

    function effectiveTrialEndsAt(
        uint256 globalTrialEndsAt,
        uint256 topicTrialEndsAt
    ) internal pure returns (uint256) {
        return Math.max(globalTrialEndsAt, topicTrialEndsAt);
    }

    function isTopicPaymentTokenAllowed(
        bool allowlistEnabled,
        bool payTokenAllowed
    ) internal pure returns (bool) {
        return !allowlistEnabled || payTokenAllowed;
    }

    function computeNewExpiry(
        uint256 oldExpiry,
        uint256 nowTimestamp,
        uint256 effectiveValueWad,
        uint256 oneMonth,
        uint256 monthlyPriceWad
    ) internal pure returns (uint256 newExpiry, uint256 secondsAdded) {
        secondsAdded = Math.mulDiv(effectiveValueWad, oneMonth, monthlyPriceWad);
        newExpiry = Math.max(oldExpiry, nowTimestamp) + secondsAdded;
    }

    function extendExpiry(
        uint256 oldExpiry,
        uint256 nowTimestamp,
        uint256 durationSeconds
    ) internal pure returns (uint256 newExpiry) {
        newExpiry = Math.max(oldExpiry, nowTimestamp) + durationSeconds;
    }
}
