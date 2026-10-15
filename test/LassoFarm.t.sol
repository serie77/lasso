// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LassoFarm} from "../src/LassoFarm.sol";

contract FarmToken is ERC20("Lasso", "LASSO") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Farm accounting in isolation: this contract plays both the core (fees) and the LP token (balances).
contract LassoFarmTest is Test {
    LassoFarm farm;
    address[3] users = [address(0xA11CE), address(0xB0B), address(0xCA7)];
    mapping(address => uint256) bal;

    uint256 constant LP_RATE = 6_000_000e18 / uint256(30 days);
    uint256 constant TRADE_RATE = 4_000_000e18 / uint256(30 days);

    function setUp() public {
        vm.warp(20_800 days + 12 hours); // mid-epoch start, like a real deploy
        farm = new LassoFarm(address(this), LP_RATE, TRADE_RATE, uint64(block.timestamp + 30 days));
        farm.init(address(this), address(this));
    }

    function _mint(address to, uint256 amt) internal {
        farm.onLpTransfer(address(0), to, amt);
        bal[to] += amt;
    }

    function _burn(address from, uint256 amt) internal {
        farm.onLpTransfer(from, address(0), amt);
        bal[from] -= amt;
    }

    function _transfer(address from, address to, uint256 amt) internal {
        farm.onLpTransfer(from, to, amt);
        bal[from] -= amt;
        bal[to] += amt;
    }

    function test_soleHolderGetsWholeStream() public {
        _mint(users[0], 1_000e18);
        skip(1 days);
        (uint256 c,) = farm.earned(users[0]);
        assertApproxEqAbs(c, LP_RATE * 1 days, 1e3);
        assertLe(c, farm.totalEmitted());
    }

    function test_noHoldersMeansNoEmission() public {
        skip(1 days);
        assertEq(farm.totalEmitted(), 0);
        _mint(users[0], 1e18);
        skip(1);
        (uint256 c,) = farm.earned(users[0]);
        assertApproxEqAbs(c, LP_RATE, 1e3, "no retroactive emission for the empty period");
    }

    function test_firstEpochIsPartial() public {
        farm.onTradeFee(users[0], 1e18);
        uint256 e = farm.currentEpoch();
        assertEq(farm.epochReward(e), TRADE_RATE * 12 hours);
    }

    function test_onlyHooksCanReport() public {
        vm.prank(users[0]);
        vm.expectRevert(LassoFarm.NotLpToken.selector);
        farm.onLpTransfer(address(0), users[0], 1e18);
        vm.prank(users[0]);
        vm.expectRevert(LassoFarm.NotCore.selector);
        farm.onTradeFee(users[0], 1e18);
    }

    function test_extendingSeasonDoesNotBackfill() public {
        _mint(users[0], 1e18);
        vm.warp(farm.end() + 5 days);
        uint256 emitted = farm.totalEmitted();
        farm.setEnd(uint64(block.timestamp + 10 days));
        assertEq(farm.totalEmitted(), emitted, "gap after the old end earns nothing");
        skip(1 days);
        assertApproxEqAbs(farm.totalEmitted(), emitted + LP_RATE * 1 days, 1);
    }

    /// @dev Random activity; the farm must never owe more than it emitted, and funding exactly totalEmitted pays all.
    function testFuzz_neverOwesMoreThanEmitted(uint256 seed) public {
        for (uint256 i = 0; i < 40; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address u = users[seed % 3];
            address v = users[(seed >> 8) % 3];
            uint256 amt = (seed >> 16) % 1_000_000e18 + 1;
            uint256 action = (seed >> 128) % 5;
            if (action == 0) _mint(u, amt);
            else if (action == 1 && bal[u] != 0) _burn(u, amt % bal[u] + 1);
            else if (action == 2 && bal[u] != 0) _transfer(u, v, amt % bal[u] + 1);
            else if (action == 3) farm.onTradeFee(u, amt % 1_000e18);
            skip((seed >> 200) % 2 days);
        }
        vm.warp(farm.end() + 2 days); // every epoch finished

        uint256 emitted = farm.totalEmitted();
        uint256 owed;
        for (uint256 j = 0; j < 3; j++) {
            (uint256 c, uint256 today) = farm.earned(users[j]);
            assertEq(today, 0);
            owed += c;
        }
        assertLe(owed, emitted, "owes more than emitted");
        assertLe(emitted, 10_000_000e18 + 1, "over season budget");
        assertEq(farm.lpTotal(), bal[users[0]] + bal[users[1]] + bal[users[2]]);

        FarmToken token = new FarmToken();
        farm.setLasso(token);
        token.mint(address(farm), emitted);
        for (uint256 j = 0; j < 3; j++) {
            vm.prank(users[j]);
            farm.claim();
        }
        assertEq(token.balanceOf(address(farm)) + farm.totalClaimed(), emitted);
        assertEq(farm.totalClaimed(), owed);
    }
}
