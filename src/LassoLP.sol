// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ILpFarm {
    function onLpTransfer(address from, address to, uint256 amount) external;
}

/// @notice LP share of the Lasso counterparty pool. Minted/burned only by the Lasso core. Every balance change is
/// reported to the farm so holders earn $LASSO without staking.
contract LassoLP is ERC20 {
    address public immutable core;
    ILpFarm public immutable farm;

    error OnlyCore();

    constructor(address core_, ILpFarm farm_) ERC20("Lasso LP", "LLP") {
        core = core_;
        farm = farm_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != core) revert OnlyCore();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != core) revert OnlyCore();
        _burn(from, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        farm.onLpTransfer(from, to, value);
        super._update(from, to, value);
    }
}
