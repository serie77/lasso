// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Hooke's stock price oracle. One feed per tokenized stock (feedId from app.hooke.fun/v1/protocol).
/// Storage-verified layout on Robinhood Chain: (price 1e18, sourceTime, publishTime, marketOpen, validUntil, publisher).
interface IHookeOracleRegistry {
    function latestPrice(bytes32 feedId)
        external
        view
        returns (
            uint256 price,
            uint64 sourceTime,
            uint64 publishTime,
            bool marketOpen,
            uint64 validUntil,
            address publisher
        );
}

/// @notice Hooke's dynamic-tax fee hook on the stock-token / USDG Uniswap V4 pool.
/// Exposes the whole Hooke mechanism in one call: pool price vs oracle price, deviation, current buy/sell tax.
interface IHookeFeeHook {
    function currentState()
        external
        view
        returns (
            uint256 poolPrice,
            uint256 oraclePrice,
            int256 deviation,
            uint256 buyFeePpm,
            uint256 sellFeePpm,
            bool marketOpen,
            bool oracleHealthy
        );

    /// @notice Time-weighted mean tick of the pool over `window` seconds (Hooke keeps its own observations).
    function consultMeanTick(uint32 window) external view returns (int24);

    /// @notice True when the stock token is currency0 of the pool (USDG is the other side).
    function tokenIsCurrency0() external view returns (bool);
}

/// @notice Minimal Uniswap V4 PoolManager surface used for reading pool state.
interface IPoolManagerExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}
