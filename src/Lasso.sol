// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HookePriceAdapter} from "./HookePriceAdapter.sol";
import {IPriceSource} from "./price/IPriceSource.sol";
import {LassoLP, ILpFarm} from "./LassoLP.sol";

interface ITradeFarm {
    function onTradeFee(address trader, uint256 feeUsd) external;
}

/// @title Lasso — perpetuals on Hooke's tokenized stocks
/// @notice Pool-vs-trader perps (GMX style). LPs deposit USDG or ETH into one pool that is the counterparty to every
/// position. Each stock gets two markets priced off Hooke itself: the oracle (share) price and the onchain token
/// price. Fees borrow Hooke's spring: the base rate applies when a trade pulls open interest toward balance, and
/// rises with the skew it creates (the "tension" fee). Orders execute in two steps against a price published after
/// the order, so nobody trades on a stale quote.
contract Lasso is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint256 private constant USD = 1e18;
    uint256 private constant BPS = 10_000;
    address public constant ETH = address(0);

    // ---------- types ----------

    struct TokenConfig {
        bool enabled;
        uint8 decimals;
        IPriceSource source;
    }

    struct MarketConfig {
        string name;
        HookePriceAdapter.PriceConfig price;
        bool active;
        bool allowIncreaseWhenClosed; // ORACLE markets: open new risk while the stock market is closed
        uint16 closedSpreadBps; // extra spread charged against the trader while the market is closed
        uint16 maxLeverageX;
        uint16 maintenanceBps; // equity floor as a fraction of size
        uint16 openFeeBps;
        uint16 closeFeeBps;
        uint16 tensionFeeMaxBps; // extra open fee at 100% skew, scales linearly with skew
        uint128 maxOiUsd; // per side
        uint128 borrowRatePerSec; // 1e18-scaled per-second rate at 100% utilisation
    }

    struct MarketState {
        uint256 longOi;
        uint256 shortOi;
        uint256 longSizeOverEntry; // Σ size * 1e18 / entry, lets us price all longs in O(1)
        uint256 shortSizeOverEntry;
        uint256 borrowIndex; // 1e18-scaled cumulative borrow rate
        uint256 lastBorrowUpdate;
    }

    struct Position {
        uint256 size; // USD 1e18
        uint256 collateral; // token units
        uint256 entryPrice;
        uint256 entryBorrowIndex;
        address token;
    }

    struct PositionMeta {
        address trader;
        uint16 market;
        bool isLong;
    }

    enum OrderStatus {
        None,
        Pending,
        Executed,
        Cancelled
    }

    struct Order {
        address trader;
        uint16 market;
        bool isLong;
        bool isIncrease;
        address token;
        uint256 collateralDelta; // token units: deposited (increase) or withdrawn (decrease)
        uint256 sizeDelta; // USD 1e18
        uint256 acceptablePrice; // worst execution price the trader accepts
        uint64 createdAt;
        OrderStatus status;
    }

    struct Params {
        uint32 minExecDelay; // POOL markets: seconds between order and execution
        uint32 orderTtl; // seconds after which anyone may cancel a pending order
        uint16 protocolShareBps; // share of fees to the treasury
        uint16 lpFeeBps; // deposit / withdraw fee, stays in the pool
        uint128 liquidationFeeUsd; // paid to the liquidator out of remaining collateral
        uint128 minCollateralUsd;
    }

    // ---------- storage ----------

    HookePriceAdapter public immutable adapter;
    LassoLP public immutable lp;
    ITradeFarm public immutable farm;
    address public treasury;
    Params public params;

    address[] public tokenList;
    mapping(address => TokenConfig) public tokens;
    mapping(address => uint256) public poolAmount; // LP-owned token balances
    mapping(address => uint256) public collateralHeld; // open-position collateral
    mapping(address => uint256) public escrowed; // pending-order collateral
    mapping(address => uint256) public protocolFees;
    mapping(address => uint256) public unclaimedEth; // ETH payouts that could not be delivered

    MarketConfig[] public marketConfigs;
    MarketState[] public marketStates;
    uint256 public totalOi;

    mapping(bytes32 => Position) public positions;
    mapping(bytes32 => PositionMeta) public positionMeta;
    bytes32[] public positionKeys; // every key ever opened, for keepers to scan

    Order[] public orders;
    mapping(address => bool) public keepers;

    // ---------- events ----------

    event TokenSet(address indexed token, uint8 decimals, address source);
    event MarketAdded(uint16 indexed market, string name);
    event MarketUpdated(uint16 indexed market);
    event KeeperSet(address indexed keeper, bool allowed);
    event ParamsSet(Params params);
    event TreasurySet(address treasury);

    event Deposit(address indexed lpAddr, address indexed token, uint256 amount, uint256 usd, uint256 shares);
    event Withdraw(address indexed lpAddr, address indexed token, uint256 amount, uint256 usd, uint256 shares);

    event OrderCreated(
        uint256 indexed id,
        address indexed trader,
        uint16 indexed market,
        bool isLong,
        bool isIncrease,
        address token,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 acceptablePrice
    );
    event OrderExecuted(uint256 indexed id, uint256 price);
    event OrderCancelled(uint256 indexed id, string reason);

    event PositionIncreased(
        bytes32 indexed key,
        address indexed trader,
        uint16 indexed market,
        bool isLong,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 price,
        uint256 feeUsd
    );
    event PositionDecreased(
        bytes32 indexed key,
        address indexed trader,
        uint16 indexed market,
        bool isLong,
        uint256 sizeDelta,
        uint256 payout,
        uint256 price,
        int256 pnlUsd,
        uint256 feeUsd
    );
    event Liquidated(
        bytes32 indexed key,
        address indexed trader,
        uint16 indexed market,
        bool isLong,
        address liquidator,
        uint256 price,
        uint256 reward
    );
    event FeesCollected(address indexed token, uint256 amount);

    // ---------- errors ----------

    error NotKeeper();
    error NotSelf();
    error BadToken();
    error BadMarket();
    error BadAmount();
    error BadValue();
    error NoPosition();
    error NotPending();
    error NotFresh();
    error NotExpired();
    error NotTrader();
    error NotLiquidatable();
    error InsufficientPool();
    error PoolBacking();
    error MarketClosed();
    error Slippage();
    error Leverage();
    error MinCollateral();
    error OiCap();
    error WouldLiquidate();
    error TokenMismatch();

    modifier onlyKeeper() {
        if (!keepers[msg.sender]) revert NotKeeper();
        _;
    }

    constructor(address owner_, HookePriceAdapter adapter_, address treasury_, Params memory params_, address farm_)
        Ownable(owner_)
    {
        adapter = adapter_;
        treasury = treasury_;
        params = params_;
        farm = ITradeFarm(farm_);
        lp = new LassoLP(address(this), ILpFarm(farm_));
    }

    receive() external payable {}

    // ---------- admin ----------

    function setToken(address token, uint8 decimals, IPriceSource source) external onlyOwner {
        if (!tokens[token].enabled) tokenList.push(token);
        tokens[token] = TokenConfig({enabled: true, decimals: decimals, source: source});
        emit TokenSet(token, decimals, address(source));
    }

    function addMarket(MarketConfig calldata cfg) external onlyOwner returns (uint16 id) {
        id = uint16(marketConfigs.length);
        marketConfigs.push(cfg);
        marketStates.push(MarketState({
            longOi: 0,
            shortOi: 0,
            longSizeOverEntry: 0,
            shortSizeOverEntry: 0,
            borrowIndex: 0,
            lastBorrowUpdate: block.timestamp
        }));
        emit MarketAdded(id, cfg.name);
    }

    function updateMarket(uint16 id, MarketConfig calldata cfg) external onlyOwner {
        if (id >= marketConfigs.length) revert BadMarket();
        _updateBorrow(id);
        marketConfigs[id] = cfg;
        emit MarketUpdated(id);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function setParams(Params calldata p) external onlyOwner {
        params = p;
        emit ParamsSet(p);
    }

    function setTreasury(address t) external onlyOwner {
        treasury = t;
        emit TreasurySet(t);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function collectFees(address token) external onlyOwner {
        uint256 amount = protocolFees[token];
        protocolFees[token] = 0;
        _send(token, treasury, amount);
        emit FeesCollected(token, amount);
    }

    // ---------- liquidity ----------

    function deposit(address token, uint256 amount) external payable nonReentrant whenNotPaused returns (uint256 shares) {
        TokenConfig memory t = _token(token);
        _pull(token, amount);
        uint256 fee = amount * params.lpFeeBps / BPS;
        uint256 net = amount - fee;
        uint256 price = _tokenPrice(token);
        uint256 usd = _toUsd(t, net, price);
        uint256 supply = lp.totalSupply();
        uint256 value = poolValueUsd();
        if (supply != 0 && value == 0) revert PoolBacking(); // existing shares are worth nothing: minting would be unfair
        shares = supply == 0 ? usd : usd * supply / value;
        if (shares == 0) revert BadAmount();
        poolAmount[token] += amount; // fee stays in the pool
        lp.mint(msg.sender, shares);
        emit Deposit(msg.sender, token, amount, usd, shares);
    }

    function withdraw(uint256 shares, address token) external nonReentrant whenNotPaused returns (uint256 amount) {
        TokenConfig memory t = _token(token);
        if (shares == 0) revert BadAmount();
        uint256 usd = shares * poolValueUsd() / lp.totalSupply();
        uint256 price = _tokenPrice(token);
        uint256 gross = _toToken(t, usd, price);
        if (gross > poolAmount[token]) revert InsufficientPool();
        uint256 fee = gross * params.lpFeeBps / BPS;
        amount = gross - fee;
        lp.burn(msg.sender, shares);
        poolAmount[token] -= amount;
        if (totalOi > poolTokensUsd()) revert PoolBacking();
        _send(token, msg.sender, amount);
        emit Withdraw(msg.sender, token, amount, usd, shares);
    }

    // ---------- orders ----------

    function createOrder(
        uint16 market,
        bool isLong,
        bool isIncrease,
        address token,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 acceptablePrice
    ) external payable nonReentrant whenNotPaused returns (uint256 id) {
        if (market >= marketConfigs.length || !marketConfigs[market].active) revert BadMarket();
        _token(token);
        if (acceptablePrice == 0) revert BadAmount();
        if (isIncrease) {
            if (collateralDelta == 0 && sizeDelta == 0) revert BadAmount();
            _pull(token, collateralDelta);
            escrowed[token] += collateralDelta;
        } else {
            if (msg.value != 0) revert BadValue();
            Position storage p = positions[positionKey(msg.sender, market, isLong)];
            if (p.size == 0) revert NoPosition();
            if (p.token != token) revert TokenMismatch();
            if (sizeDelta > p.size) revert BadAmount();
        }
        id = orders.length;
        orders.push(Order({
            trader: msg.sender,
            market: market,
            isLong: isLong,
            isIncrease: isIncrease,
            token: token,
            collateralDelta: collateralDelta,
            sizeDelta: sizeDelta,
            acceptablePrice: acceptablePrice,
            createdAt: uint64(block.timestamp),
            status: OrderStatus.Pending
        }));
        emit OrderCreated(id, msg.sender, market, isLong, isIncrease, token, collateralDelta, sizeDelta, acceptablePrice);
    }

    /// @notice Keeper fills a pending order at the first price published after it was placed.
    /// Soft failures (slippage, limits, closed market) cancel the order and refund; price failures revert so the
    /// keeper retries later.
    function executeOrder(uint256 id) external nonReentrant onlyKeeper whenNotPaused {
        Order storage o = orders[id];
        if (o.status != OrderStatus.Pending) revert NotPending();
        MarketConfig memory cfg = marketConfigs[o.market];

        bool maximize = o.isIncrease == o.isLong; // worse side for the trader
        (uint256 price, uint64 publishTime, bool open) = adapter.quote(cfg.price, maximize);
        if (cfg.price.source == HookePriceAdapter.Source.ORACLE) {
            if (publishTime <= o.createdAt) revert NotFresh();
        } else if (block.timestamp < o.createdAt + params.minExecDelay) {
            revert NotFresh();
        }

        if (!open && cfg.closedSpreadBps != 0) {
            price = maximize ? price * (BPS + cfg.closedSpreadBps) / BPS : price * (BPS - cfg.closedSpreadBps) / BPS;
        }

        try this.selfExecute(id, price, open) {
            o.status = OrderStatus.Executed;
            emit OrderExecuted(id, price);
        } catch (bytes memory reason) {
            _cancel(id, _reasonString(reason));
        }
    }

    /// @dev Self-call so execution can be rolled back and the order cancelled instead of reverting the keeper tx.
    function selfExecute(uint256 id, uint256 price, bool open) external {
        if (msg.sender != address(this)) revert NotSelf();
        Order memory o = orders[id];
        MarketConfig memory cfg = marketConfigs[o.market];
        if (o.isIncrease) {
            if (!open && !cfg.allowIncreaseWhenClosed) revert MarketClosed();
            if (o.isLong ? price > o.acceptablePrice : price < o.acceptablePrice) revert Slippage();
            escrowed[o.token] -= o.collateralDelta;
            _increase(o, cfg, price);
        } else {
            if (o.isLong ? price < o.acceptablePrice : price > o.acceptablePrice) revert Slippage();
            _decrease(o.trader, o.market, o.isLong, o.sizeDelta, o.collateralDelta, price, cfg);
        }
    }

    function cancelOrder(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        if (o.status != OrderStatus.Pending) revert NotPending();
        if (msg.sender != o.trader && !keepers[msg.sender]) {
            if (block.timestamp < o.createdAt + params.orderTtl) revert NotExpired();
        }
        _cancel(id, msg.sender == o.trader ? "trader" : "expired");
    }

    function _cancel(uint256 id, string memory reason) internal {
        Order storage o = orders[id];
        o.status = OrderStatus.Cancelled;
        if (o.isIncrease && o.collateralDelta != 0) {
            escrowed[o.token] -= o.collateralDelta;
            _send(o.token, o.trader, o.collateralDelta);
        }
        emit OrderCancelled(id, reason);
    }

    // ---------- positions ----------

    function _increase(Order memory o, MarketConfig memory cfg, uint256 price) internal {
        bytes32 key = positionKey(o.trader, o.market, o.isLong);
        Position storage p = positions[key];
        MarketState storage ms = marketStates[o.market];
        TokenConfig memory t = tokens[o.token];
        _updateBorrow(o.market);

        if (p.size != 0 && p.token != o.token) revert TokenMismatch();
        if (p.size == 0 && o.sizeDelta == 0) revert BadAmount(); // collateral without a position would be stuck
        uint256 tokenPrice = _tokenPrice(o.token);

        uint256 feeUsd = o.sizeDelta * (cfg.openFeeBps + tensionFeeBps(o.market, o.isLong, o.sizeDelta)) / BPS
            + _borrowFeeUsd(p, ms);
        uint256 feeTokens = _toToken(t, feeUsd, tokenPrice);
        uint256 collateral = p.collateral + o.collateralDelta;
        if (collateral <= feeTokens) revert MinCollateral();
        collateral -= feeTokens;

        uint256 newSize = p.size + o.sizeDelta;
        if (o.sizeDelta != 0) {
            uint256 soe = (p.size == 0 ? 0 : p.size * USD / p.entryPrice) + o.sizeDelta * USD / price;
            p.entryPrice = newSize * USD / soe;
            if (o.isLong) {
                ms.longOi += o.sizeDelta;
                ms.longSizeOverEntry += o.sizeDelta * USD / price;
                if (ms.longOi > cfg.maxOiUsd) revert OiCap();
            } else {
                ms.shortOi += o.sizeDelta;
                ms.shortSizeOverEntry += o.sizeDelta * USD / price;
                if (ms.shortOi > cfg.maxOiUsd) revert OiCap();
            }
            totalOi += o.sizeDelta;
            if (totalOi > poolTokensUsd()) revert PoolBacking();
        }
        p.size = newSize;
        p.collateral = collateral;
        p.entryBorrowIndex = ms.borrowIndex;
        p.token = o.token;

        uint256 collateralUsd = _toUsd(t, collateral, tokenPrice);
        if (collateralUsd < params.minCollateralUsd) revert MinCollateral();
        if (newSize > collateralUsd * cfg.maxLeverageX) revert Leverage();

        collateralHeld[o.token] = collateralHeld[o.token] + o.collateralDelta - feeTokens;
        _creditFee(o.token, feeTokens);
        farm.onTradeFee(o.trader, feeUsd);
        if (positionMeta[key].trader == address(0)) {
            positionMeta[key] = PositionMeta({trader: o.trader, market: o.market, isLong: o.isLong});
            positionKeys.push(key);
        }
        emit PositionIncreased(key, o.trader, o.market, o.isLong, o.sizeDelta, o.collateralDelta, price, feeUsd);
    }

    function _decrease(
        address trader,
        uint16 market,
        bool isLong,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 price,
        MarketConfig memory cfg
    ) internal {
        bytes32 key = positionKey(trader, market, isLong);
        Position storage p = positions[key];
        if (p.size == 0) revert NoPosition();
        if (sizeDelta > p.size) revert BadAmount();
        MarketState storage ms = marketStates[market];
        TokenConfig memory t = tokens[p.token];
        _updateBorrow(market);
        uint256 tokenPrice = _tokenPrice(p.token);
        address token = p.token;

        int256 pnlUsd = _pnlUsd(p, isLong, sizeDelta, price);
        uint256 feeUsd = sizeDelta * cfg.closeFeeBps / BPS + _borrowFeeUsd(p, ms);
        uint256 feeTokens = _toToken(t, feeUsd, tokenPrice);

        uint256 payout;
        uint256 toPool; // collateral moving to the pool (losses + the LP share of fees)
        uint256 profitTokens;
        if (pnlUsd > 0) {
            profitTokens = _toToken(t, uint256(pnlUsd), tokenPrice);
        }
        uint256 debit = feeTokens + (pnlUsd < 0 ? _toToken(t, uint256(-pnlUsd), tokenPrice) : 0);
        if (debit >= p.collateral) {
            // underwater: collateral is gone, the pool absorbs the rest
            toPool = p.collateral;
            feeTokens = Math.min(feeTokens, p.collateral);
            p.collateral = 0;
        } else {
            toPool = debit;
            p.collateral -= debit;
        }

        bool fullClose = sizeDelta == p.size;
        if (fullClose) collateralDelta = p.collateral;
        if (collateralDelta > p.collateral) revert BadAmount();
        p.collateral -= collateralDelta;
        payout = collateralDelta + profitTokens;

        // market aggregates
        uint256 soeDelta = sizeDelta * USD / p.entryPrice;
        if (isLong) {
            ms.longOi -= sizeDelta;
            ms.longSizeOverEntry = ms.longSizeOverEntry > soeDelta ? ms.longSizeOverEntry - soeDelta : 0;
        } else {
            ms.shortOi -= sizeDelta;
            ms.shortSizeOverEntry = ms.shortSizeOverEntry > soeDelta ? ms.shortSizeOverEntry - soeDelta : 0;
        }
        totalOi -= sizeDelta;
        p.size -= sizeDelta;
        p.entryBorrowIndex = ms.borrowIndex;

        if (p.size == 0) {
            delete positions[key];
        } else {
            uint256 collateralUsd = _toUsd(t, p.collateral, tokenPrice);
            if (collateralUsd < params.minCollateralUsd) revert MinCollateral();
            if (p.size > collateralUsd * cfg.maxLeverageX) revert Leverage();
            if (_liquidatable(p, cfg, ms, isLong, price, tokenPrice)) revert WouldLiquidate();
        }

        collateralHeld[token] -= toPool + collateralDelta;
        uint256 protocol = feeTokens * params.protocolShareBps / BPS;
        protocolFees[token] += protocol;
        poolAmount[token] += toPool - protocol;
        farm.onTradeFee(trader, _toUsd(t, feeTokens, tokenPrice));
        uint256 sameToken = profitTokens == 0 ? 0 : _payProfit(token, profitTokens, tokenPrice, trader);
        _send(token, trader, collateralDelta + sameToken);
        emit PositionDecreased(key, trader, market, isLong, sizeDelta, payout, price, pnlUsd, feeUsd);
    }

    /// @dev Takes trader profit out of the pool in `token`. If the pool is short of that token the remainder is paid
    /// in another pool token at current prices (sent here); returns the same-token part for the caller to send.
    function _payProfit(address token, uint256 amount, uint256 tokenPrice, address trader)
        internal
        returns (uint256 sameToken)
    {
        sameToken = Math.min(amount, poolAmount[token]);
        poolAmount[token] -= sameToken;
        uint256 remainingUsd = _toUsd(tokens[token], amount - sameToken, tokenPrice);
        for (uint256 i = 0; i < tokenList.length && remainingUsd != 0; i++) {
            address other = tokenList[i];
            if (other == token || poolAmount[other] == 0) continue;
            uint256 otherPrice = _tokenPrice(other);
            uint256 want = _toToken(tokens[other], remainingUsd, otherPrice);
            uint256 got = Math.min(want, poolAmount[other]);
            if (got == 0) continue;
            poolAmount[other] -= got;
            uint256 gotUsd = _toUsd(tokens[other], got, otherPrice);
            remainingUsd = gotUsd >= remainingUsd ? 0 : remainingUsd - gotUsd;
            _send(other, trader, got);
        }
        if (remainingUsd != 0) revert InsufficientPool();
    }

    function liquidate(address trader, uint16 market, bool isLong) external nonReentrant whenNotPaused {
        bytes32 key = positionKey(trader, market, isLong);
        Position storage p = positions[key];
        if (p.size == 0) revert NoPosition();
        MarketConfig memory cfg = marketConfigs[market];
        MarketState storage ms = marketStates[market];
        TokenConfig memory t = tokens[p.token];
        _updateBorrow(market);
        (uint256 price,,) = adapter.quote(cfg.price, !isLong);
        uint256 tokenPrice = _tokenPrice(p.token);
        if (!_liquidatable(p, cfg, ms, isLong, price, tokenPrice)) revert NotLiquidatable();

        address token = p.token;
        uint256 size = p.size;
        uint256 collateral = p.collateral;
        int256 pnlUsd = _pnlUsd(p, isLong, size, price);
        uint256 feeUsd = size * cfg.closeFeeBps / BPS + _borrowFeeUsd(p, ms);
        uint256 feeTokens = Math.min(_toToken(t, feeUsd, tokenPrice), collateral);

        // whatever equity is left after pnl and fees pays the liquidator, the rest of the collateral goes to the pool
        uint256 remaining = collateral - feeTokens;
        if (pnlUsd < 0) {
            uint256 loss = _toToken(t, uint256(-pnlUsd), tokenPrice);
            remaining = loss >= remaining ? 0 : remaining - loss;
        }
        uint256 reward = Math.min(remaining, _toToken(t, params.liquidationFeeUsd, tokenPrice));

        uint256 soeDelta = size * USD / p.entryPrice;
        if (isLong) {
            ms.longOi -= size;
            ms.longSizeOverEntry = ms.longSizeOverEntry > soeDelta ? ms.longSizeOverEntry - soeDelta : 0;
        } else {
            ms.shortOi -= size;
            ms.shortSizeOverEntry = ms.shortSizeOverEntry > soeDelta ? ms.shortSizeOverEntry - soeDelta : 0;
        }
        totalOi -= size;
        delete positions[key];

        collateralHeld[token] -= collateral;
        uint256 protocol = feeTokens * params.protocolShareBps / BPS;
        protocolFees[token] += protocol;
        poolAmount[token] += collateral - reward - protocol;
        _send(token, msg.sender, reward);
        emit Liquidated(key, trader, market, isLong, msg.sender, price, reward);
    }

    // ---------- views ----------

    function positionKey(address trader, uint16 market, bool isLong) public pure returns (bytes32) {
        return keccak256(abi.encode(trader, market, isLong));
    }

    function marketCount() external view returns (uint256) {
        return marketConfigs.length;
    }

    function orderCount() external view returns (uint256) {
        return orders.length;
    }

    function positionCount() external view returns (uint256) {
        return positionKeys.length;
    }

    function getMarketConfig(uint16 id) external view returns (MarketConfig memory) {
        return marketConfigs[id];
    }

    function getMarketState(uint16 id) external view returns (MarketState memory) {
        return marketStates[id];
    }

    function getOrder(uint256 id) external view returns (Order memory) {
        return orders[id];
    }

    function getPosition(bytes32 key) external view returns (Position memory) {
        return positions[key];
    }

    /// @notice Current mark (mid) price and whether the stock market is open.
    function markPrice(uint16 market) public view returns (uint256 price, bool open) {
        MarketConfig memory cfg = marketConfigs[market];
        return adapter.mid(cfg.price);
    }

    /// @notice Extra open fee (bps) a trade would pay for the skew it creates. Zero when it trades toward balance.
    function tensionFeeBps(uint16 market, bool isLong, uint256 sizeDelta) public view returns (uint256) {
        MarketState storage ms = marketStates[market];
        uint256 l = ms.longOi + (isLong ? sizeDelta : 0);
        uint256 s = ms.shortOi + (isLong ? 0 : sizeDelta);
        (uint256 heavy, uint256 light) = isLong ? (l, s) : (s, l);
        if (heavy <= light || heavy + light == 0) return 0;
        return marketConfigs[market].tensionFeeMaxBps * (heavy - light) / (heavy + light);
    }

    /// @notice Equity and liquidation status of a position at the current (trader-worst) price.
    function positionHealth(bytes32 key)
        external
        view
        returns (int256 equityUsd, int256 pnlUsd, uint256 feeUsd, uint256 price, bool liquidatable)
    {
        Position storage p = positions[key];
        if (p.size == 0) return (0, 0, 0, 0, false);
        PositionMeta memory meta = positionMeta[key];
        uint16 market = meta.market;
        bool isLong = meta.isLong;
        MarketConfig memory cfg = marketConfigs[market];
        MarketState storage ms = marketStates[market];
        (price,,) = adapter.quote(cfg.price, !isLong);
        uint256 tokenPrice = _tokenPrice(p.token);
        pnlUsd = _pnlUsd(p, isLong, p.size, price);
        feeUsd = p.size * cfg.closeFeeBps / BPS + _pendingBorrowFeeUsd(p, ms, market);
        equityUsd = int256(_toUsd(tokens[p.token], p.collateral, tokenPrice)) + pnlUsd - int256(feeUsd);
        liquidatable = equityUsd < int256(p.size * cfg.maintenanceBps / BPS);
    }

    /// @notice USD value of pool tokens, ignoring open trader PnL.
    function poolTokensUsd() public view returns (uint256 total) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            uint256 amount = poolAmount[token];
            if (amount != 0) total += _toUsd(tokens[token], amount, _tokenPrice(token));
        }
    }

    /// @notice Pool value for LP share pricing: token value minus what traders are currently up.
    function poolValueUsd() public view returns (uint256) {
        int256 value = int256(poolTokensUsd());
        for (uint16 m = 0; m < marketConfigs.length; m++) {
            MarketState storage ms = marketStates[m];
            if (ms.longOi == 0 && ms.shortOi == 0) continue;
            (uint256 price,) = adapter.mid(marketConfigs[m].price);
            int256 longPnl = int256(price * ms.longSizeOverEntry / USD) - int256(ms.longOi);
            int256 shortPnl = int256(ms.shortOi) - int256(price * ms.shortSizeOverEntry / USD);
            value -= longPnl + shortPnl;
        }
        return value <= 0 ? 0 : uint256(value);
    }

    // ---------- internals ----------

    function _pnlUsd(Position storage p, bool isLong, uint256 sizeDelta, uint256 price) internal view returns (int256) {
        int256 diff = int256(price) - int256(p.entryPrice);
        if (!isLong) diff = -diff;
        return diff * int256(sizeDelta) / int256(p.entryPrice);
    }

    function _borrowFeeUsd(Position storage p, MarketState storage ms) internal view returns (uint256) {
        if (p.size == 0) return 0;
        return p.size * (ms.borrowIndex - p.entryBorrowIndex) / USD;
    }

    function _pendingBorrowFeeUsd(Position storage p, MarketState storage ms, uint16 market)
        internal
        view
        returns (uint256)
    {
        if (p.size == 0) return 0;
        uint256 index = ms.borrowIndex + _borrowIndexDelta(market, ms);
        return p.size * (index - p.entryBorrowIndex) / USD;
    }

    function _borrowIndexDelta(uint16 market, MarketState storage ms) internal view returns (uint256) {
        uint256 dt = block.timestamp - ms.lastBorrowUpdate;
        uint256 oi = ms.longOi + ms.shortOi;
        if (dt == 0 || oi == 0) return 0;
        uint256 pool = poolTokensUsd();
        uint256 util = pool == 0 ? USD : Math.min(USD, oi * USD / pool);
        return uint256(marketConfigs[market].borrowRatePerSec) * util / USD * dt;
    }

    function _updateBorrow(uint16 market) internal {
        MarketState storage ms = marketStates[market];
        ms.borrowIndex += _borrowIndexDelta(market, ms);
        ms.lastBorrowUpdate = block.timestamp;
    }

    function _liquidatable(
        Position storage p,
        MarketConfig memory cfg,
        MarketState storage ms,
        bool isLong,
        uint256 price,
        uint256 tokenPrice
    ) internal view returns (bool) {
        int256 pnl = _pnlUsd(p, isLong, p.size, price);
        uint256 fee = p.size * cfg.closeFeeBps / BPS + _borrowFeeUsd(p, ms);
        int256 equity = int256(_toUsd(tokens[p.token], p.collateral, tokenPrice)) + pnl - int256(fee);
        return equity < int256(p.size * cfg.maintenanceBps / BPS);
    }

    function _creditFee(address token, uint256 feeTokens) internal {
        uint256 protocol = feeTokens * params.protocolShareBps / BPS;
        protocolFees[token] += protocol;
        poolAmount[token] += feeTokens - protocol;
    }

    function _token(address token) internal view returns (TokenConfig memory t) {
        t = tokens[token];
        if (!t.enabled) revert BadToken();
    }

    function _tokenPrice(address token) internal view returns (uint256 p) {
        (p,) = tokens[token].source.price();
    }

    function _toUsd(TokenConfig memory t, uint256 amount, uint256 price) internal pure returns (uint256) {
        return amount * price / 10 ** t.decimals;
    }

    function _toToken(TokenConfig memory t, uint256 usd, uint256 price) internal pure returns (uint256) {
        return usd * 10 ** t.decimals / price;
    }

    function _pull(address token, uint256 amount) internal {
        if (token == ETH) {
            if (msg.value != amount) revert BadValue();
        } else {
            if (msg.value != 0) revert BadValue();
            if (amount != 0) IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _send(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == ETH) {
            (bool ok,) = to.call{value: amount, gas: 50_000}("");
            if (!ok) unclaimedEth[to] += amount;
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function claimEth() external nonReentrant {
        uint256 amount = unclaimedEth[msg.sender];
        unclaimedEth[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth send failed");
    }

    function _reasonString(bytes memory reason) internal pure returns (string memory) {
        if (reason.length == 4) {
            bytes4 sel = bytes4(reason);
            if (sel == Slippage.selector) return "slippage";
            if (sel == MarketClosed.selector) return "market closed";
            if (sel == Leverage.selector) return "leverage";
            if (sel == MinCollateral.selector) return "min collateral";
            if (sel == OiCap.selector) return "oi cap";
            if (sel == PoolBacking.selector) return "pool backing";
            if (sel == WouldLiquidate.selector) return "would liquidate";
            if (sel == InsufficientPool.selector) return "insufficient pool";
            if (sel == TokenMismatch.selector) return "token mismatch";
            if (sel == NoPosition.selector) return "no position";
            if (sel == BadAmount.selector) return "bad amount";
        }
        return "execution failed";
    }
}
