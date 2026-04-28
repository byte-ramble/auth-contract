// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TopicAccessPolicyLib
/// @notice Pure access / expiry policy helpers extracted from `TopicAccessManagerUpgradeable`.
/// @dev Stateless; all functions are `pure`. Keeping the policy here makes the rules easy to reason about
///      and unit-test in isolation. See `docs/design/architecture.md` §5 for the canonical `hasAccess` ladder.
library TopicAccessPolicyLib {
    /// @notice Canonical `hasAccess` evaluation used by the manager contract.
    /// @dev Order (first match wins): missing topic → false, whitelisted → true, trial active → true,
    ///      free topic → true, paid-and-not-expired → true, else false.
    /// @param topicExists Whether the topic is registered.
    /// @param isWhitelisted Whether the user is whitelisted for this topic.
    /// @param trialEndsAt Effective trial cutoff (topic-level overriding global).
    /// @param monthlyPriceWad Topic's monthly price in WAD.
    /// @param expiry The user's paid expiry timestamp (seconds).
    /// @param nowTimestamp Current block timestamp.
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

    /// @notice Returns true when no payment is required (free topic or active trial).
    /// @dev Used by quote / preview helpers to short-circuit before touching oracles.
    function isNoPaymentRequired(
        uint256 monthlyPriceWad,
        uint256 trialEndsAt,
        uint256 nowTimestamp
    ) internal pure returns (bool) {
        return monthlyPriceWad == 0 || trialEndsAt > nowTimestamp;
    }

    /// @notice Collapses (global, topic-level) trial cutoffs into a single effective timestamp.
    /// @dev Takes `max` so a topic can extend — but never shorten — the global trial.
    function effectiveTrialEndsAt(
        uint256 globalTrialEndsAt,
        uint256 topicTrialEndsAt
    ) internal pure returns (uint256) {
        return Math.max(globalTrialEndsAt, topicTrialEndsAt);
    }

    /// @notice Returns whether `payTokenAllowed` is sufficient given the current allowlist mode.
    /// @dev When the allowlist is disabled, any token is allowed; when enabled, only explicitly allowed ones.
    function isTopicPaymentTokenAllowed(
        bool allowlistEnabled,
        bool payTokenAllowed
    ) internal pure returns (bool) {
        return !allowlistEnabled || payTokenAllowed;
    }

    /// @notice Computes a new expiry from an effective WAD value and the topic's monthly price.
    /// @dev `secondsAdded = effectiveValueWad * oneMonth / monthlyPriceWad` (rounded down).
    ///      `newExpiry = max(oldExpiry, now) + secondsAdded` — ensures renewals past an already-active expiry
    ///      extend forward, while brand-new subscriptions start from `now`.
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

    /// @notice Returns `max(oldExpiry, now) + durationSeconds`; the extension primitive used by `extendExpiry`.
    function extendExpiry(
        uint256 oldExpiry,
        uint256 nowTimestamp,
        uint256 durationSeconds
    ) internal pure returns (uint256 newExpiry) {
        newExpiry = Math.max(oldExpiry, nowTimestamp) + durationSeconds;
    }
}
