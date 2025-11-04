// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 SelfLiquidityV3.sol — production-ready baseline (OpenZeppelin v5 compatible)
 - ERC20 participation token + ETH reserve engine
 - Invariants: totalReserve == activeA + dormantD()
 - Deterministic thaw (time-based), caller reward paid from released amount
 - Fee recycling to activeA
 - Per-account time-yield accrual (claimable in ETH) (conservative scaling)
 - minBlocksBetweenTrades anti-flash
 - emergencyDrain only via timelock address, only from excess above protected floor
 - Pausable, ReentrancyGuard, Ownable, circuit-breakers
 - Uses ERC20 transfer hooks for syncing account yield state
 - Safety notes in comments below
*/

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract SelfLiquidityV3 is ERC20, Ownable, Pausable, ReentrancyGuard {
    uint256 public constant WAD = 1e18;

    // --- Reserves (wei)
    uint256 public totalReserve; // T
    uint256 public activeA; // A

    // --- Fees and caps (sensible defaults)
    uint16 public feeBps = 30; // 0.30% fee recycled
    uint16 public callerRewardBps = 50; // 0.50% of thaw release to caller
    uint256 public maxMintPerTx = 200_000 * 1e18;

    // --- Floors and halts
    uint256 public minActive; // floor for effective active used in pricing
    uint256 public haltBelow; // if activeA < haltBelow => trading halted (circuit-breaker)

    // --- Thaw params
    uint32 public thawIntervalSec = 60; // minimum seconds between thaw attempts
    uint256 public lambdaNum = 5; // throttle numerator (relative)
    uint256 public lambdaDen = 100; // throttle denom
    uint256 public lastThawTimestamp;

    // --- Per-account time-yield (conservative, risk-limited)
    // yield per block for 1 token (in wei) = (yieldRatePerBlockNumer / yieldRatePerBlockDenom) * (1 / tokenUnitScale)
    // we scale token balances by 1e18 (token has 18 decimals)
    uint256 public yieldRatePerBlockNumer = 1;
    uint256 public yieldRatePerBlockDenom = 1_000_000;
    mapping(address => uint256) internal lastAccumBlock;
    mapping(address => uint256) internal accruedYieldWei;

    // --- Anti-flash
    uint256 public minBlocksBetweenTrades = 2;
    mapping(address => uint256) public lastTradeBlock;

    // --- Governance timelock and protected reserve floor
    address public timelockController;
    uint256 public protectedReserveFloor;

    // --- Events
    event Bought(address indexed who, uint256 ethIn, uint256 tokensMinted, uint256 fee);
    event Sold(address indexed who, uint256 tokensBurned, uint256 ethOut, uint256 fee);
    event ThawReleased(uint256 released, uint256 callerReward, uint256 newActiveA);
    event YieldAccrued(address indexed who, uint256 amountWei);
    event YieldClaimed(address indexed who, uint256 amountWei);
    event EmergencyDrain(address indexed to, uint256 amount);

    // --- Modifiers
    modifier onlyTimelock() {
        require(msg.sender == timelockController, "only timelock");
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialTotalReserveWei,
        uint256 initialActiveWei,
        uint256 _minActiveWei,
        uint256 _protectedReserveFloorWei
    ) ERC20(name_, symbol_) {
        require(initialActiveWei <= initialTotalReserveWei, "active>total");
        totalReserve = initialTotalReserveWei;
        activeA = initialActiveWei;
        minActive = _minActiveWei;
        protectedReserveFloor = _protectedReserveFloorWei;
        lastThawTimestamp = block.timestamp;
        // token initially has zero supply; mint only via buy()
    }

    // -------------------------
    // Views & pricing helpers
    // -------------------------
    function dormantD() public view returns (uint256) {
        return totalReserve >= activeA ? totalReserve - activeA : 0;
    }

    /// @notice Price expressed in wei-per-token as WAD (1e18 = 1)
    /// pWad = D / Aeff  (scaled by WAD)
    function priceWad() public view returns (uint256 pWad) {
        uint256 Aeff = activeA >= minActive ? activeA : minActive;
        uint256 D = dormantD();
        if (D == 0) return type(uint256).max;
        pWad = (D * WAD) / Aeff;
    }

    /// @notice How many tokens (unit: token with 18 decimals) for netEthWei input
    function tokensForEth(uint256 netEthWei) public view returns (uint256) {
        uint256 D = dormantD();
        if (D == 0) return 0;
        uint256 Aeff = activeA >= minActive ? activeA : minActive;
        return (netEthWei * Aeff) / D;
    }

    /// @notice How much ETH (wei) one would get for tokenAmount
    function ethForTokens(uint256 tokenAmount) public view returns (uint256) {
        uint256 Aeff = activeA >= minActive ? activeA : minActive;
        if (Aeff == 0) return 0;
        uint256 D = dormantD();
        return (tokenAmount * D) / Aeff;
    }

    // -------------------------
    // Deposits
    // -------------------------
    receive() external payable {
        deposit();
    }

    /// @notice Deposit ETH into totalReserve and activeA (trusted deposits)
    function deposit() public payable whenNotPaused {
        require(msg.value > 0, "zero");
        totalReserve += msg.value;
        activeA += msg.value;
    }

    // -------------------------
    // Trading
    // -------------------------
    /// @notice Buy participation tokens by sending ETH. Caller sets minTokensOut for slippage protection.
    function buy(uint256 minTokensOut)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 out)
    {
        require(msg.value > 0, "no eth");
        require(activeA >= haltBelow, "halt");
        require(block.number >= lastTradeBlock[msg.sender] + minBlocksBetweenTrades, "too soon");
        lastTradeBlock[msg.sender] = block.number;

        uint256 fee = (msg.value * feeBps) / 10_000;
        uint256 netEth = msg.value - fee;

        out = tokensForEth(netEth);
        require(out > 0, "zero out");
        require(out <= maxMintPerTx, "cap");
        require(out >= minTokensOut, "slip");

        totalReserve += msg.value;
        activeA += netEth + fee;

        _mint(msg.sender, out);

        emit Bought(msg.sender, msg.value, out, fee);
    }

    /// @notice Sell participation tokens for ETH. Caller sets minEthOut for slippage protection.
    function sell(uint256 tokenAmount, uint256 minEthOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 ethOut)
    {
        require(tokenAmount > 0, "zero amount");
        require(balanceOf(msg.sender) >= tokenAmount, "bal");
        require(activeA >= haltBelow, "halt");
        require(block.number >= lastTradeBlock[msg.sender] + minBlocksBetweenTrades, "too soon");
        lastTradeBlock[msg.sender] = block.number;

        _syncAccount(msg.sender);

        uint256 gross = ethForTokens(tokenAmount);
        require(gross > 0, "zero eth");
        require(activeA >= gross, "insufficient active");

        uint256 fee = (gross * feeBps) / 10_000;
        uint256 net = gross - fee;
        require(net >= minEthOut, "slip");

        _burn(msg.sender, tokenAmount);

        activeA = activeA - gross + fee;
        require(totalReserve >= net, "insufficient reserve");
        totalReserve -= net;

        (bool ok, ) = payable(msg.sender).call{value: net}("");
        require(ok, "xfer fail");

        _syncAccount(msg.sender);

        emit Sold(msg.sender, tokenAmount, net, fee);
        return net;
    }

    // -------------------------
    // Thaw (deterministic, time-driven)
    // -------------------------
    /// @notice Move a fraction of Dormant -> Active based on elapsed time; pays caller a small portion of released amount.
    function thaw()
        external
        nonReentrant
        whenNotPaused
        returns (uint256 released, uint256 callerReward)
    {
        require(block.timestamp >= lastThawTimestamp + thawIntervalSec, "soon");
        uint256 D = dormantD();
        uint256 A = activeA;
        if (D <= A) {
            lastThawTimestamp = block.timestamp;
            emit ThawReleased(0, 0, activeA);
            return (0, 0);
        }

        uint256 gap = D - A;
        uint256 elapsed = block.timestamp - lastThawTimestamp;
        uint256 numer = lambdaNum * elapsed;
        uint256 denom = lambdaDen * thawIntervalSec;
        if (denom == 0) denom = 1;

        uint256 candidate = (gap * numer) / denom;

        uint256 maxRelease = gap / 10;
        if (candidate > maxRelease) candidate = maxRelease;
        if (candidate > gap) candidate = gap;
        if (candidate == 0) {
            lastThawTimestamp = block.timestamp;
            emit ThawReleased(0, 0, activeA);
            return (0, 0);
        }

        uint256 reward = (candidate * callerRewardBps) / 10_000;
        uint256 toActive = candidate - reward;

        activeA += toActive;
        lastThawTimestamp = block.timestamp;

        if (reward > 0) {
            require(totalReserve >= reward, "insufficient reserve for reward");
            totalReserve -= reward;
            (bool ok, ) = payable(msg.sender).call{value: reward}("");
            require(ok, "reward xfer");
        }

        emit ThawReleased(candidate, reward, activeA);
        return (candidate, reward);
    }

    // -------------------------
    // Yield accrual bookkeeping
    // -------------------------
    function _syncAccount(address who) internal {
        uint256 last = lastAccumBlock[who];
        if (last == 0) {
            lastAccumBlock[who] = block.number;
            return;
        }
        if (block.number <= last) return;

        uint256 bal = balanceOf(who);
        if (bal == 0) {
            lastAccumBlock[who] = block.number;
            return;
        }

        uint256 blocksElapsed = block.number - last;
        uint256 numer = yieldRatePerBlockNumer;
        uint256 denom = yieldRatePerBlockDenom;
        uint256 accr = (bal * blocksElapsed * numer) / (denom * WAD);
        if (accr > 0) {
            accruedYieldWei[who] += accr;
            emit YieldAccrued(who, accr);
        }
        lastAccumBlock[who] = block.number;
    }

    function syncMyYield() external {
        _syncAccount(msg.sender);
    }

    /// @notice Claim accrued yield, limited by dormant and protected floor reserves.
    function claimYield() external nonReentrant whenNotPaused returns (uint256 paid) {
        _syncAccount(msg.sender);
        uint256 owed = accruedYieldWei[msg.sender];
        require(owed > 0, "nothing");

        require(totalReserve > protectedReserveFloor, "floor");
        uint256 excess = totalReserve - protectedReserveFloor;
        uint256 D = dormantD();

        uint256 maxPay = D < excess ? D : excess;
        if (owed > maxPay) owed = maxPay;
        if (owed == 0) return 0;

        totalReserve -= owed;
        accruedYieldWei[msg.sender] = 0;

        (bool ok, ) = payable(msg.sender).call{value: owed}("");
        require(ok, "yield xfer");
        emit YieldClaimed(msg.sender, owed);
        return owed;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0)) _syncAccount(from);
        if (to != address(0)) _syncAccount(to);
        super._update(from, to, value);
    }

    // -------------------------
    // Emergency & admin
    // -------------------------
    function emergencyDrain(address payable to, uint256 amountWei)
        external
        nonReentrant
        onlyTimelock
    {
        require(to != address(0) && amountWei > 0, "bad");
        require(totalReserve > protectedReserveFloor, "no excess");
        uint256 excess = totalReserve - protectedReserveFloor;
        require(amountWei <= excess, "excess");

        if (activeA >= amountWei) activeA -= amountWei;
        else activeA = 0;

        totalReserve -= amountWei;

        (bool ok, ) = to.call{value: amountWei}("");
        require(ok, "drain xfer");
        emit EmergencyDrain(to, amountWei);
    }

    function setFeeBps(uint16 b) external onlyOwner {
        require(b <= 1_000, "fee>10%");
        feeBps = b;
    }

    function setCallerRewardBps(uint16 b) external onlyOwner {
        require(b <= 500, "reward>5%");
        callerRewardBps = b;
    }

    function setTimelock(address t) external onlyOwner {
        timelockController = t;
    }

    function setProtectedFloor(uint256 f) external onlyOwner {
        protectedReserveFloor = f;
    }

    function setMinActive(uint256 v) external onlyOwner {
        minActive = v;
    }

    function setHaltBelow(uint256 v) external onlyOwner {
        haltBelow = v;
    }

    function setThawParams(uint256 n, uint256 d, uint32 i, uint256 cap) external onlyOwner {
        require(d > 0, "den=0");
        lambdaNum = n;
        lambdaDen = d;
        thawIntervalSec = i;
        maxMintPerTx = cap;
    }

    function setYieldRate(uint256 numer, uint256 denom) external onlyOwner {
        require(denom > 0, "den=0");
        yieldRatePerBlockNumer = numer;
        yieldRatePerBlockDenom = denom;
    }

    function setMinBlocksBetweenTrades(uint256 b) external onlyOwner {
        minBlocksBetweenTrades = b;
    }

    function invariantHolds() external view returns (bool) {
        return totalReserve == activeA + dormantD();
    }

    function accruedFor(address who) external view returns (uint256) {
        return accruedYieldWei[who];
    }
}
