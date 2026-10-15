// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Lasso} from "../src/Lasso.sol";
import {HookePriceAdapter} from "../src/HookePriceAdapter.sol";

/// @notice Lists a new Hooke stock as two markets (share + token), same risk settings as XMAX/hXMAX.
/// env: PRIVATE_KEY, LASSO, TICKER (e.g. XMAX), FEED_ID (from app.hooke.fun/v1/protocol), FEE_HOOK (the stock's fee hook)
contract AddStock is Script {
    function run() external {
        Lasso lasso = Lasso(payable(vm.envAddress("LASSO")));
        string memory ticker = vm.envString("TICKER");
        bytes32 feedId = vm.envBytes32("FEED_ID");
        address feeHook = vm.envAddress("FEE_HOOK");
        uint128 borrowRate = uint128(1e18 / uint256(365 days));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        uint16 share = lasso.addMarket(
            Lasso.MarketConfig({
                name: ticker,
                price: HookePriceAdapter.PriceConfig(HookePriceAdapter.Source.ORACLE, feedId, feeHook, 0, 18, 6),
                active: true,
                allowIncreaseWhenClosed: false,
                closedSpreadBps: 50,
                maxLeverageX: 10,
                maintenanceBps: 100,
                openFeeBps: 10,
                closeFeeBps: 10,
                tensionFeeMaxBps: 50,
                maxOiUsd: 1_000_000e18,
                borrowRatePerSec: borrowRate
            })
        );
        uint16 token = lasso.addMarket(
            Lasso.MarketConfig({
                name: string.concat("h", ticker),
                price: HookePriceAdapter.PriceConfig(HookePriceAdapter.Source.POOL, bytes32(0), feeHook, 30 minutes, 18, 6),
                active: true,
                allowIncreaseWhenClosed: true,
                closedSpreadBps: 0,
                maxLeverageX: 5,
                maintenanceBps: 200,
                openFeeBps: 10,
                closeFeeBps: 10,
                tensionFeeMaxBps: 50,
                maxOiUsd: 100_000e18,
                borrowRatePerSec: borrowRate
            })
        );
        vm.stopBroadcast();

        // both prices must resolve before anyone trades them
        (uint256 p0,) = lasso.markPrice(share);
        (uint256 p1,) = lasso.markPrice(token);
        console.log(ticker, "share market", share, p0);
        console.log(ticker, "token market", token, p1);
    }
}
