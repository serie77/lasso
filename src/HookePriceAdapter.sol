// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookeOracleRegistry, IHookeFeeHook} from "./interfaces/IHooke.sol";
import {TickMath} from "./lib/TickMath.sol";

/// @notice Prices perp markets straight off Hooke's two prices for every tokenized stock:
///  - ORACLE: the stock's reference price from HookeOracleRegistry (what the real share trades at).
///  - POOL:   the onchain stock-token price from the Hooke fee hook (spot vs Hooke's own TWAP, worse one for the trader).
/// Shorting POOL and longing ORACLE on the same stock is a pure trade on the token's premium to the share.
contract HookePriceAdapter {
    enum Source {
        ORACLE,
        POOL
    }

    struct PriceConfig {
        Source source;
        bytes32 feedId; // ORACLE
        address feeHook; // POOL (also gives marketOpen for ORACLE markets if set)
        uint32 twapWindow; // POOL
        uint8 tokenDecimals; // POOL
        uint8 quoteDecimals; // POOL
    }

    IHookeOracleRegistry public immutable registry;
    uint256 public immutable staleGrace; // seconds past validUntil we still accept an oracle price

    error StalePrice();
    error ZeroPrice();

    constructor(IHookeOracleRegistry registry_, uint256 staleGrace_) {
        registry = registry_;
        staleGrace = staleGrace_;
    }

    /// @param maximize true returns the higher of the available prices (used against longs opening / shorts closing)
    function quote(PriceConfig memory cfg, bool maximize)
        external
        view
        returns (uint256 price, uint64 publishTime, bool marketOpen)
    {
        if (cfg.source == Source.ORACLE) {
            (uint256 p,, uint64 pub, bool open, uint64 validUntil,) = registry.latestPrice(cfg.feedId);
            if (p == 0) revert ZeroPrice();
            if (block.timestamp > uint256(validUntil) + staleGrace) revert StalePrice();
            return (p, pub, open);
        }

        IHookeFeeHook hook = IHookeFeeHook(cfg.feeHook);
        (uint256 spot,,,,,,) = hook.currentState();
        uint256 twap = tickToPrice(hook.consultMeanTick(cfg.twapWindow), hook.tokenIsCurrency0(), cfg.tokenDecimals, cfg.quoteDecimals);
        if (spot == 0 || twap == 0) revert ZeroPrice();
        price = maximize ? Math.max(spot, twap) : Math.min(spot, twap);
        return (price, uint64(block.timestamp), true);
    }

    /// @notice Mark price for valuation and display: the oracle price, or the pool spot for POOL markets.
    function mid(PriceConfig memory cfg) external view returns (uint256 price, bool marketOpen) {
        if (cfg.source == Source.ORACLE) {
            (uint256 p,,, bool open, uint64 validUntil,) = registry.latestPrice(cfg.feedId);
            if (p == 0) revert ZeroPrice();
            if (block.timestamp > uint256(validUntil) + staleGrace) revert StalePrice();
            return (p, open);
        }
        (uint256 spot,,,,,,) = IHookeFeeHook(cfg.feeHook).currentState();
        if (spot == 0) revert ZeroPrice();
        return (spot, true);
    }

    /// @notice Hooke's own view of the stock: pool price, oracle price, deviation and the current tax.
    function hookeState(address feeHook)
        external
        view
        returns (uint256 poolPrice, uint256 oraclePrice, int256 deviation, uint256 buyFeePpm, uint256 sellFeePpm, bool marketOpen)
    {
        (poolPrice, oraclePrice, deviation, buyFeePpm, sellFeePpm, marketOpen,) = IHookeFeeHook(feeHook).currentState();
    }

    /// @notice Price of the stock token in quote units (1e18) from a pool tick.
    function tickToPrice(int24 tick, bool tokenIsCurrency0, uint8 tokenDecimals, uint8 quoteDecimals)
        public
        pure
        returns (uint256)
    {
        uint256 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 ratioX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96); // token1 per token0, X96
        if (tokenIsCurrency0) {
            return Math.mulDiv(ratioX96, 1e18 * 10 ** tokenDecimals, (1 << 96) * 10 ** quoteDecimals);
        }
        return Math.mulDiv(1e18 * 10 ** tokenDecimals, 1 << 96, ratioX96 * 10 ** quoteDecimals);
    }
}
