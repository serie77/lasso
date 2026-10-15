// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceSource} from "./IPriceSource.sol";
import {IPoolManagerExtsload} from "../interfaces/IHooke.sol";

/// @notice Keeper-posted USD price with staleness and an optional on-chain sanity band against a Uniswap V4 pool.
/// Used for ETH collateral: Robinhood Chain has no ETH/USD oracle and the ETH/USDG V4 pool is thin, so the
/// keeper posts an exchange price and the contract refuses posts that stray too far from the pool.
contract PostedPriceSource is IPriceSource, Ownable2Step {
    uint256 private constant POOLS_SLOT = 6; // PoolManager `_pools` mapping slot

    IPoolManagerExtsload public immutable poolManager;
    bytes32 public immutable poolId;
    bool public immutable tokenIsCurrency0;
    uint8 public immutable tokenDecimals;
    uint8 public immutable quoteDecimals;

    uint256 public maxAge; // seconds a posted price stays valid
    uint256 public bandBps; // max deviation from pool spot, 0 disables the check
    mapping(address => bool) public posters;

    uint256 public lastPrice;
    uint256 public lastUpdate;

    event PricePosted(uint256 price, uint256 poolPrice, uint256 at);
    event PosterSet(address indexed poster, bool allowed);
    event ParamsSet(uint256 maxAge, uint256 bandBps);

    error NotPoster();
    error OutOfBand(uint256 posted, uint256 pool);
    error Stale();
    error ZeroPrice();

    constructor(
        address owner_,
        IPoolManagerExtsload poolManager_,
        bytes32 poolId_,
        bool tokenIsCurrency0_,
        uint8 tokenDecimals_,
        uint8 quoteDecimals_,
        uint256 maxAge_,
        uint256 bandBps_
    ) Ownable(owner_) {
        poolManager = poolManager_;
        poolId = poolId_;
        tokenIsCurrency0 = tokenIsCurrency0_;
        tokenDecimals = tokenDecimals_;
        quoteDecimals = quoteDecimals_;
        maxAge = maxAge_;
        bandBps = bandBps_;
    }

    function setPoster(address poster, bool allowed) external onlyOwner {
        posters[poster] = allowed;
        emit PosterSet(poster, allowed);
    }

    function setParams(uint256 maxAge_, uint256 bandBps_) external onlyOwner {
        maxAge = maxAge_;
        bandBps = bandBps_;
        emit ParamsSet(maxAge_, bandBps_);
    }

    function post(uint256 priceUsd) external {
        if (!posters[msg.sender]) revert NotPoster();
        if (priceUsd == 0) revert ZeroPrice();
        uint256 pool = 0;
        if (bandBps != 0) {
            pool = poolSpotPrice();
            uint256 diff = priceUsd > pool ? priceUsd - pool : pool - priceUsd;
            if (diff * 10_000 > pool * bandBps) revert OutOfBand(priceUsd, pool);
        }
        lastPrice = priceUsd;
        lastUpdate = block.timestamp;
        emit PricePosted(priceUsd, pool, block.timestamp);
    }

    function price() external view returns (uint256, uint256) {
        if (lastPrice == 0 || block.timestamp > lastUpdate + maxAge) revert Stale();
        return (lastPrice, lastUpdate);
    }

    /// @notice Spot price of the token in quote units (1e18) read straight from PoolManager storage.
    function poolSpotPrice() public view returns (uint256) {
        bytes32 slot0 = poolManager.extsload(keccak256(abi.encodePacked(poolId, POOLS_SLOT)));
        uint256 sqrtPriceX96 = uint256(slot0) & ((1 << 160) - 1);
        // ratio = token1 per token0, scaled by 2^96
        uint256 ratioX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        if (tokenIsCurrency0) {
            // price = ratio * 10^(dec0 - dec1)
            return Math.mulDiv(ratioX96, 1e18 * 10 ** tokenDecimals, (1 << 96) * 10 ** quoteDecimals);
        }
        return Math.mulDiv(1e18 * 10 ** tokenDecimals, 1 << 96, ratioX96 * 10 ** quoteDecimals);
    }
}
