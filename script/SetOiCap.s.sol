// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Lasso} from "../src/Lasso.sol";

/// @notice Changes one market's per-side open-interest cap. env: PRIVATE_KEY, LASSO, MARKET, MAX_OI_USD (whole dollars)
contract SetOiCap is Script {
    function run() external {
        Lasso lasso = Lasso(payable(vm.envAddress("LASSO")));
        uint16 id = uint16(vm.envUint("MARKET"));
        Lasso.MarketConfig memory cfg = lasso.getMarketConfig(id);
        console.log(cfg.name, "maxOiUsd", cfg.maxOiUsd / 1e18, "->");
        cfg.maxOiUsd = uint128(vm.envUint("MAX_OI_USD") * 1e18);
        console.log(cfg.maxOiUsd / 1e18);
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        lasso.updateMarket(id, cfg);
        vm.stopBroadcast();
    }
}
