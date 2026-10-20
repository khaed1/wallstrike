// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ICappedBurnHook} from "./interfaces/ICappedBurnHook.sol";
import {IStakedIMD} from "./interfaces/IStakedIMD.sol";
import {ImdPriceRecorder} from "./ImdPriceRecorder.sol";
import {TickPrice} from "./libraries/TickPrice.sol";
import {OptionMath} from "./libraries/OptionMath.sol";

/// @title Wallstrike
/// @notice Reserved exits for IMD and sIMD holders.
///
/// Every week anyone can open a series per strike line and tenor. Its strike is fixed at opening from the
/// 7-day mean price and the top of POOL4's buy wall. ETH writers deposit for one day, then buyers have one
/// day to:
/// - buy Exit Tickets (ERC-1155, id = series id): the right, after expiry, to deliver IMD (or sIMD) and
///   receive the strike in ETH; or
/// - take a Floor Loan: post sIMD, receive ETH, no price liquidation. An unpaid loan's sIMD goes to the
///   writers.
/// Premiums sell in a Dutch auction from twice a Black-Scholes floor down to the floor. The floor is
/// re-priced at every sale from the lower of POOL4's refTick price and the main pool's price, so a fall
/// during the deposit window or the auction is always charged for.
///
/// Every ticket is fully backed by ETH locked at purchase, settlement is physical, and sIMD only ever
/// moves by transfer (sIMD's one-block hold blocks redeems, never transfers). The owner (intended to be
/// a timelock) can change caps and fees for future series and pause new series, deposits, sales and
/// loans; a guardian can pause at once. Neither can touch an existing series, ticket, loan or writer
/// balance, and exercise, repay, finalize and claims always stay open.
contract Wallstrike is ERC1155, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IStakedIMD;

    // --- schedule ---
    uint256 public constant DEPOSIT_WINDOW = 1 days;
    uint256 public constant AUCTION = 1 days;
    uint256 public constant EXERCISE_WINDOW = 72 hours;
    uint8 public constant LINES = 2;
    uint8 public constant TENORS = 2;

    // --- price windows (30-minute recorder slots) ---
    uint256 public constant MEAN_SLOTS = 336; // 7 days
    uint256 public constant MEAN_MIN_VALID = 252; // 75%
    uint256 public constant VOL_MIN_PAIRS = 200;
    uint256 public constant SPOT_SLOTS = 48; // 24 hours
    uint256 public constant SPOT_MIN_VALID = 36; // 75%
    /// @notice The wall can lower a line's strike by at most 20% (2232 ticks).
    int256 public constant MAX_WALL_BELOW_LINE = 2232;
    /// @notice Pricing volatility is at least 125% of the 7-day realized volatility of refTick.
    uint256 public constant VOL_MARKUP_BPS = 12_500;

    // --- bounds on owner settings ---
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 2000;
    uint256 public constant MAX_LOAN_FEE_BPS = 1000;
    uint256 public constant MAX_LOAN_LTV_BPS = 5000;
    uint256 public constant MIN_SIGMA = 1e18;
    uint256 public constant MAX_SIGMA = 5e18;
    uint256 public constant MIN_FLOOR_RATE = 0.005e18;
    uint256 public constant MAX_FLOOR_RATE = 0.9e18;
    /// @notice Loans value sIMD at no more than its rate at opening plus 1%.
    uint256 public constant SIMD_RATE_TOLERANCE_BPS = 100;

    struct Series {
        uint64 auctionStart;
        uint64 expiry;
        uint8 line;
        uint8 tenorId;
        bool finalized;
        uint16 protocolFeeBps;
        uint16 loanFeeBps;
        uint16 loanLtvBps;
        uint256 strike; // wei of ETH per 1e18 IMD
        uint256 sigma; // pricing volatility, 1e18 = 100%
        uint256 floorRate; // premium floor at opening, as a fraction of strike notional
        uint256 simdRate; // sIMD rate at opening, IMD per 1e24 shares
        uint256 depositCap; // most writer ETH that can be put at risk; any excess is released
        uint256 deposits; // writer shares, 1 wei of ETH each
        uint256 ticketCollateral; // ETH locked behind sold tickets
        uint256 premiums; // writers' share of premiums
        uint256 loanFees; // writers' share of loan fees
        uint256 loanPrincipal; // ETH lent
        uint256 loanRepaid; // ETH repaid
        uint256 loanRepaidInAuction; // ETH repaid before the auction ended, released with unused capacity
        uint256 loanCollateral; // sIMD shares held for open loans
        uint256 exercisePaid; // ETH paid to ticket holders
        uint256 imdDelivered;
        uint256 simdDelivered;
        uint256 finalEth;
        uint256 finalSimd;
    }

    struct Loan {
        address borrower;
        uint64 seriesId;
        bool closed;
        uint256 shares;
        uint256 principal;
    }

    IERC20 public immutable imd;
    IStakedIMD public immutable simd;
    ICappedBurnHook public immutable hook;
    ImdPriceRecorder public immutable recorder;

    uint256 public seriesCount;
    mapping(uint256 => Series) internal series;
    /// @notice Series id by keccak256(week, line, tenorId); one series per line and tenor per week.
    mapping(bytes32 => uint256) public seriesByKey;
    mapping(uint256 => mapping(address => uint256)) public writerDeposit;
    mapping(uint256 => mapping(address => bool)) public releaseClaimed;
    mapping(uint256 => mapping(address => bool)) public finalClaimed;
    mapping(uint256 => mapping(address => uint256)) public ticketCollateralOf;

    uint256 public loanCount;
    mapping(uint256 => Loan) public loans;

    uint256 public openTicketCollateral;
    uint256 public openLoanPrincipal;

    // --- owner settings ---
    uint256 public maxSeriesDeposits = 10 ether;
    uint256 public maxAccountCollateral = 2.5 ether;
    uint256 public maxOpenTicketCollateral = 25 ether;
    uint256 public maxOpenLoanPrincipal = 10 ether;
    uint256 public maxLoanPrincipal = 1 ether;
    uint256 public loanLtvBps = 3500;
    uint256 public loanFeeBps = 300;
    uint256 public protocolFeeBps = 1000;
    uint256 public sigmaFloor = 2e18;
    bool public paused;
    address public guardian;
    address public feeRecipient;
    uint256 public feesAccrued;

    event SeriesOpened(
        uint256 indexed id,
        uint8 line,
        uint8 tenorId,
        uint256 strike,
        uint256 sigma,
        uint256 floorRate,
        uint256 auctionStart,
        uint256 expiry
    );
    event Deposited(uint256 indexed id, address indexed writer, uint256 amount);
    event DepositWithdrawn(uint256 indexed id, address indexed writer, uint256 amount);
    event TicketsBought(uint256 indexed id, address indexed buyer, uint256 imdAmount, uint256 premium);
    event Exercised(uint256 indexed id, address indexed holder, uint256 imdAmount, bool inSimd, uint256 delivered, uint256 paid);
    event Borrowed(uint256 indexed loanId, uint256 indexed id, address indexed borrower, uint256 shares, uint256 principal, uint256 fee);
    event Repaid(uint256 indexed loanId, address indexed payer);
    event Finalized(uint256 indexed id, uint256 finalEth, uint256 imd, uint256 finalSimd);
    event ReleaseClaimed(uint256 indexed id, address indexed writer, uint256 eth);
    event Claimed(uint256 indexed id, address indexed writer, uint256 eth, uint256 imd, uint256 simdShares);
    event SettingsUpdated();
    event PausedSet(bool paused);
    event FeesWithdrawn(address indexed to, uint256 amount);

    error Paused();
    error NotGuardian();
    error InvalidLineOrTenor();
    error SeriesExists();
    error UnknownSeries();
    error PoolUnhealthy();
    error NotInWindow();
    error CapExceeded();
    error Slippage();
    error ZeroAmount();
    error LoanClosed();
    error WrongAmount();
    error NothingToClaim();
    error InvalidSetting();

    constructor(
        IERC20 imd_,
        IStakedIMD simd_,
        ICappedBurnHook hook_,
        ImdPriceRecorder recorder_,
        address owner_,
        address feeRecipient_,
        address guardian_
    ) ERC1155("") Ownable(owner_) {
        if (simd_.asset() != address(imd_) || address(recorder_.hook()) != address(hook_)) revert InvalidSetting();
        if (address(recorder_.simd()) != address(simd_) || feeRecipient_ == address(0)) revert InvalidSetting();
        imd = imd_;
        simd = simd_;
        hook = hook_;
        recorder = recorder_;
        feeRecipient = feeRecipient_;
        guardian = guardian_;
    }

    // ------------------------------------------------------------------
    // Series
    // ------------------------------------------------------------------

    /// @notice Opens this week's series for a strike line and tenor. Anyone can call it.
    /// @param line 0: strike at 80% of the 7-day mean, 1: at 60%; capped by the buy wall's 24h median.
    /// @param tenorId 0: 7 days, 1: 30 days, counted from the end of the auction.
    function openSeries(uint8 line, uint8 tenorId) external returns (uint256 id) {
        if (paused) revert Paused();
        if (line >= LINES || tenorId >= TENORS) revert InvalidLineOrTenor();
        bytes32 key = keccak256(abi.encode(block.timestamp / 1 weeks, line, tenorId));
        if (seriesByKey[key] != 0) revert SeriesExists();
        if (!recorder.healthy()) revert PoolUnhealthy();

        (uint256 strike, uint256 spot) = _strikeAndSpot(line);
        uint256 sigma = Math.max(sigmaFloor, recorder.realizedVol(MEAN_SLOTS, VOL_MIN_PAIRS) * VOL_MARKUP_BPS / 10_000);
        uint256 tenor = tenorSeconds(tenorId);
        uint256 floorRate = OptionMath.putRate(spot, strike, sigma, tenor + AUCTION + EXERCISE_WINDOW);

        id = ++seriesCount;
        seriesByKey[key] = id;
        Series storage s = series[id];
        s.auctionStart = uint64(block.timestamp + DEPOSIT_WINDOW);
        s.expiry = uint64(block.timestamp + DEPOSIT_WINDOW + AUCTION + tenor);
        s.line = line;
        s.tenorId = tenorId;
        s.protocolFeeBps = uint16(protocolFeeBps);
        s.loanFeeBps = uint16(loanFeeBps);
        s.loanLtvBps = uint16(loanLtvBps);
        s.strike = strike;
        s.sigma = sigma;
        s.floorRate = Math.min(Math.max(floorRate, MIN_FLOOR_RATE), MAX_FLOOR_RATE);
        s.simdRate = simd.convertToAssets(1e24);
        s.depositCap = maxSeriesDeposits;
        emit SeriesOpened(id, line, tenorId, strike, sigma, s.floorRate, s.auctionStart, s.expiry);
    }

    /// @notice The strike and the 24h mean price a series would open with now, in wei of ETH per 1e18 IMD.
    function previewStrike(uint8 line) external view returns (uint256 strike, uint256 spot) {
        if (line >= LINES) revert InvalidLineOrTenor();
        return _strikeAndSpot(line);
    }

    /// @dev The line's strike, lowered to the buy wall when the wall sits below the market and below the
    /// line, by at most 20%. The wall reading is its 24h 25th percentile toward the higher price, so it has to
    /// be held for 18 hours to count. A wall at or above the market (being filled) is ignored. Moving the wall
    /// can therefore never block a series, and lowers a strike by 20% at most.
    function _strikeAndSpot(uint8 line) internal view returns (uint256 strike, uint256 spot) {
        int24 meanTick = recorder.meanTick(MEAN_SLOTS, MEAN_MIN_VALID);
        int24 spotTick = recorder.meanTick(SPOT_SLOTS, SPOT_MIN_VALID);
        int24 wallTick = recorder.lowWallTick(SPOT_SLOTS, SPOT_MIN_VALID);
        // A higher tick is a lower IMD price, so the larger tick is the lower strike.
        int256 lineTick = int256(meanTick) + lineOffset(line);
        int256 strikeTick = lineTick;
        if (wallTick > spotTick && wallTick > lineTick) {
            int256 lowest = lineTick + MAX_WALL_BELOW_LINE;
            strikeTick = wallTick < lowest ? wallTick : lowest;
        }
        if (strikeTick > TickMath.MAX_TICK) strikeTick = TickMath.MAX_TICK;
        strike = TickPrice.ethPerImd(int24(strikeTick));
        spot = TickPrice.ethPerImd(spotTick);
    }

    /// @notice Ticks between the 7-day mean and a line's strike: ceil(-ln(k) / ln(1.0001)).
    function lineOffset(uint8 line) public pure returns (int256) {
        return line == 0 ? int256(2232) : int256(5109); // k = 0.80, k = 0.60
    }

    function tenorSeconds(uint8 tenorId) public pure returns (uint256) {
        return tenorId == 0 ? 7 days : 30 days;
    }

    /// @notice Premium rate (fraction of strike notional) now: twice the floor at the start of the auction,
    /// falling linearly to the floor at its end. The floor is the larger of the floor at opening and the
    /// put's value at the current pessimistic price until the exercise window closes (holders can pick when
    /// to exercise within it).
    function premiumRate(uint256 id) public view returns (uint256) {
        Series storage s = _series(id);
        _requireAuction(s);
        uint256 spot = TickPrice.ethPerImd(recorder.pessimisticTick());
        uint256 floorRate =
            Math.max(s.floorRate, OptionMath.putRate(spot, s.strike, s.sigma, s.expiry + EXERCISE_WINDOW - block.timestamp));
        uint256 remaining = s.auctionStart + AUCTION - block.timestamp;
        return floorRate + Math.mulDiv(floorRate, remaining, AUCTION);
    }

    // ------------------------------------------------------------------
    // Writers
    // ------------------------------------------------------------------

    /// @notice Adds ETH to a series' writer pool during its deposit window. There is no first-come limit:
    /// if deposits exceed the series cap, every writer is put at risk pro rata and the excess is released
    /// after the auction.
    function deposit(uint256 id) external payable nonReentrant {
        if (paused) revert Paused();
        if (msg.value == 0) revert ZeroAmount();
        Series storage s = _series(id);
        if (block.timestamp >= s.auctionStart) revert NotInWindow();
        s.deposits += msg.value;
        writerDeposit[id][msg.sender] += msg.value;
        emit Deposited(id, msg.sender, msg.value);
    }

    /// @notice Takes ETH back out before the auction starts.
    function withdrawDeposit(uint256 id, uint256 amount) external nonReentrant {
        Series storage s = _series(id);
        if (block.timestamp >= s.auctionStart) revert NotInWindow();
        writerDeposit[id][msg.sender] -= amount;
        s.deposits -= amount;
        emit DepositWithdrawn(id, msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }

    /// @notice After the auction, returns the writer's share of the ETH no ticket or open loan used.
    function claimRelease(uint256 id) external nonReentrant returns (uint256 amount) {
        Series storage s = _series(id);
        if (block.timestamp < s.auctionStart + AUCTION) revert NotInWindow();
        if (releaseClaimed[id][msg.sender]) revert NothingToClaim();
        releaseClaimed[id][msg.sender] = true;
        amount = Math.mulDiv(writerDeposit[id][msg.sender], releasedEth(id), s.deposits == 0 ? 1 : s.deposits);
        emit ReleaseClaimed(id, msg.sender, amount);
        if (amount != 0) Address.sendValue(payable(msg.sender), amount);
    }

    /// @notice Writer ETH not backing a ticket or a loan still open at the end of the auction. Final once
    /// the auction has ended.
    function releasedEth(uint256 id) public view returns (uint256) {
        Series storage s = series[id];
        return s.deposits - s.ticketCollateral - (s.loanPrincipal - s.loanRepaidInAuction);
    }

    /// @notice ETH a sale or loan can still put at risk in a series.
    function capacityLeft(uint256 id) public view returns (uint256) {
        Series storage s = series[id];
        uint256 cap = Math.min(s.deposits, s.depositCap);
        uint256 used = s.ticketCollateral + s.loanPrincipal - s.loanRepaid;
        return cap > used ? cap - used : 0;
    }

    /// @notice Freezes a series' final balances once its exercise window has closed. Anyone can call it;
    /// `claim` calls it too. Unpaid loans' sIMD goes to the writers.
    function finalize(uint256 id) public {
        Series storage s = _series(id);
        if (s.finalized) return;
        if (block.timestamp < s.expiry + EXERCISE_WINDOW) revert NotInWindow();
        s.finalized = true;
        s.finalEth = s.ticketCollateral + s.premiums + s.loanFees + s.loanRepaid - s.loanRepaidInAuction - s.exercisePaid;
        s.finalSimd = s.simdDelivered + s.loanCollateral;
        openTicketCollateral -= s.ticketCollateral;
        openLoanPrincipal -= s.loanPrincipal - s.loanRepaid;
        emit Finalized(id, s.finalEth, s.imdDelivered, s.finalSimd);
    }

    /// @notice Pays a writer's pro rata share of the final ETH, delivered IMD and sIMD.
    function claim(uint256 id) external nonReentrant returns (uint256 eth, uint256 imdOut, uint256 simdOut) {
        finalize(id);
        Series storage s = series[id];
        uint256 shares = writerDeposit[id][msg.sender];
        if (shares == 0 || finalClaimed[id][msg.sender]) revert NothingToClaim();
        finalClaimed[id][msg.sender] = true;
        eth = Math.mulDiv(shares, s.finalEth, s.deposits);
        imdOut = Math.mulDiv(shares, s.imdDelivered, s.deposits);
        simdOut = Math.mulDiv(shares, s.finalSimd, s.deposits);
        emit Claimed(id, msg.sender, eth, imdOut, simdOut);
        if (imdOut != 0) imd.safeTransfer(msg.sender, imdOut);
        if (simdOut != 0) simd.safeTransfer(msg.sender, simdOut);
        if (eth != 0) Address.sendValue(payable(msg.sender), eth);
    }

    // ------------------------------------------------------------------
    // Exit Tickets
    // ------------------------------------------------------------------

    /// @notice Buys tickets for `imdAmount` wei of IMD during the auction.
    /// @param maxPremium The most ETH the caller will pay; any excess `msg.value` is refunded.
    /// @param minStrike The lowest strike the caller accepts.
    function buyTickets(uint256 id, uint256 imdAmount, uint256 maxPremium, uint256 minStrike)
        external
        payable
        nonReentrant
        returns (uint256 premium)
    {
        if (paused) revert Paused();
        if (imdAmount == 0) revert ZeroAmount();
        Series storage s = _series(id);
        if (s.strike < minStrike) revert Slippage();
        uint256 collateral = Math.mulDiv(imdAmount, s.strike, 1e18, Math.Rounding.Ceil);
        premium = Math.mulDiv(collateral, premiumRate(id), 1e18, Math.Rounding.Ceil);
        if (premium > maxPremium || premium > msg.value) revert Slippage();
        if (collateral > capacityLeft(id)) revert CapExceeded();
        if (ticketCollateralOf[id][msg.sender] + collateral > maxAccountCollateral) revert CapExceeded();
        if (openTicketCollateral + collateral > maxOpenTicketCollateral) revert CapExceeded();

        uint256 fee = premium * s.protocolFeeBps / 10_000;
        feesAccrued += fee;
        s.premiums += premium - fee;
        s.ticketCollateral += collateral;
        ticketCollateralOf[id][msg.sender] += collateral;
        openTicketCollateral += collateral;
        emit TicketsBought(id, msg.sender, imdAmount, premium);

        _mint(msg.sender, id, imdAmount, "");
        if (msg.value > premium) Address.sendValue(payable(msg.sender), msg.value - premium);
    }

    /// @notice After expiry, delivers IMD (or the sIMD worth it) and receives the strike in ETH.
    /// @param inSimd Deliver `simd.previewWithdraw(imdAmount)` sIMD shares instead of IMD.
    function exercise(uint256 id, uint256 imdAmount, bool inSimd) external nonReentrant returns (uint256 paid) {
        if (imdAmount == 0) revert ZeroAmount();
        Series storage s = _series(id);
        if (block.timestamp < s.expiry || block.timestamp >= s.expiry + EXERCISE_WINDOW) revert NotInWindow();
        _burn(msg.sender, id, imdAmount);
        paid = Math.mulDiv(imdAmount, s.strike, 1e18);
        s.exercisePaid += paid;
        uint256 delivered;
        if (inSimd) {
            delivered = simd.previewWithdraw(imdAmount);
            s.simdDelivered += delivered;
            simd.safeTransferFrom(msg.sender, address(this), delivered);
        } else {
            delivered = imdAmount;
            s.imdDelivered += imdAmount;
            imd.safeTransferFrom(msg.sender, address(this), imdAmount);
        }
        emit Exercised(id, msg.sender, imdAmount, inSimd, delivered, paid);
        Address.sendValue(payable(msg.sender), paid);
    }

    // ------------------------------------------------------------------
    // Floor Loans
    // ------------------------------------------------------------------

    /// @notice Borrows ETH against sIMD during the auction. Principal is the series' loan-to-value of the
    /// sIMD's IMD value at the lower of the strike and the current pessimistic price. The fee, taken
    /// upfront, is the larger of the series' loan fee and the value of the put the loan embeds. There is
    /// no price liquidation: repay before the exercise window closes, or the sIMD goes to the writers.
    /// @param minReceived The least ETH the caller accepts after the fee.
    function borrow(uint256 id, uint256 shares, uint256 minReceived)
        external
        nonReentrant
        returns (uint256 loanId, uint256 principal)
    {
        if (paused) revert Paused();
        if (shares == 0) revert ZeroAmount();
        Series storage s = _series(id);
        _requireAuction(s);

        uint256 rate = Math.min(simd.convertToAssets(1e24), s.simdRate * (10_000 + SIMD_RATE_TOLERANCE_BPS) / 10_000);
        uint256 spot = TickPrice.ethPerImd(recorder.pessimisticTick());
        uint256 loanStrike = Math.min(s.strike, spot) * s.loanLtvBps / 10_000; // ETH lent per IMD
        principal = Math.mulDiv(Math.mulDiv(shares, rate, 1e24), loanStrike, 1e18);
        uint256 feeRate = Math.max(
            uint256(s.loanFeeBps) * 1e14,
            OptionMath.putRate(spot, loanStrike, s.sigma, s.expiry + EXERCISE_WINDOW - block.timestamp)
        );
        uint256 fee = Math.mulDiv(principal, feeRate, 1e18, Math.Rounding.Ceil);
        if (principal == 0 || fee >= principal || principal - fee < minReceived) revert Slippage();
        if (principal > maxLoanPrincipal || principal > capacityLeft(id)) revert CapExceeded();
        if (openLoanPrincipal + principal > maxOpenLoanPrincipal) revert CapExceeded();

        uint256 protocolCut = fee * s.protocolFeeBps / 10_000;
        feesAccrued += protocolCut;
        s.loanFees += fee - protocolCut;
        s.loanPrincipal += principal;
        s.loanCollateral += shares;
        openLoanPrincipal += principal;

        loanId = ++loanCount;
        loans[loanId] = Loan({borrower: msg.sender, seriesId: uint64(id), closed: false, shares: shares, principal: principal});
        emit Borrowed(loanId, id, msg.sender, shares, principal, fee);

        simd.safeTransferFrom(msg.sender, address(this), shares);
        Address.sendValue(payable(msg.sender), principal - fee);
    }

    /// @notice Repays a loan in full and returns its sIMD to the borrower. Anyone may pay.
    function repay(uint256 loanId) external payable nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0) || loan.closed) revert LoanClosed();
        Series storage s = series[loan.seriesId];
        if (block.timestamp >= s.expiry + EXERCISE_WINDOW) revert NotInWindow();
        if (msg.value != loan.principal) revert WrongAmount();
        loan.closed = true;
        s.loanRepaid += loan.principal;
        if (block.timestamp < s.auctionStart + AUCTION) s.loanRepaidInAuction += loan.principal;
        s.loanCollateral -= loan.shares;
        openLoanPrincipal -= loan.principal;
        emit Repaid(loanId, msg.sender);
        simd.safeTransfer(loan.borrower, loan.shares);
    }

    // ------------------------------------------------------------------
    // Owner and guardian
    // ------------------------------------------------------------------

    function setCaps(
        uint256 maxSeriesDeposits_,
        uint256 maxAccountCollateral_,
        uint256 maxOpenTicketCollateral_,
        uint256 maxOpenLoanPrincipal_,
        uint256 maxLoanPrincipal_
    ) external onlyOwner {
        maxSeriesDeposits = maxSeriesDeposits_;
        maxAccountCollateral = maxAccountCollateral_;
        maxOpenTicketCollateral = maxOpenTicketCollateral_;
        maxOpenLoanPrincipal = maxOpenLoanPrincipal_;
        maxLoanPrincipal = maxLoanPrincipal_;
        emit SettingsUpdated();
    }

    /// @notice Pricing for series opened from now on.
    function setPricing(uint256 protocolFeeBps_, uint256 loanFeeBps_, uint256 loanLtvBps_, uint256 sigmaFloor_)
        external
        onlyOwner
    {
        if (protocolFeeBps_ > MAX_PROTOCOL_FEE_BPS || loanFeeBps_ > MAX_LOAN_FEE_BPS) revert InvalidSetting();
        if (loanLtvBps_ > MAX_LOAN_LTV_BPS || sigmaFloor_ < MIN_SIGMA || sigmaFloor_ > MAX_SIGMA) revert InvalidSetting();
        protocolFeeBps = protocolFeeBps_;
        loanFeeBps = loanFeeBps_;
        loanLtvBps = loanLtvBps_;
        sigmaFloor = sigmaFloor_;
        emit SettingsUpdated();
    }

    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit SettingsUpdated();
    }

    /// @notice Stops new series, deposits, ticket sales and loans. The owner or the guardian can pause.
    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardian();
        paused = true;
        emit PausedSet(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit PausedSet(false);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert InvalidSetting();
        feeRecipient = feeRecipient_;
        emit SettingsUpdated();
    }

    /// @notice Sends accrued protocol fees to the fee recipient. Anyone can call it.
    function withdrawFees() external nonReentrant {
        uint256 amount = feesAccrued;
        feesAccrued = 0;
        emit FeesWithdrawn(feeRecipient, amount);
        Address.sendValue(payable(feeRecipient), amount);
    }

    function getSeries(uint256 id) external view returns (Series memory) {
        return series[id];
    }

    function _series(uint256 id) internal view returns (Series storage s) {
        s = series[id];
        if (s.auctionStart == 0) revert UnknownSeries();
    }

    function _requireAuction(Series storage s) internal view {
        if (block.timestamp < s.auctionStart || block.timestamp >= s.auctionStart + AUCTION) revert NotInWindow();
    }
}
