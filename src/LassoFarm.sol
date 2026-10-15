// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LassoFarm — earn $LASSO by providing liquidity and trading on Lasso
/// @notice Two emission streams, both accrued onchain as 1:1 claims on $LASSO:
///  - Liquidity: `lpRate` LASSO per second, split pro-rata over every LLP balance. Holding LLP is enough, no staking.
///  - Trading: `tradeRate` LASSO per second, grouped into UTC-day epochs. Each finished epoch's emission is split
///    pro-rata over the fees each trader paid in it. Fees go to LPs, so every point is paid for.
/// Both streams stop at `end`. Every share rounds down, so the sum of everything users can ever claim is at most
/// `totalEmitted()`. $LASSO launches later on Hooke: the owner sets it once with `setLasso`, funds this contract with
/// `totalEmitted()` and users `claim()`.
contract LassoFarm is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e18;
    uint256 public constant EPOCH = 1 days;

    address public core; // reports trading fees
    address public lpToken; // reports LLP balance changes
    IERC20 public lasso;
    uint64 public immutable start;
    uint64 public end;

    // liquidity stream (Synthetix-style accumulator)
    uint256 public lpRate; // LASSO wei per second
    uint256 public lpTotal;
    uint256 public lpRewardPerToken; // PRECISION-scaled
    uint256 public lpLastUpdate;
    uint256 public lpEmitted; // emitted while lpTotal > 0, up to lpLastUpdate
    mapping(address => uint256) public lpBalance;
    mapping(address => uint256) public lpPaid;

    // trading stream
    uint256 public tradeRate; // LASSO wei per second
    uint256 public tradeEmitted;
    mapping(uint256 => uint256) public epochFees; // USD 1e18 paid in fees per epoch
    mapping(uint256 => uint256) public epochReward; // fixed at the epoch's first fee
    mapping(address => uint256) public traderEpoch; // epoch of the trader's open tally
    mapping(address => uint256) public traderFees; // fees in that epoch

    mapping(address => uint256) public accrued; // settled, unclaimed
    mapping(address => uint256) public claimed;
    uint256 public totalClaimed;

    event Initialized(address core, address lpToken);
    event LassoSet(address lasso);
    event RatesSet(uint256 lpRate, uint256 tradeRate);
    event EndSet(uint64 end);
    event TradeFee(address indexed trader, uint256 indexed epoch, uint256 feeUsd);
    event Claimed(address indexed user, uint256 amount);

    error NotCore();
    error NotLpToken();
    error AlreadySet();
    error NotLive();
    error BadEnd();

    constructor(address owner_, uint256 lpRate_, uint256 tradeRate_, uint64 end_) Ownable(owner_) {
        if (end_ <= block.timestamp) revert BadEnd();
        start = uint64(block.timestamp);
        end = end_;
        lpRate = lpRate_;
        tradeRate = tradeRate_;
        lpLastUpdate = block.timestamp;
    }

    // ---------- admin ----------

    function init(address core_, address lpToken_) external onlyOwner {
        if (core != address(0)) revert AlreadySet();
        core = core_;
        lpToken = lpToken_;
        emit Initialized(core_, lpToken_);
    }

    /// @notice Sets the $LASSO token once it exists. Cannot be changed afterwards.
    function setLasso(IERC20 lasso_) external onlyOwner {
        if (address(lasso) != address(0)) revert AlreadySet();
        lasso = lasso_;
        emit LassoSet(address(lasso_));
    }

    /// @notice New rates apply from now on. Trading epochs that already started keep their emission.
    function setRates(uint256 lpRate_, uint256 tradeRate_) external onlyOwner {
        _updateLp();
        lpRate = lpRate_;
        tradeRate = tradeRate_;
        emit RatesSet(lpRate_, tradeRate_);
    }

    function setEnd(uint64 end_) external onlyOwner {
        if (end_ < block.timestamp) revert BadEnd();
        _updateLp();
        // after a finished season, the gap until now earns nothing
        lpLastUpdate = block.timestamp;
        end = end_;
        emit EndSet(end_);
    }

    // ---------- hooks ----------

    /// @dev Called by LLP on every mint, burn and transfer, before balances change.
    function onLpTransfer(address from, address to, uint256 amount) external {
        if (msg.sender != lpToken) revert NotLpToken();
        _updateLp();
        if (from == address(0)) {
            lpTotal += amount;
        } else {
            _settleLp(from);
            lpBalance[from] -= amount;
        }
        if (to == address(0)) {
            lpTotal -= amount;
        } else {
            _settleLp(to);
            lpBalance[to] += amount;
        }
    }

    /// @dev Called by the core whenever a trader pays fees (USD 1e18).
    function onTradeFee(address trader, uint256 feeUsd) external {
        if (msg.sender != core) revert NotCore();
        if (feeUsd == 0 || block.timestamp >= end) return;
        uint256 e = currentEpoch();
        _settleTrader(trader);
        if (epochFees[e] == 0) {
            uint256 reward = epochEmission(e);
            epochReward[e] = reward;
            tradeEmitted += reward;
        }
        epochFees[e] += feeUsd;
        traderEpoch[trader] = e;
        traderFees[trader] += feeUsd;
        emit TradeFee(trader, e, feeUsd);
    }

    // ---------- claim ----------

    function claim() external returns (uint256 amount) {
        if (address(lasso) == address(0)) revert NotLive();
        _updateLp();
        _settleLp(msg.sender);
        _settleTrader(msg.sender);
        amount = accrued[msg.sender];
        accrued[msg.sender] = 0;
        claimed[msg.sender] += amount;
        totalClaimed += amount;
        lasso.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ---------- views ----------

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH;
    }

    /// @notice LASSO emitted to traders for epoch `e`: tradeRate times the part of the day inside the season.
    function epochEmission(uint256 e) public view returns (uint256) {
        uint256 from = Math.max(e * EPOCH, start);
        uint256 to = Math.min((e + 1) * EPOCH, end);
        return to > from ? tradeRate * (to - from) : 0;
    }

    /// @notice Upper bound of everything users can ever claim so far. Fund the farm with at least this.
    function totalEmitted() external view returns (uint256) {
        uint256 t = Math.min(block.timestamp, end);
        uint256 pending = lpTotal != 0 && t > lpLastUpdate ? lpRate * (t - lpLastUpdate) : 0;
        return lpEmitted + pending + tradeEmitted;
    }

    /// @return claimable LASSO earned so far (liquidity + finished trading epochs)
    /// @return today the trader's share of the running epoch at current fees, final when the epoch ends
    function earned(address user) external view returns (uint256 claimable, uint256 today) {
        claimable = accrued[user] + Math.mulDiv(lpBalance[user], _lpRewardPerToken() - lpPaid[user], PRECISION);
        uint256 f = traderFees[user];
        if (f != 0) {
            uint256 e = traderEpoch[user];
            uint256 share = Math.mulDiv(epochReward[e], f, epochFees[e]);
            if (e < currentEpoch()) claimable += share;
            else today = share;
        }
    }

    // ---------- internals ----------

    function _lpRewardPerToken() internal view returns (uint256) {
        uint256 t = Math.min(block.timestamp, end);
        if (lpTotal == 0 || t <= lpLastUpdate) return lpRewardPerToken;
        return lpRewardPerToken + Math.mulDiv(lpRate * (t - lpLastUpdate), PRECISION, lpTotal);
    }

    function _updateLp() internal {
        uint256 t = Math.min(block.timestamp, end);
        if (t <= lpLastUpdate) return;
        if (lpTotal != 0) {
            lpRewardPerToken = _lpRewardPerToken();
            lpEmitted += lpRate * (t - lpLastUpdate);
        }
        lpLastUpdate = t;
    }

    function _settleLp(address user) internal {
        uint256 rpt = lpRewardPerToken;
        accrued[user] += Math.mulDiv(lpBalance[user], rpt - lpPaid[user], PRECISION);
        lpPaid[user] = rpt;
    }

    function _settleTrader(address user) internal {
        uint256 f = traderFees[user];
        if (f == 0) return;
        uint256 e = traderEpoch[user];
        if (e >= currentEpoch()) return; // epoch still running
        accrued[user] += Math.mulDiv(epochReward[e], f, epochFees[e]);
        traderFees[user] = 0;
    }
}
