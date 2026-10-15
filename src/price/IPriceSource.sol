// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice USD price (1e18) of a collateral token.
interface IPriceSource {
    function price() external view returns (uint256 priceUsd, uint256 updatedAt);
}
