// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPriceSource} from "./IPriceSource.sol";

/// @notice Constant price, used for the USDG stablecoin ($1).
contract FixedPriceSource is IPriceSource {
    uint256 public immutable fixedPrice;

    constructor(uint256 fixedPrice_) {
        fixedPrice = fixedPrice_;
    }

    function price() external view returns (uint256, uint256) {
        return (fixedPrice, block.timestamp);
    }
}
