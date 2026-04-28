// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IPancakePairV2
/// @notice Minimal subset of the PancakeSwap V2 pair interface consumed by `TopicAccessManagerUpgradeable`
///         to quote and execute the RAMBLE → WBNB swap on BSC.
interface IPancakePairV2 {
    /// @notice The pair's first token (sorted by address).
    function token0() external view returns (address);

    /// @notice The pair's second token.
    function token1() external view returns (address);

    /// @notice Returns current pool reserves and the last reserve-update timestamp.
    /// @return reserve0 Reserve of `token0`.
    /// @return reserve1 Reserve of `token1`.
    /// @return blockTimestampLast Truncated block timestamp of the last reserve update.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice Executes a pre-funded swap — the caller must have transferred the input token to the pair first.
    /// @param amount0Out Target output of `token0` (0 when swapping `token0 → token1`).
    /// @param amount1Out Target output of `token1` (0 when swapping `token1 → token0`).
    /// @param to Recipient of the output tokens.
    /// @param data Flash-swap callback payload; empty bytes for a plain swap.
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;
}
