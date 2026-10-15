// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Lasso} from "../src/Lasso.sol";
import {Addresses} from "./Addresses.sol";

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManagerSwap {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

/// @notice Swaps exact ETH for USDG on the Robinhood Chain ETH/USDG Uniswap v4 pool.
contract EthToUsdg {
    IPoolManagerSwap constant PM = IPoolManagerSwap(Addresses.POOL_MANAGER);
    uint160 constant MIN_SQRT_PRICE_PLUS_ONE = 4295128740;

    function key() public pure returns (PoolKey memory) {
        return PoolKey(address(0), Addresses.USDG, 0, 30, 0x58A6eF29ddCdb064A72b550a78D84a8e065994C0);
    }

    function swap(uint256 minOut) external payable returns (uint256 out) {
        out = abi.decode(PM.unlock(abi.encode(msg.sender, msg.value, minOut)), (uint256));
        if (address(this).balance != 0) payable(msg.sender).transfer(address(this).balance);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "pm");
        (address to, uint256 amountIn, uint256 minOut) = abi.decode(data, (address, uint256, uint256));
        int256 delta = PM.swap(key(), SwapParams(true, -int256(amountIn), MIN_SQRT_PRICE_PLUS_ONE), "");
        int128 a0 = int128(delta >> 128);
        int128 a1 = int128(delta);
        uint256 out = uint256(uint128(a1));
        require(out >= minOut, "slippage");
        PM.settle{value: uint256(uint128(-a0))}();
        PM.take(Addresses.USDG, to, out);
        return abi.encode(out);
    }

    receive() external payable {}
}

/// @notice Live smoke test setup: swap a little ETH to USDG, approve Lasso, seed the pool.
/// env: PRIVATE_KEY, LASSO, SWAP_WEI, MIN_USDG (6 decimals), DEPOSIT_USDG (6 decimals)
contract LiveSetup is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        Lasso lasso = Lasso(payable(vm.envAddress("LASSO")));
        IERC20 usdg = IERC20(Addresses.USDG);

        vm.startBroadcast(pk);
        EthToUsdg swapper = new EthToUsdg();
        uint256 got = swapper.swap{value: vm.envUint("SWAP_WEI")}(vm.envUint("MIN_USDG"));
        usdg.approve(address(lasso), type(uint256).max);
        uint256 shares = lasso.deposit(Addresses.USDG, vm.envUint("DEPOSIT_USDG"));
        vm.stopBroadcast();

        console.log("swapped USDG", got);
        console.log("LLP minted", shares);
        console.log("wallet USDG", usdg.balanceOf(me));
        console.log("pool value", lasso.poolValueUsd());
    }
}
