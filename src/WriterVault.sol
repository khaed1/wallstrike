// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Wallstrike} from "./Wallstrike.sol";
import {IStakedIMD} from "./interfaces/IStakedIMD.sol";

/// @title WriterVault
/// @notice Writes one Wallstrike product (a strike line and a tenor) automatically, round after round.
///
/// Each round the vault joins one series as a writer with all of its ETH, waits until the series settles,
/// then joins the next series open for deposits. A 7-day series takes 12 days from opening to settlement,
/// so a 7-day vault runs a round every two weeks.
///
/// Shares are priced only between rounds, when everything the vault holds is ETH, so no price oracle is
/// needed:
/// - deposits always wait for the next round and become shares at its starting price;
/// - `withdraw` is instant between rounds. During a round, `requestWithdraw` queues shares to be paid at
///   the round's end (cancellable until the series' auction starts). A round can start only 12 hours after
///   the previous one ended, so every round is followed by a real window to withdraw.
/// The vault joins every series of its product on the terms it opened with: unlike a direct writer, it does
/// not withdraw during the deposit window. ETH the series does not use is returned at the round's end.
/// IMD and sIMD delivered to the vault (exercised tickets, unpaid loans) are not part of the share price.
/// They are paid out to the round's shareholders pro rata, to claim at any time. sIMD only ever moves by
/// transfer.
///
/// No owner and no fee: `startRound` and `endRound` are permissionless.
contract WriterVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IStakedIMD;

    uint256 internal constant ACC = 1e27;
    /// @dev Virtual shares and ETH make a donation to the vault worthless as an attack on depositors.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ETH = 1;
    /// @notice Minimum time between the end of a round and the start of the next, for withdrawals.
    uint256 public constant MIN_IDLE = 12 hours;
    /// @notice A round must put at least this much ETH at risk, so dust cannot occupy the vault.
    uint256 public constant MIN_ROUND_ETH = 0.1 ether;

    struct Account {
        uint256 shares;
        uint256 imdCheckpoint;
        uint256 simdCheckpoint;
        uint256 depositEth; // waiting for round `depositRound`
        uint64 depositRound;
        uint64 withdrawRound; // `withdrawShares` leave at the end of this round
        uint256 withdrawShares;
        uint256 ethOwed; // from queued withdrawals
        uint256 imdOwed;
        uint256 simdOwed;
    }

    /// @dev Share price, IMD and sIMD per share at a round boundary.
    struct Mark {
        uint256 nav; // ETH, plus VIRTUAL_ETH
        uint256 supply; // shares, plus VIRTUAL_SHARES
        uint256 accImd;
        uint256 accSimd;
    }

    Wallstrike public immutable wallstrike;
    IERC20 public immutable imd;
    IStakedIMD public immutable simd;
    uint8 public immutable line;
    uint8 public immutable tenorId;

    /// @notice Shares at risk in the current round, including shares queued to leave at its end.
    uint256 public totalShares;
    /// @notice Number of rounds started. The current round is `round` while `activeSeries != 0`.
    uint64 public round;
    uint256 public activeSeries;
    uint256 public pendingDepositEth;
    uint256 public pendingWithdrawShares;
    /// @notice ETH set aside for processed withdrawals, not yet claimed.
    uint256 public reservedEth;
    uint256 public lastEndedAt;
    /// @notice Cumulative IMD and sIMD per share, scaled by 1e27.
    uint256 public accImd;
    uint256 public accSimd;

    mapping(uint64 => Mark) public startMark;
    mapping(uint64 => Mark) public endMark;
    mapping(uint64 => uint256) public roundSeries;
    mapping(address => Account) internal _accounts;

    event Deposited(address indexed user, uint256 eth, uint64 round);
    event DepositCancelled(address indexed user, uint256 eth);
    event WithdrawQueued(address indexed user, uint256 shares, uint64 round);
    event WithdrawCancelled(address indexed user, uint256 shares, uint64 round);
    event Withdrawn(address indexed user, uint256 shares, uint256 eth);
    event Claimed(address indexed user, uint256 eth, uint256 imd, uint256 simdShares);
    event RoundStarted(uint64 indexed round, uint256 indexed seriesId, uint256 eth, uint256 sharesMinted);
    event RoundEnded(uint64 indexed round, uint256 indexed seriesId, uint256 eth, uint256 imd, uint256 simdShares);

    error ZeroAmount();
    error RoundActive();
    error NoActiveRound();
    error DepositWindowClosed();
    error NothingToDeploy();
    error InsufficientShares();
    error NothingPending();
    error OnlyWallstrike();
    error TooSoon();
    error AuctionStarted();

    constructor(Wallstrike wallstrike_, uint8 line_, uint8 tenorId_) {
        if (line_ >= wallstrike_.LINES() || tenorId_ >= wallstrike_.TENORS()) revert Wallstrike.InvalidLineOrTenor();
        wallstrike = wallstrike_;
        imd = wallstrike_.imd();
        simd = wallstrike_.simd();
        line = line_;
        tenorId = tenorId_;
    }

    /// @dev Only Wallstrike pays ETH in; users deposit through `deposit`.
    receive() external payable {
        if (msg.sender != address(wallstrike)) revert OnlyWallstrike();
    }

    // ------------------------------------------------------------------
    // Users
    // ------------------------------------------------------------------

    /// @notice Queues ETH for the next round. It becomes shares at that round's starting price.
    function deposit() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        Account memory a = _synced(_accounts[msg.sender]);
        a.depositEth += msg.value;
        a.depositRound = round + 1;
        pendingDepositEth += msg.value;
        _accounts[msg.sender] = a;
        emit Deposited(msg.sender, msg.value, round + 1);
    }

    /// @notice Takes back ETH still waiting for a round to start.
    function cancelDeposit() external nonReentrant {
        Account memory a = _synced(_accounts[msg.sender]);
        uint256 eth = a.depositEth;
        if (eth == 0) revert NothingPending();
        a.depositEth = 0;
        a.depositRound = 0;
        pendingDepositEth -= eth;
        _accounts[msg.sender] = a;
        emit DepositCancelled(msg.sender, eth);
        Address.sendValue(payable(msg.sender), eth);
    }

    /// @notice Withdraws shares for ETH at once. Only between rounds; during a round use `requestWithdraw`.
    function withdraw(uint256 shares) external nonReentrant returns (uint256 eth) {
        if (activeSeries != 0) revert RoundActive();
        Account memory a = _takeShares(shares);
        eth = Math.mulDiv(shares, nav() + VIRTUAL_ETH, totalShares + VIRTUAL_SHARES);
        totalShares -= shares;
        _accounts[msg.sender] = a;
        emit Withdrawn(msg.sender, shares, eth);
        Address.sendValue(payable(msg.sender), eth);
    }

    /// @notice During a round, queues shares to leave at its end. They stay at risk until then and are paid
    /// at the round's closing price, with their share of any IMD and sIMD; collect with `claim`.
    function requestWithdraw(uint256 shares) external nonReentrant {
        if (activeSeries == 0) revert NoActiveRound();
        Account memory a = _takeShares(shares);
        a.withdrawShares += shares;
        a.withdrawRound = round;
        pendingWithdrawShares += shares;
        _accounts[msg.sender] = a;
        emit WithdrawQueued(msg.sender, shares, round);
    }

    /// @notice Puts queued shares back in the round, until the series' auction starts.
    function cancelWithdraw() external nonReentrant {
        if (activeSeries == 0) revert NoActiveRound();
        if (block.timestamp >= wallstrike.getSeries(activeSeries).auctionStart) revert AuctionStarted();
        Account memory a = _synced(_accounts[msg.sender]);
        uint256 shares = a.withdrawShares;
        if (shares == 0) revert NothingPending();
        a.withdrawShares = 0;
        a.withdrawRound = 0;
        a.shares += shares;
        pendingWithdrawShares -= shares;
        _accounts[msg.sender] = a;
        emit WithdrawCancelled(msg.sender, shares, round);
    }

    /// @notice Pays out ETH from processed withdrawals and the caller's share of delivered IMD and sIMD.
    function claim() external nonReentrant returns (uint256 eth, uint256 imdOut, uint256 simdOut) {
        Account memory a = _synced(_accounts[msg.sender]);
        (eth, imdOut, simdOut) = (a.ethOwed, a.imdOwed, a.simdOwed);
        a.ethOwed = 0;
        a.imdOwed = 0;
        a.simdOwed = 0;
        reservedEth -= eth;
        _accounts[msg.sender] = a;
        emit Claimed(msg.sender, eth, imdOut, simdOut);
        if (imdOut != 0) imd.safeTransfer(msg.sender, imdOut);
        if (simdOut != 0) simd.safeTransfer(msg.sender, simdOut);
        if (eth != 0) Address.sendValue(payable(msg.sender), eth);
    }

    // ------------------------------------------------------------------
    // Rounds (anyone can call)
    // ------------------------------------------------------------------

    /// @notice Starts a round in this week's series for the vault's product, opening the series if nobody
    /// has yet. Converts queued deposits to shares and deposits all of the vault's ETH as a writer. Needs
    /// `MIN_IDLE` since the last round ended, shares at risk, and at least `MIN_ROUND_ETH`.
    function startRound() external nonReentrant returns (uint256 seriesId) {
        if (activeSeries != 0) revert RoundActive();
        if (block.timestamp < lastEndedAt + MIN_IDLE) revert TooSoon();
        seriesId = wallstrike.seriesByKey(keccak256(abi.encode(block.timestamp / 1 weeks, line, tenorId)));
        if (seriesId == 0) seriesId = wallstrike.openSeries(line, tenorId);
        if (block.timestamp >= wallstrike.getSeries(seriesId).auctionStart) revert DepositWindowClosed();

        uint64 r = ++round;
        Mark memory m = Mark({
            nav: nav() + VIRTUAL_ETH, supply: totalShares + VIRTUAL_SHARES, accImd: accImd, accSimd: accSimd
        });
        startMark[r] = m;
        uint256 minted = Math.mulDiv(pendingDepositEth, m.supply, m.nav);
        totalShares += minted;
        pendingDepositEth = 0;

        uint256 eth = address(this).balance - reservedEth;
        if (totalShares == 0 || eth < MIN_ROUND_ETH) revert NothingToDeploy();
        activeSeries = seriesId;
        roundSeries[r] = seriesId;
        emit RoundStarted(r, seriesId, eth, minted);
        wallstrike.deposit{value: eth}(seriesId);
    }

    /// @notice Ends the round once its series has settled: collects the series' ETH, IMD and sIMD, shares
    /// out the IMD and sIMD, and pays queued withdrawals at the round's closing price.
    function endRound() external nonReentrant {
        uint256 seriesId = activeSeries;
        if (seriesId == 0) revert NoActiveRound();
        if (!wallstrike.releaseClaimed(seriesId, address(this))) wallstrike.claimRelease(seriesId);
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 simdBefore = simd.balanceOf(address(this));
        wallstrike.claim(seriesId); // reverts until the exercise window has closed
        uint256 imdIn = imd.balanceOf(address(this)) - imdBefore;
        uint256 simdIn = simd.balanceOf(address(this)) - simdBefore;

        uint64 r = round;
        activeSeries = 0;
        lastEndedAt = block.timestamp;
        if (totalShares != 0) {
            accImd += Math.mulDiv(imdIn, ACC, totalShares);
            accSimd += Math.mulDiv(simdIn, ACC, totalShares);
        }
        Mark memory m = Mark({
            nav: nav() + VIRTUAL_ETH, supply: totalShares + VIRTUAL_SHARES, accImd: accImd, accSimd: accSimd
        });
        endMark[r] = m;
        reservedEth += Math.mulDiv(pendingWithdrawShares, m.nav, m.supply);
        totalShares -= pendingWithdrawShares;
        pendingWithdrawShares = 0;
        emit RoundEnded(r, seriesId, address(this).balance, imdIn, simdIn);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice ETH that belongs to shareholders: everything except queued deposits and processed
    /// withdrawals. During a round most of it is deposited in the series and not counted here.
    function nav() public view returns (uint256) {
        return address(this).balance - pendingDepositEth - reservedEth;
    }

    /// @notice A user's position with every finished deposit, withdrawal and payout applied.
    function accountOf(address user) external view returns (Account memory) {
        return _synced(_accounts[user]);
    }

    /// @notice ETH value of `shares` between rounds.
    function previewWithdraw(uint256 shares) external view returns (uint256) {
        return Math.mulDiv(shares, nav() + VIRTUAL_ETH, totalShares + VIRTUAL_SHARES);
    }

    /// @dev Syncs the caller's account and removes `shares` from its settled balance.
    function _takeShares(uint256 shares) internal view returns (Account memory a) {
        if (shares == 0) revert ZeroAmount();
        a = _synced(_accounts[msg.sender]);
        if (a.shares < shares) revert InsufficientShares();
        a.shares -= shares;
    }

    /// @dev Applies everything that has happened since the account was last touched: payouts on its
    /// shares, a queued deposit whose round has started, and a queued withdrawal whose round has ended.
    function _synced(Account memory a) internal view returns (Account memory) {
        a.imdOwed += Math.mulDiv(a.shares, accImd - a.imdCheckpoint, ACC);
        a.simdOwed += Math.mulDiv(a.shares, accSimd - a.simdCheckpoint, ACC);
        a.imdCheckpoint = accImd;
        a.simdCheckpoint = accSimd;

        if (a.depositEth != 0 && a.depositRound <= round) {
            Mark memory m = startMark[a.depositRound];
            uint256 shares = Math.mulDiv(a.depositEth, m.supply, m.nav);
            a.imdOwed += Math.mulDiv(shares, accImd - m.accImd, ACC);
            a.simdOwed += Math.mulDiv(shares, accSimd - m.accSimd, ACC);
            a.shares += shares;
            a.depositEth = 0;
            a.depositRound = 0;
        }

        bool ended = a.withdrawRound < round || (a.withdrawRound == round && activeSeries == 0);
        if (a.withdrawShares != 0 && ended) {
            Mark memory s = startMark[a.withdrawRound];
            Mark memory e = endMark[a.withdrawRound];
            a.imdOwed += Math.mulDiv(a.withdrawShares, e.accImd - s.accImd, ACC);
            a.simdOwed += Math.mulDiv(a.withdrawShares, e.accSimd - s.accSimd, ACC);
            a.ethOwed += Math.mulDiv(a.withdrawShares, e.nav, e.supply);
            a.withdrawShares = 0;
            a.withdrawRound = 0;
        }
        return a;
    }
}
