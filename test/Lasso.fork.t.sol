// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Addresses} from "../script/Addresses.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Lasso} from "../src/Lasso.sol";
import {LassoFarm} from "../src/LassoFarm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HookePriceAdapter} from "../src/HookePriceAdapter.sol";
import {PostedPriceSource} from "../src/price/PostedPriceSource.sol";
import {IHookeOracleRegistry, IHookeFeeHook} from "../src/interfaces/IHooke.sol";

/// @notice Runs against a fork of Robinhood Chain: real Hooke oracle registry, fee hook, PoolManager and USDG.
contract LassoForkTest is Test {
    uint16 constant XMAX = 0; // oracle market
    uint16 constant HXMAX = 1; // pool market
    address constant ETH = address(0);

    Lasso tension;
    LassoFarm farm;
    HookePriceAdapter adapter;
    PostedPriceSource ethSource;
    IERC20 usdg = IERC20(Addresses.USDG);
    IHookeOracleRegistry registry = IHookeOracleRegistry(Addresses.HOOKE_ORACLE_REGISTRY);

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");
    address lp = makeAddr("lp");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint64 oraclePublishTime;
    bool _closedOverride; // stock market state for _bumpOracle; tests run the same whatever the live flag says
    uint256 ethPrice;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC", Addresses.PUBLIC_RPC));
        Deploy d = new Deploy();
        owner = address(d); // deployAll configures via onlyOwner calls made by the Deploy contract
        (tension, farm, adapter, ethSource) = d.deployAll(owner, keeper, treasury, true);

        // ETH price: post the pool spot so the band check passes
        ethPrice = ethSource.poolSpotPrice();
        vm.prank(keeper);
        ethSource.post(ethPrice);

        // USDG from the PoolManager (largest holder) to our actors
        vm.startPrank(Addresses.POOL_MANAGER);
        usdg.transfer(lp, 500_000e6);
        usdg.transfer(alice, 50_000e6);
        usdg.transfer(bob, 50_000e6);
        vm.stopPrank();
        vm.deal(lp, 100 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        (, , oraclePublishTime, , , ) = registry.latestPrice(Addresses.XMAX_FEED_ID);

        vm.startPrank(lp);
        usdg.approve(address(tension), type(uint256).max);
        tension.deposit(Addresses.USDG, 200_000e6);
        tension.deposit{value: 20 ether}(ETH, 20 ether);
        vm.stopPrank();
        vm.prank(alice);
        usdg.approve(address(tension), type(uint256).max);
        vm.prank(bob);
        usdg.approve(address(tension), type(uint256).max);
    }

    // ---------- pricing against live Hooke ----------

    function test_tickMathMatchesLivePool() public view {
        IHookeFeeHook hook = IHookeFeeHook(Addresses.HOOKE_FEE_HOOK);
        (uint256 spot,,,,,,) = hook.currentState();
        uint256 twap = adapter.tickToPrice(hook.consultMeanTick(60), hook.tokenIsCurrency0(), 18, 6);
        // 60s mean tick vs spot: within 0.5%
        assertApproxEqRel(twap, spot, 0.005e18, "tick->price off vs Hooke spot");
        assertGt(spot, 1e18);
        assertLt(spot, 100e18);
    }

    function test_oracleQuoteMatchesRegistry() public view {
        (uint256 p,,, bool open,,) = registry.latestPrice(Addresses.XMAX_FEED_ID);
        (uint256 price, bool mOpen) = tension.markPrice(XMAX);
        assertEq(price, p);
        assertEq(mOpen, open);
    }

    function test_hookeStateReadable() public view {
        (uint256 pool, uint256 oracle, int256 dev, uint256 buy, uint256 sell,) = adapter.hookeState(Addresses.HOOKE_FEE_HOOK);
        assertGt(pool, 0);
        assertGt(oracle, 0);
        assertTrue(buy >= 20_000 && buy <= 40_000);
        assertTrue(sell >= 20_000 && sell <= 40_000);
        // deviation = pool/oracle - 1
        int256 expected = int256(pool * 1e18 / oracle) - 1e18;
        assertApproxEqAbs(dev, expected, 1e15);
    }

    function test_ethPriceBand() public {
        vm.prank(keeper);
        vm.expectRevert();
        ethSource.post(ethPrice * 2);
        vm.prank(keeper);
        ethSource.post(ethPrice * 101 / 100);
    }

    // ---------- liquidity ----------

    function test_depositWithdraw() public {
        uint256 shares = tension.lp().balanceOf(lp);
        assertGt(shares, 0);
        uint256 value = tension.poolValueUsd();
        // 200k USDG + 20 ETH, minus 0.1% deposit fee that stays in the pool (so value counts it)
        assertApproxEqRel(value, 200_000e18 + 20 * ethPrice, 0.001e18);

        uint256 before = usdg.balanceOf(lp);
        vm.prank(lp);
        uint256 out = tension.withdraw(shares / 10, Addresses.USDG);
        // a tenth of the pool, paid in USDG, minus the 0.1% withdraw fee
        assertApproxEqRel(out, value / 10 / 1e12 * 999 / 1000, 0.002e18);
        assertEq(usdg.balanceOf(lp) - before, out);
        _assertSolvent();
    }

    // ---------- orders on the oracle market ----------

    function test_oracleOrderNeedsFreshPublish() public {
        (uint256 p,,, bool open,,) = registry.latestPrice(Addresses.XMAX_FEED_ID);
        skip(10);
        _mockOracle(p, open); // last publish is now; the order below is created after it
        skip(1);
        uint256 id = _createIncrease(alice, XMAX, true, Addresses.USDG, 1_000e6, 5_000e18, type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert(Lasso.NotFresh.selector);
        tension.executeOrder(id);
    }

    function test_openAndCloseLongWithProfit() public {
        uint256 id = _createIncrease(alice, XMAX, true, Addresses.USDG, 1_000e6, 5_000e18, type(uint256).max);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(id);

        bytes32 key = tension.positionKey(alice, XMAX, true);
        Lasso.Position memory p = tension.getPosition(key);
        assertEq(p.size, 5_000e18);
        (uint256 entry,) = tension.markPrice(XMAX);
        assertEq(p.entryPrice, entry);
        // open fee 0.1% of 5000 = $5, plus tension fee (long skew 100% -> +0.5% = $25): collateral = 1000 - 30
        assertEq(p.collateral, 970e6);
        _assertSolvent();

        // stock +10%
        _mockOracle(entry * 110 / 100, true);
        (int256 equity, int256 pnl,,, bool liq) = tension.positionHealth(key);
        assertApproxEqAbs(pnl, 500e18, 1e12);
        assertFalse(liq);
        assertGt(equity, 1_400e18);

        uint256 before = usdg.balanceOf(alice);
        uint256 cid = _createDecrease(alice, XMAX, true, Addresses.USDG, 0, 5_000e18, 1);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(cid);
        uint256 got = usdg.balanceOf(alice) - before;
        // 970 collateral + 500 profit - 5 close fee - tiny borrow fee
        assertApproxEqAbs(got, 1_465e6, 1e6);
        assertEq(tension.getPosition(key).size, 0);
        assertEq(tension.totalOi(), 0);
        _assertSolvent();
    }

    function test_shortLosesWhenStockRises() public {
        uint256 id = _createIncrease(bob, XMAX, false, Addresses.USDG, 1_000e6, 3_000e18, 1);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(id);
        (uint256 entry,) = tension.markPrice(XMAX);
        _mockOracle(entry * 105 / 100, true);

        uint256 before = usdg.balanceOf(bob);
        uint256 cid = _createDecrease(bob, XMAX, false, Addresses.USDG, 0, 3_000e18, type(uint256).max);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(cid);
        uint256 got = usdg.balanceOf(bob) - before;
        // collateral 1000 - 3 open - 15 tension - 150 loss - 3 close
        assertApproxEqAbs(got, 829e6, 1e6);
        _assertSolvent();
    }

    function test_slippageCancelsAndRefunds() public {
        (uint256 mark,) = tension.markPrice(XMAX);
        uint256 before = usdg.balanceOf(alice);
        uint256 id = _createIncrease(alice, XMAX, true, Addresses.USDG, 1_000e6, 5_000e18, mark - 1);
        assertEq(usdg.balanceOf(alice), before - 1_000e6);
        _bumpOracle();
        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit Lasso.OrderCancelled(id, "slippage");
        tension.executeOrder(id);
        assertEq(usdg.balanceOf(alice), before);
        assertEq(uint8(tension.getOrder(id).status), uint8(Lasso.OrderStatus.Cancelled));
        _assertSolvent();
    }

    function test_closedMarketBlocksNewRiskButAllowsClose() public {
        uint256 id = _createIncrease(alice, XMAX, true, Addresses.USDG, 1_000e6, 5_000e18, type(uint256).max);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(id);
        (uint256 entry,) = tension.markPrice(XMAX);

        // market closes
        _closedOverride = true;
        _mockOracle(entry, false);
        uint256 id2 = _createIncrease(bob, XMAX, true, Addresses.USDG, 1_000e6, 5_000e18, type(uint256).max);
        _bumpOracle();
        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit Lasso.OrderCancelled(id2, "market closed");
        tension.executeOrder(id2);

        // close still works, at a 0.5% spread against the trader
        uint256 before = usdg.balanceOf(alice);
        uint256 cid = _createDecrease(alice, XMAX, true, Addresses.USDG, 0, 5_000e18, 1);
        _bumpOracle();
        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit Lasso.OrderExecuted(cid, entry * 9950 / 10_000);
        tension.executeOrder(cid);
        // 970 - 25 (0.5% of 5000) - 5 close fee
        assertApproxEqAbs(usdg.balanceOf(alice) - before, 940e6, 1e6);
        _assertSolvent();
    }

    function test_liquidation() public {
        uint256 id = _createIncrease(alice, XMAX, true, Addresses.USDG, 1_000e6, 9_000e18, type(uint256).max);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(id);
        bytes32 key = tension.positionKey(alice, XMAX, true);
        (uint256 entry,) = tension.markPrice(XMAX);

        vm.expectRevert(Lasso.NotLiquidatable.selector);
        tension.liquidate(alice, XMAX, true);

        // -10%: pnl -900 on 9000 size; collateral 1000 - 9 - 45 = 946; equity ≈ 946 - 900 - 9 = 37 < 1% of 9000 = 90
        _mockOracle(entry * 90 / 100, true);
        (,,,, bool liq) = tension.positionHealth(key);
        assertTrue(liq);

        uint256 poolBefore = tension.poolAmount(Addresses.USDG);
        uint256 before = usdg.balanceOf(bob);
        vm.prank(bob);
        tension.liquidate(alice, XMAX, true);
        assertEq(usdg.balanceOf(bob) - before, 1e6, "liquidator gets $1");
        assertEq(tension.getPosition(key).size, 0);
        assertEq(tension.totalOi(), 0);
        assertGt(tension.poolAmount(Addresses.USDG), poolBefore);
        _assertSolvent();
    }

    // ---------- pool (hXMAX) market ----------

    function test_poolMarketShortAndTwapProtection() public {
        // short the onchain token: executes after minExecDelay, no oracle needed
        uint256 id = _createIncrease(bob, HXMAX, false, Addresses.USDG, 2_000e6, 6_000e18, 1);
        vm.prank(keeper);
        vm.expectRevert(Lasso.NotFresh.selector);
        tension.executeOrder(id);
        skip(2);
        vm.prank(keeper);
        tension.executeOrder(id);
        Lasso.Position memory p = tension.getPosition(tension.positionKey(bob, HXMAX, false));
        assertEq(p.size, 6_000e18);

        // spot dumps 20% but the TWAP hasn't moved: closing a short uses max(spot, twap) = twap -> no profit yet
        (uint256 spot,,,,,,) = IHookeFeeHook(Addresses.HOOKE_FEE_HOOK).currentState();
        _mockPoolSpot(spot * 80 / 100);
        (uint256 execPrice,,) = adapter.quote(tension.getMarketConfig(HXMAX).price, true);
        assertApproxEqRel(execPrice, spot, 0.01e18, "twap should cap the short's exit price");

        // the TWAP follows: now the short closes in profit
        _mockPoolTwap(spot * 80 / 100);
        uint256 before = usdg.balanceOf(bob);
        uint256 cid = _createDecrease(bob, HXMAX, false, Addresses.USDG, 0, 6_000e18, type(uint256).max);
        skip(2);
        vm.prank(keeper);
        tension.executeOrder(cid);
        uint256 got = usdg.balanceOf(bob) - before;
        // 2000 - 6 - 30 tension + ~1200 profit - 6 close (entry was min(spot, twap), slightly under spot)
        assertApproxEqAbs(got, 3_158e6, 8e6);
        _assertSolvent();
    }

    // ---------- ETH collateral ----------

    function test_ethCollateralRoundTrip() public {
        uint256 id = _createIncrease(alice, XMAX, true, ETH, 1 ether, 10_000e18, type(uint256).max);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(id);
        bytes32 key = tension.positionKey(alice, XMAX, true);
        Lasso.Position memory p = tension.getPosition(key);
        assertEq(p.token, ETH);
        (uint256 entry,) = tension.markPrice(XMAX);
        _mockOracle(entry * 102 / 100, true);

        uint256 before = alice.balance;
        uint256 cid = _createDecrease(alice, XMAX, true, ETH, 0, 10_000e18, 1);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(cid);
        uint256 got = alice.balance - before;
        // fees: open $10 + tension $50 + close $10 = $70; profit $200 -> net +$130 in ETH
        uint256 expected = 1 ether + 130e18 * 1e18 / ethPrice;
        assertApproxEqRel(got, expected, 0.002e18);
        _assertSolvent();
    }

    function test_tensionFeeFollowsSkew() public {
        assertEq(tension.tensionFeeBps(XMAX, true, 1_000e18), 50); // first long: 100% skew -> max
        uint256 id = _createIncrease(alice, XMAX, true, Addresses.USDG, 1_000e6, 4_000e18, type(uint256).max);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(id);
        assertEq(tension.tensionFeeBps(XMAX, false, 4_000e18), 0); // shorting toward balance is free
        assertEq(tension.tensionFeeBps(XMAX, true, 4_000e18), 50); // piling on longs pays full
        assertEq(tension.tensionFeeBps(XMAX, false, 6_000e18), 10); // overshooting to 6k short vs 4k long: 20% skew
    }

    function test_expiredOrderCancellableByAnyone() public {
        uint256 id = _createIncrease(alice, XMAX, true, Addresses.USDG, 1_000e6, 5_000e18, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(Lasso.NotExpired.selector);
        tension.cancelOrder(id);
        skip(6 minutes);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(bob);
        tension.cancelOrder(id);
        assertEq(usdg.balanceOf(alice) - before, 1_000e6);
    }

    function test_lpAbsorbsTraderProfitInShareValue() public {
        uint256 valueBefore = tension.poolValueUsd();
        uint256 id = _createIncrease(alice, XMAX, true, Addresses.USDG, 5_000e6, 40_000e18, type(uint256).max);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(id);
        assertEq(tension.totalOi(), 40_000e18);
        (uint256 entry,) = tension.markPrice(XMAX);
        _mockOracle(entry * 110 / 100, true);
        // traders are up $4000 -> LP value drops by that, net of the LP share (80%) of the $240 fees paid in
        uint256 valueAfter = tension.poolValueUsd();
        assertApproxEqAbs(valueBefore - valueAfter, 4_000e18 - 240e18 * 8 / 10, 2e18);
    }

    function test_increaseSizeWithoutNewCollateral() public {
        uint256 id = _createIncrease(alice, XMAX, true, Addresses.USDG, 1_000e6, 2_000e18, type(uint256).max);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(id);
        // add size only: the fee comes out of the existing collateral
        uint256 id2 = _createIncrease(alice, XMAX, true, Addresses.USDG, 0, 1_000e18, type(uint256).max);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(id2);
        assertEq(uint8(tension.getOrder(id2).status), uint8(Lasso.OrderStatus.Executed));
        assertEq(tension.getPosition(tension.positionKey(alice, XMAX, true)).size, 3_000e18);
        _assertSolvent();
    }

    // ---------- $LASSO farming ----------

    function test_farmLpAccruesProRata() public {
        uint256 rate = farm.lpRate();
        _warp(vm.getBlockTimestamp() + 1 days);
        (uint256 l1,) = farm.earned(lp);
        assertApproxEqAbs(l1, rate * 1 days, 1e6, "sole LP earns the whole stream");

        vm.prank(bob);
        tension.deposit(Addresses.USDG, 50_000e6);
        uint256 total = tension.lp().totalSupply();
        uint256 sb = tension.lp().balanceOf(bob);
        _warp(vm.getBlockTimestamp() + 1 days);
        (uint256 b,) = farm.earned(bob);
        (uint256 l2,) = farm.earned(lp);
        assertApproxEqAbs(b, rate * 1 days * sb / total, 1e6);
        assertApproxEqAbs(l2, rate * 1 days + rate * 1 days * (total - sb) / total, 1e6);
        assertLe(b + l2, farm.totalEmitted());
    }

    function test_farmLpTransferMovesFutureRewardsOnly() public {
        uint256 rate = farm.lpRate();
        skip(1 hours);
        uint256 total = tension.lp().totalSupply();
        uint256 half = total / 2;
        ERC20 llp = tension.lp();
        vm.prank(lp);
        llp.transfer(alice, half);
        (uint256 a0,) = farm.earned(alice);
        assertEq(a0, 0);
        skip(1 hours);
        (uint256 a,) = farm.earned(alice);
        (uint256 l,) = farm.earned(lp);
        assertApproxEqAbs(a, rate * 1 hours * half / total, 1e6);
        assertApproxEqAbs(l, rate * 1 hours + rate * 1 hours * (total - half) / total, 1e6);
    }

    function test_farmTradingSplitsEpochByFeesPaid() public {
        uint256 e = farm.currentEpoch() + 1;
        _warp(e * 1 days + 1 hours);
        // alice: 0.1% open + 0.5% tension on 5000 = $30. bob shorts toward balance: 0.1% = $5
        uint256 id = _createIncrease(alice, XMAX, true, Addresses.USDG, 1_000e6, 5_000e18, type(uint256).max);
        uint256 id2 = _createIncrease(bob, XMAX, false, Addresses.USDG, 1_000e6, 5_000e18, 1);
        _bumpOracle();
        vm.startPrank(keeper);
        tension.executeOrder(id);
        tension.executeOrder(id2);
        vm.stopPrank();
        assertEq(farm.traderFees(alice), 30e18);
        assertEq(farm.traderFees(bob), 5e18);

        uint256 reward = farm.epochReward(e);
        assertEq(reward, farm.tradeRate() * 1 days);
        (uint256 aNow, uint256 aToday) = farm.earned(alice);
        assertEq(aNow, 0, "nothing claimable until the epoch ends");
        assertEq(aToday, reward * 30 / 35);

        _warp((e + 1) * 1 days);
        (uint256 a,) = farm.earned(alice);
        (uint256 b,) = farm.earned(bob);
        assertEq(a, reward * 30 / 35);
        assertEq(b, reward * 5 / 35);
        assertLe(a + b, reward);
    }

    function test_farmClaimAndSeasonEnd() public {
        uint256 id = _createIncrease(alice, XMAX, true, Addresses.USDG, 1_000e6, 5_000e18, type(uint256).max);
        _bumpOracle();
        vm.prank(keeper);
        tension.executeOrder(id);

        vm.expectRevert(LassoFarm.NotLive.selector);
        vm.prank(lp);
        farm.claim();

        // past the season: nothing accrues any more
        _warp(farm.end() + 1);
        (uint256 l1,) = farm.earned(lp);
        uint256 emitted = farm.totalEmitted();
        _warp(farm.end() + 10 days);
        (uint256 l2,) = farm.earned(lp);
        assertEq(l1, l2);
        assertEq(farm.totalEmitted(), emitted);
        assertLe(emitted, 10_000_000e18, "season budget");

        // $LASSO launches: fund exactly totalEmitted and everyone can claim
        MockLasso token = new MockLasso();
        vm.prank(owner);
        farm.setLasso(token);
        token.mint(address(farm), emitted);
        (uint256 a,) = farm.earned(alice);
        vm.prank(lp);
        assertEq(farm.claim(), l2);
        vm.prank(alice);
        assertEq(farm.claim(), a);
        assertEq(token.balanceOf(lp), l2);
        assertGt(a, 0);
        (uint256 again,) = farm.earned(lp);
        assertEq(again, 0);
        vm.prank(owner);
        vm.expectRevert(LassoFarm.AlreadySet.selector);
        farm.setLasso(token);
    }

    // ---------- helpers ----------

    /// @dev Jumps in time and keeps the posted ETH price fresh (it expires after an hour).
    function _warp(uint256 t) internal {
        vm.warp(t);
        vm.prank(keeper);
        ethSource.post(ethPrice);
    }


    function _createIncrease(
        address who,
        uint16 market,
        bool isLong,
        address token,
        uint256 collateral,
        uint256 size,
        uint256 acceptable
    ) internal returns (uint256 id) {
        vm.prank(who);
        id = tension.createOrder{value: token == ETH ? collateral : 0}(market, isLong, true, token, collateral, size, acceptable);
    }

    function _createDecrease(
        address who,
        uint16 market,
        bool isLong,
        address token,
        uint256 collateral,
        uint256 size,
        uint256 acceptable
    ) internal returns (uint256 id) {
        vm.prank(who);
        id = tension.createOrder(market, isLong, false, token, collateral, size, acceptable);
    }

    /// @dev Replaces the live oracle answer; publish time = now so it is fresh for orders created before now.
    function _mockOracle(uint256 price, bool open) internal {
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IHookeOracleRegistry.latestPrice.selector, Addresses.XMAX_FEED_ID),
            abi.encode(price, uint64(vm.getBlockTimestamp() - 1), uint64(vm.getBlockTimestamp()), open, uint64(vm.getBlockTimestamp() + 15), address(0xa4b8))
        );
    }

    /// @dev Simulates the next oracle publish after the latest order: same price, newer timestamp.
    function _bumpOracle() internal {
        (uint256 p,,,,,) = registry.latestPrice(Addresses.XMAX_FEED_ID);
        skip(10);
        _mockOracle(p, !_closedOverride);
    }

    function _mockPoolSpot(uint256 spot) internal {
        (, uint256 oracle, int256 dev, uint256 buy, uint256 sell, bool open, bool healthy) =
            IHookeFeeHook(Addresses.HOOKE_FEE_HOOK).currentState();
        vm.mockCall(
            Addresses.HOOKE_FEE_HOOK,
            abi.encodeWithSelector(IHookeFeeHook.currentState.selector),
            abi.encode(spot, oracle, dev, buy, sell, open, healthy)
        );
    }

    function _mockPoolTwap(uint256 price) internal {
        // find the tick whose price is just below `price` (hXMAX is currency1: a higher tick means a lower price)
        IHookeFeeHook hook = IHookeFeeHook(Addresses.HOOKE_FEE_HOOK);
        assertFalse(hook.tokenIsCurrency0());
        int24 tick = hook.consultMeanTick(30 minutes);
        while (adapter.tickToPrice(tick, false, 18, 6) > price) tick += 10;
        vm.mockCall(
            Addresses.HOOKE_FEE_HOOK, abi.encodeWithSelector(IHookeFeeHook.consultMeanTick.selector, uint32(30 minutes)), abi.encode(tick)
        );
    }

    /// @dev Contract holds at least everything it owes: pool + collateral + escrow + protocol fees.
    function _assertSolvent() internal view {
        address t = address(tension);
        uint256 owedUsdg = tension.poolAmount(Addresses.USDG) + tension.collateralHeld(Addresses.USDG)
            + tension.escrowed(Addresses.USDG) + tension.protocolFees(Addresses.USDG);
        assertGe(usdg.balanceOf(t), owedUsdg, "USDG insolvent");
        uint256 owedEth = tension.poolAmount(ETH) + tension.collateralHeld(ETH) + tension.escrowed(ETH) + tension.protocolFees(ETH);
        assertGe(t.balance, owedEth, "ETH insolvent");
    }
}

contract MockLasso is ERC20("Lasso", "LASSO") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
