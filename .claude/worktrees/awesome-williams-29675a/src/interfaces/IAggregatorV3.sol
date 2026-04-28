// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IAggregatorV3
/// @notice Minimal subset of the Chainlink AggregatorV3 interface used by `TopicAccessManagerUpgradeable`
///         to price native BNB and ERC20 payment tokens in USD.
interface IAggregatorV3 {
    /// @notice Number of decimals used by `latestRoundData().answer`.
    function decimals() external view returns (uint8);

    /// @notice Returns the most recent round's data.
    /// @return roundId Current round id.
    /// @return answer The reported price (scaled by `decimals()`). Validated to be positive by callers.
    /// @return startedAt Timestamp the round was opened.
    /// @return updatedAt Timestamp the round was last updated — used for staleness checks.
    /// @return answeredInRound Round in which the answer was actually computed; must be `>= roundId`.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
