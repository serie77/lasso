// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";
import {Lasso} from "../src/Lasso.sol";
import {LassoFarm} from "../src/LassoFarm.sol";
import {HookePriceAdapter} from "../src/HookePriceAdapter.sol";
import {FixedPriceSource} from "../src/price/FixedPriceSource.sol";
import {PostedPriceSource} from "../src/price/PostedPriceSource.sol";
import {IHookeOracleRegistry, IPoolManagerExtsload} from "../src/interfaces/IHooke.sol";
import {IPriceSource} from "../src/price/IPriceSource.sol";

/// @notice Deploys Lasso + LassoFarm with the XMAX (oracle) and hXMAX (pool) markets. USDG collateral only on
/// mainnet: LP withdrawals then never depend on a keeper-posted price.
/// env: PRIVATE_KEY, KEEPER (address), TREASURY (address); both default to the deployer
contract Deploy is Script {
    // Season 1: 10M $LASSO over 30 days — 6M to liquidity, 4M to trading
    uint256 constant SEASON = 30 days;
    uint256 constant LP_BUDGET = 6_000_000e18;
    uint256 constant TRADE_BUDGET = 4_000_000e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console.log("deployer", deployer);
        address keeper = vm.envOr("KEEPER", deployer);
        address treasury = vm.envOr("TREASURY", deployer);

        vm.startBroadcast(pk);
        (Lasso lasso, LassoFarm farm, HookePriceAdapter adapter,) = deployAll(deployer, keeper, treasury, false);
        vm.stopBroadcast();

        string memory json = "deploy";
        vm.serializeAddress(json, "lasso", address(lasso));
        vm.serializeAddress(json, "lp", address(lasso.lp()));
        vm.serializeAddress(json, "farm", address(farm));
        vm.serializeAddress(json, "adapter", address(adapter));
        vm.serializeUint(json, "chainId", block.chainid);
        string memory out = vm.serializeUint(json, "block", block.number);
        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), ".json"));
        console.log("Lasso", address(lasso));
        console.log("LassoFarm", address(farm));
    }

    function deployAll(address owner, address keeper, address treasury, bool withEth)
        public
        returns (Lasso lasso, LassoFarm farm, HookePriceAdapter adapter, PostedPriceSource ethSource)
    {
        adapter = new HookePriceAdapter(IHookeOracleRegistry(Addresses.HOOKE_ORACLE_REGISTRY), 120);
        FixedPriceSource usdgSource = new FixedPriceSource(1e18);
        farm = new LassoFarm(owner, LP_BUDGET / SEASON, TRADE_BUDGET / SEASON, uint64(block.timestamp + SEASON));

        lasso = new Lasso(
            owner,
            adapter,
            treasury,
            Lasso.Params({
                minExecDelay: 2,
                orderTtl: 5 minutes,
                protocolShareBps: 2000,
                lpFeeBps: 10,
                liquidationFeeUsd: 1e18,
                minCollateralUsd: 5e18
            }),
            address(farm)
        );
        farm.init(address(lasso), address(lasso.lp()));
        lasso.setToken(Addresses.USDG, 6, IPriceSource(address(usdgSource)));
        lasso.setKeeper(keeper, true);
        if (withEth) ethSource = _enableEth(lasso, owner, keeper);

        uint128 borrowRate = uint128(1e18 / uint256(365 days)); // 100% APR at full utilisation

        lasso.addMarket(
            Lasso.MarketConfig({
                name: "XMAX",
                price: HookePriceAdapter.PriceConfig({
                    source: HookePriceAdapter.Source.ORACLE,
                    feedId: Addresses.XMAX_FEED_ID,
                    feeHook: Addresses.HOOKE_FEE_HOOK,
                    twapWindow: 0,
                    tokenDecimals: 18,
                    quoteDecimals: 6
                }),
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
        lasso.addMarket(
            Lasso.MarketConfig({
                name: "hXMAX",
                price: HookePriceAdapter.PriceConfig({
                    source: HookePriceAdapter.Source.POOL,
                    feedId: bytes32(0),
                    feeHook: Addresses.HOOKE_FEE_HOOK,
                    twapWindow: 30 minutes,
                    tokenDecimals: 18,
                    quoteDecimals: 6
                }),
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
    }

    function _enableEth(Lasso lasso, address owner, address keeper) internal returns (PostedPriceSource ethSource) {
        ethSource = new PostedPriceSource(
            owner,
            IPoolManagerExtsload(Addresses.POOL_MANAGER),
            Addresses.ETH_USDG_POOL_ID,
            true, // ETH is currency0 of the ETH/USDG pool
            18,
            6,
            1 hours,
            500 // posted price must stay within 5% of the pool
        );
        ethSource.setPoster(keeper, true);
        lasso.setToken(lasso.ETH(), 18, IPriceSource(address(ethSource)));
    }
}
