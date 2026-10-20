// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Wallstrike} from "../src/Wallstrike.sol";
import {ImdPriceRecorder} from "../src/ImdPriceRecorder.sol";
import {TickPrice} from "../src/libraries/TickPrice.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract WallstrikeTest is BaseTest {
    function setUp() public override {
        super.setUp();
        seed(336);
    }

    // ------------------------------------------------------------------
    // Opening series
    // ------------------------------------------------------------------

    function test_Line0StrikeIsTheWallWhenTheWallIsLower() public {
        // 80% of the mean is tick 62,232; the wall at 63,840 is cheaper, so it caps the strike.
        uint256 id = ws.openSeries(0, 1);
        Wallstrike.Series memory s = ws.getSeries(id);
        assertEq(s.strike, TickPrice.ethPerImd(WALL_TICK));
        assertEq(s.auctionStart, block.timestamp + 1 days);
        assertEq(s.expiry, block.timestamp + 2 days + 30 days);
        assertGt(s.floorRate, 0.05e18);
        assertLt(s.floorRate, 0.25e18);
    }

    function test_Line1StrikeIsSixtyPercentOfTheMean() public {
        uint256 id = ws.openSeries(1, 0);
        assertEq(ws.getSeries(id).strike, TickPrice.ethPerImd(SPOT_TICK + 5109));
        assertApproxEqRel(ws.getSeries(id).strike, TickPrice.ethPerImd(SPOT_TICK) * 6 / 10, 1e14);
    }

    function test_FloorRateHigherForLongerTenorAndHigherStrike() public {
        uint256 short0 = ws.getSeries(ws.openSeries(0, 0)).floorRate;
        uint256 long0 = ws.getSeries(ws.openSeries(0, 1)).floorRate;
        uint256 long1 = ws.getSeries(ws.openSeries(1, 1)).floorRate;
        assertGt(long0, short0);
        assertGt(long0, long1);
    }

    function test_OneSeriesPerLineAndTenorPerWeek() public {
        ws.openSeries(0, 0);
        vm.expectRevert(Wallstrike.SeriesExists.selector);
        ws.openSeries(0, 0);
        ws.openSeries(0, 1); // other tenor is fine
        seed(336); // a week later
        ws.openSeries(0, 0);
    }

    function test_OpenRevertsWithoutEnoughHistory() public {
        vm.warp(block.timestamp + 1 days); // last 48 slots are empty
        vm.expectRevert();
        ws.openSeries(0, 0);
    }

    function test_OpenRevertsWhenPool4Unhealthy() public {
        hook.setMarketOpen(false);
        vm.expectRevert(Wallstrike.PoolUnhealthy.selector);
        ws.openSeries(0, 0);
        hook.setMarketOpen(true);
        hook.setRebalanceEnabled(false);
        vm.expectRevert(Wallstrike.PoolUnhealthy.selector);
        ws.openSeries(0, 0);
    }

    function test_WallAboveTheMarketIsIgnored() public {
        setMarket(SPOT_TICK, SPOT_TICK, SPOT_TICK - 10); // the wall is being filled
        seed(48);
        uint256 id = ws.openSeries(0, 0);
        assertEq(ws.getSeries(id).strike, TickPrice.ethPerImd(SPOT_TICK + 2232)); // 80% of the mean
    }

    function test_WallFarBelowTheMarketCountsAsFiftyPercentBelow() public {
        setMarket(SPOT_TICK, SPOT_TICK, SPOT_TICK + 20_000); // pushed far down
        seed(48);
        uint256 id = ws.openSeries(0, 0);
        assertEq(ws.getSeries(id).strike, TickPrice.ethPerImd(SPOT_TICK + 6932));
        assertApproxEqRel(ws.getSeries(id).strike, TickPrice.ethPerImd(SPOT_TICK) / 2, 1e14);
    }

    function test_ShortLivedWallMoveDoesNotMoveTheStrike() public {
        // A few hours with the wall pushed 20% lower barely moves the 24h median.
        setMarket(SPOT_TICK, SPOT_TICK, WALL_TICK + 2000);
        seed(6);
        setMarket(SPOT_TICK, SPOT_TICK, WALL_TICK);
        uint256 id = ws.openSeries(0, 0);
        assertEq(ws.getSeries(id).strike, TickPrice.ethPerImd(WALL_TICK));
    }

    // ------------------------------------------------------------------
    // Writers and the auction
    // ------------------------------------------------------------------

    function test_DepositAndWithdrawBeforeAuction() public {
        uint256 id = openAndFund(0, 0, 3 ether, 0);
        vm.prank(alice);
        ws.withdrawDeposit(id, 1 ether);
        assertEq(ws.writerDeposit(id, alice), 2 ether);
        assertEq(ws.getSeries(id).deposits, 2 ether);
        toAuction(id);
        vm.prank(alice);
        vm.expectRevert(Wallstrike.NotInWindow.selector);
        ws.withdrawDeposit(id, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Wallstrike.NotInWindow.selector);
        ws.deposit{value: 1 ether}(id);
    }

    /// @dev Review finding: a squatter could fill the cap at opening and withdraw in the last block before
    /// the auction. Deposits are now pro rata, so nobody is crowded out.
    function test_SquatterCannotCrowdOutWriters() public {
        uint256 id = ws.openSeries(0, 0);
        vm.prank(mallory);
        ws.deposit{value: 10 ether}(id);
        vm.prank(alice);
        ws.deposit{value: 5 ether}(id); // accepted even though the cap is full
        vm.warp(ws.getSeries(id).auctionStart - 12);
        vm.prank(mallory);
        ws.withdrawDeposit(id, 10 ether);
        toAuction(id);
        assertEq(ws.capacityLeft(id), 5 ether);
        vm.prank(carol);
        ws.buyTickets{value: 1 ether}(id, 100e18, 1 ether, 0);
    }

    function test_OversubscribedSeriesPutsWritersAtRiskProRata() public {
        uint256 id = openAndFund(0, 0, 12 ether, 8 ether); // 20 ETH against a 10 ETH cap
        toAuction(id);
        assertEq(ws.capacityLeft(id), 10 ether);
        uint256 strike = ws.getSeries(id).strike;
        uint256 imdAmount = 2 ether * 1e18 / strike;
        vm.prank(carol);
        ws.buyTickets{value: 1 ether}(id, imdAmount, 1 ether, 0);
        vm.warp(ws.getSeries(id).auctionStart + 1 days);
        uint256 used = ws.getSeries(id).ticketCollateral;
        assertEq(ws.releasedEth(id), 20 ether - used);
        uint256 before = alice.balance;
        vm.prank(alice);
        ws.claimRelease(id);
        assertEq(alice.balance - before, (20 ether - used) * 12 / 20);
    }

    function test_PremiumFallsFromTwiceTheFloorToTheFloor() public {
        uint256 id = openAndFund(0, 0, 5 ether, 0);
        uint256 floorRate = ws.getSeries(id).floorRate;
        vm.expectRevert(Wallstrike.NotInWindow.selector);
        ws.premiumRate(id);
        toAuction(id);
        assertEq(ws.premiumRate(id), 2 * floorRate);
        vm.warp(block.timestamp + 12 hours);
        assertEq(ws.premiumRate(id), floorRate + floorRate / 2);
        vm.warp(block.timestamp + 12 hours - 1);
        assertApproxEqRel(ws.premiumRate(id), floorRate, 2e13);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(Wallstrike.NotInWindow.selector);
        ws.premiumRate(id);
    }

    function test_FullTicketLifecycle() public {
        uint256 id = openAndFund(0, 0, 6 ether, 4 ether);
        uint256 strike = ws.getSeries(id).strike;
        uint256 premium = _buyLate(id, 1000e18);

        // After the auction, unused capacity goes back to writers pro rata.
        vm.warp(ws.getSeries(id).auctionStart + 1 days);
        uint256 released = ws.releasedEth(id);
        assertEq(released, 10 ether - ws.getSeries(id).ticketCollateral);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        ws.claimRelease(id);
        assertEq(alice.balance - aliceBefore, released * 6 / 10);
        vm.prank(alice);
        vm.expectRevert(Wallstrike.NothingToClaim.selector);
        ws.claimRelease(id);

        // At expiry Carol delivers 600 IMD and the sIMD worth 400 IMD.
        toExpiry(id);
        (uint256 paid, uint256 sharesDelivered) = _exerciseMixed(id);
        assertEq(paid, 600e18 * strike / 1e18 + 400e18 * strike / 1e18);
        assertEq(ws.balanceOf(carol, id), 0);
        assertGe(simd.convertToAssets(sharesDelivered), 400e18 - 1);

        // Writers split what is left.
        toSettled(id);
        _checkAliceClaim(id, paid, sharesDelivered);
        vm.startPrank(bob);
        ws.claimRelease(id);
        ws.claim(id);
        vm.stopPrank();
        ws.withdrawFees();
        assertEq(feeTo.balance, premium / 10);
        assertLe(address(ws).balance, 5); // rounding dust only
        assertEq(ws.openTicketCollateral(), 0);
    }

    function _buyLate(uint256 id, uint256 imdAmount) internal returns (uint256 premium) {
        toAuction(id);
        vm.warp(block.timestamp + 18 hours);
        uint256 strike = ws.getSeries(id).strike;
        uint256 collateral = imdAmount * strike / 1e18 + 1;
        uint256 rate = ws.premiumRate(id);
        uint256 carolBefore = carol.balance;
        vm.prank(carol);
        premium = ws.buyTickets{value: 1 ether}(id, imdAmount, 1 ether, strike);
        assertEq(carol.balance, carolBefore - premium);
        assertApproxEqAbs(premium, collateral * rate / 1e18, 2);
        assertEq(ws.balanceOf(carol, id), imdAmount);
        assertEq(ws.feesAccrued(), premium / 10);
    }

    function _exerciseMixed(uint256 id) internal returns (uint256 paid, uint256 shares) {
        giveImd(carol, 600e18);
        giveSimd(carol, 500e18);
        shares = simd.previewWithdraw(400e18);
        vm.startPrank(carol);
        imd.approve(address(ws), 600e18);
        simd.approve(address(ws), type(uint256).max);
        paid = ws.exercise(id, 600e18, false);
        paid += ws.exercise(id, 400e18, true);
        vm.stopPrank();
    }

    function _checkAliceClaim(uint256 id, uint256 paid, uint256 sharesDelivered) internal {
        vm.prank(alice);
        (uint256 eth, uint256 imdOut, uint256 simdOut) = ws.claim(id);
        Wallstrike.Series memory s = ws.getSeries(id);
        assertEq(s.finalEth, s.ticketCollateral + s.premiums - paid);
        assertEq(eth, s.finalEth * 6 / 10);
        assertEq(imdOut, 600e18 * 6 / 10);
        assertEq(simdOut, sharesDelivered * 6 / 10);
    }

    function test_UnexercisedTicketsLeaveEverythingToWriters() public {
        uint256 id = openAndFund(1, 0, 2 ether, 0);
        toAuction(id);
        vm.prank(carol);
        uint256 premium = ws.buyTickets{value: 1 ether}(id, 100e18, 1 ether, 0);
        toSettled(id);
        uint256 before = alice.balance;
        vm.startPrank(alice);
        ws.claimRelease(id);
        ws.claim(id);
        vm.stopPrank();
        assertEq(alice.balance - before, 2 ether + premium - premium / 10);
    }

    function test_BuyChecks() public {
        uint256 id = openAndFund(0, 0, 1 ether, 0);
        uint256 strike = ws.getSeries(id).strike;
        vm.prank(carol);
        vm.expectRevert(Wallstrike.NotInWindow.selector);
        ws.buyTickets{value: 1 ether}(id, 1e18, 1 ether, 0);
        toAuction(id);
        vm.prank(carol);
        vm.expectRevert(Wallstrike.Slippage.selector); // strike below the caller's minimum
        ws.buyTickets{value: 1 ether}(id, 1e18, 1 ether, strike + 1);
        vm.prank(carol);
        vm.expectRevert(Wallstrike.Slippage.selector); // premium above the caller's maximum
        ws.buyTickets{value: 1 ether}(id, 100e18, 1, 0);
        uint256 tooMuch = (1 ether * 1e18 / strike) + 1e18;
        vm.prank(carol);
        vm.expectRevert(Wallstrike.CapExceeded.selector); // more than the pool backs
        ws.buyTickets{value: 1 ether}(id, tooMuch, 1 ether, 0);
    }

    function test_AccountAndGlobalCaps() public {
        vm.prank(owner);
        ws.setCaps(10 ether, 0.5 ether, 0.8 ether, 10 ether, 1 ether);
        uint256 id = openAndFund(0, 0, 5 ether, 0);
        uint256 strike = ws.getSeries(id).strike;
        toAuction(id);
        uint256 halfEthOfImd = 0.5 ether * 1e18 / strike;
        vm.prank(carol);
        ws.buyTickets{value: 1 ether}(id, halfEthOfImd, 1 ether, 0);
        vm.prank(carol);
        vm.expectRevert(Wallstrike.CapExceeded.selector);
        ws.buyTickets{value: 1 ether}(id, 1e18, 1 ether, 0);
        vm.prank(dave);
        vm.expectRevert(Wallstrike.CapExceeded.selector); // global cap of 0.8 ETH
        ws.buyTickets{value: 1 ether}(id, halfEthOfImd, 1 ether, 0);
    }

    function test_ExerciseWindow() public {
        uint256 id = openAndFund(0, 0, 1 ether, 0);
        toAuction(id);
        vm.prank(carol);
        ws.buyTickets{value: 1 ether}(id, 10e18, 1 ether, 0);
        giveImd(carol, 10e18);
        vm.prank(carol);
        imd.approve(address(ws), 10e18);
        vm.warp(ws.getSeries(id).expiry - 1);
        vm.prank(carol);
        vm.expectRevert(Wallstrike.NotInWindow.selector);
        ws.exercise(id, 10e18, false);
        toSettled(id);
        vm.prank(carol);
        vm.expectRevert(Wallstrike.NotInWindow.selector);
        ws.exercise(id, 10e18, false);
    }

    function test_CannotExerciseMoreThanHeld() public {
        uint256 id = openAndFund(0, 0, 1 ether, 0);
        toAuction(id);
        vm.prank(carol);
        ws.buyTickets{value: 1 ether}(id, 10e18, 1 ether, 0);
        toExpiry(id);
        giveImd(mallory, 20e18);
        vm.startPrank(mallory);
        imd.approve(address(ws), 20e18);
        vm.expectRevert();
        ws.exercise(id, 10e18, false);
        vm.stopPrank();
    }

    function test_TicketsAreTransferable() public {
        uint256 id = openAndFund(0, 0, 1 ether, 0);
        toAuction(id);
        vm.prank(carol);
        ws.buyTickets{value: 1 ether}(id, 10e18, 1 ether, 0);
        vm.prank(carol);
        ws.safeTransferFrom(carol, dave, id, 10e18, "");
        toExpiry(id);
        giveImd(dave, 10e18);
        vm.startPrank(dave);
        imd.approve(address(ws), 10e18);
        uint256 paid = ws.exercise(id, 10e18, false);
        vm.stopPrank();
        assertEq(paid, 10e18 * ws.getSeries(id).strike / 1e18);
    }

    // ------------------------------------------------------------------
    // sIMD one-block hold
    // ------------------------------------------------------------------

    /// @dev A third party can stamp any address for 1 wei. Wallstrike never redeems, so nothing breaks.
    function _stamp(address target) internal {
        giveImd(mallory, 1);
        vm.startPrank(mallory);
        imd.approve(address(simd), 1);
        simd.deposit(1, target);
        vm.stopPrank();
        assertEq(simd.lastDepositBlock(target), block.number);
    }

    function test_HoldCannotBlockExerciseInSimd() public {
        uint256 id = openAndFund(0, 0, 1 ether, 0);
        toAuction(id);
        vm.prank(carol);
        ws.buyTickets{value: 1 ether}(id, 10e18, 1 ether, 0);
        toExpiry(id);
        giveSimd(carol, 20e18);
        _stamp(carol);
        _stamp(address(ws));
        vm.startPrank(carol);
        simd.approve(address(ws), type(uint256).max);
        ws.exercise(id, 10e18, true);
        vm.stopPrank();
    }

    function test_HoldCannotBlockBorrowRepayOrClaim() public {
        uint256 id = openAndFund(0, 0, 5 ether, 0);
        toAuction(id);
        uint256 shares = giveSimd(dave, 1000e18);
        _stamp(dave);
        _stamp(address(ws));
        vm.startPrank(dave);
        simd.approve(address(ws), shares);
        (uint256 loanId, uint256 principal) = ws.borrow(id, shares, 0);
        _stamp(address(ws));
        ws.repay{value: principal}(loanId);
        vm.stopPrank();
        toSettled(id);
        _stamp(alice);
        _stamp(address(ws));
        vm.prank(alice);
        ws.claim(id);
    }

    // ------------------------------------------------------------------
    // Floor Loans
    // ------------------------------------------------------------------

    function test_BorrowAndRepay() public {
        uint256 id = openAndFund(0, 0, 5 ether, 0);
        uint256 strike = ws.getSeries(id).strike;
        toAuction(id);
        uint256 shares = giveSimd(dave, 1000e18);
        uint256 imdValue = simd.convertToAssets(shares);
        uint256 before = dave.balance;
        vm.startPrank(dave);
        simd.approve(address(ws), shares);
        (uint256 loanId, uint256 principal) = ws.borrow(id, shares, 0);
        vm.stopPrank();
        assertApproxEqRel(principal, imdValue * strike / 1e18 * 3500 / 10_000, 1e12);
        uint256 fee = (principal * 300 + 9999) / 10_000; // rounded up
        assertEq(dave.balance - before, principal - fee);
        assertEq(simd.balanceOf(dave), 0);
        assertEq(ws.feesAccrued(), fee / 10);

        toExpiry(id);
        vm.prank(dave);
        vm.expectRevert(Wallstrike.WrongAmount.selector);
        ws.repay{value: principal - 1}(loanId);
        vm.prank(dave);
        ws.repay{value: principal}(loanId);
        assertEq(simd.balanceOf(dave), shares);
        vm.prank(dave);
        vm.expectRevert(Wallstrike.LoanClosed.selector);
        ws.repay{value: principal}(loanId);

        toSettled(id);
        uint256 aliceBefore = alice.balance;
        vm.startPrank(alice);
        ws.claimRelease(id);
        ws.claim(id);
        vm.stopPrank();
        assertEq(alice.balance - aliceBefore, 5 ether + fee - fee / 10);
        assertEq(ws.openLoanPrincipal(), 0);
    }

    function test_UnpaidLoanSimdGoesToWriters() public {
        uint256 id = openAndFund(0, 0, 3 ether, 1 ether);
        toAuction(id);
        uint256 shares = giveSimd(dave, 1000e18);
        vm.startPrank(dave);
        simd.approve(address(ws), shares);
        (uint256 loanId, uint256 principal) = ws.borrow(id, shares, 0);
        vm.stopPrank();
        toSettled(id);
        vm.prank(dave);
        vm.expectRevert(Wallstrike.NotInWindow.selector);
        ws.repay{value: principal}(loanId);
        vm.prank(alice);
        (,, uint256 simdOut) = ws.claim(id);
        assertEq(simdOut, shares * 3 / 4);
        assertEq(ws.openLoanPrincipal(), 0);
    }

    function test_LoanValuesSimdAtNoMoreThanTheRecordedRate() public {
        uint256 id = openAndFund(0, 0, 5 ether, 0);
        toAuction(id);
        uint256 shares = giveSimd(dave, 1000e18);
        uint256 recorded = ws.getSeries(id).simdRate;
        // A large donation inflates sIMD's live rate inside the borrow transaction.
        imd.mint(address(simd), 1_000_000e18);
        assertGt(simd.convertToAssets(1e24), recorded * 2);
        vm.startPrank(dave);
        simd.approve(address(ws), shares);
        (, uint256 principal) = ws.borrow(id, shares, 0);
        vm.stopPrank();
        uint256 cappedValue = shares * (recorded * 10_100 / 10_000) / 1e24;
        assertApproxEqRel(principal, cappedValue * ws.getSeries(id).strike / 1e18 * 3500 / 10_000, 1e12);
    }

    function test_LoanCaps() public {
        uint256 id = openAndFund(0, 0, 10 ether, 0);
        toAuction(id);
        uint256 shares = giveSimd(dave, 1_000_000e18); // worth far more than the 1 ETH loan cap
        vm.startPrank(dave);
        simd.approve(address(ws), shares);
        vm.expectRevert(Wallstrike.CapExceeded.selector);
        ws.borrow(id, shares, 0);
        vm.expectRevert(Wallstrike.Slippage.selector);
        ws.borrow(id, shares / 1000, type(uint256).max);
        vm.stopPrank();
    }

    function test_TicketsAndLoansShareCapacity() public {
        uint256 id = openAndFund(0, 0, 1 ether, 0);
        uint256 strike = ws.getSeries(id).strike;
        toAuction(id);
        uint256 shares = giveSimd(dave, 1000e18);
        vm.startPrank(dave);
        simd.approve(address(ws), shares);
        (, uint256 principal) = ws.borrow(id, shares, 0);
        vm.stopPrank();
        uint256 room = 1 ether - principal;
        uint256 fits = room * 1e18 / strike - 1e15;
        vm.prank(carol);
        ws.buyTickets{value: 1 ether}(id, fits, 1 ether, 0);
        vm.prank(carol);
        vm.expectRevert(Wallstrike.CapExceeded.selector);
        ws.buyTickets{value: 1 ether}(id, 1e18, 1 ether, 0);
        assertLe(ws.getSeries(id).ticketCollateral + ws.getSeries(id).loanPrincipal, 1 ether);
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

    function test_PauseStopsNewActivityOnly() public {
        uint256 id = openAndFund(0, 0, 2 ether, 0);
        toAuction(id);
        vm.prank(carol);
        ws.buyTickets{value: 1 ether}(id, 10e18, 1 ether, 0);
        uint256 shares = giveSimd(dave, 100e18);
        vm.startPrank(dave);
        simd.approve(address(ws), shares);
        (uint256 loanId, uint256 principal) = ws.borrow(id, shares, 0);
        vm.stopPrank();

        vm.prank(owner);
        ws.pause();
        vm.expectRevert(Wallstrike.Paused.selector);
        ws.openSeries(1, 1);
        vm.prank(carol);
        vm.expectRevert(Wallstrike.Paused.selector);
        ws.buyTickets{value: 1 ether}(id, 10e18, 1 ether, 0);

        vm.prank(dave);
        ws.repay{value: principal}(loanId);
        toExpiry(id);
        giveImd(carol, 10e18);
        vm.startPrank(carol);
        imd.approve(address(ws), 10e18);
        ws.exercise(id, 10e18, false);
        vm.stopPrank();
        toSettled(id);
        vm.startPrank(alice);
        ws.claimRelease(id);
        ws.claim(id);
        vm.stopPrank();
    }

    function test_OwnerSettingsAreBounded() public {
        vm.startPrank(owner);
        vm.expectRevert(Wallstrike.InvalidSetting.selector);
        ws.setPricing(2001, 300, 3500, 2e18);
        vm.expectRevert(Wallstrike.InvalidSetting.selector);
        ws.setPricing(1000, 1001, 3500, 2e18);
        vm.expectRevert(Wallstrike.InvalidSetting.selector);
        ws.setPricing(1000, 300, 5001, 2e18);
        vm.expectRevert(Wallstrike.InvalidSetting.selector);
        ws.setPricing(1000, 300, 3500, 5e18 + 1);
        vm.expectRevert(Wallstrike.InvalidSetting.selector);
        ws.setFeeRecipient(address(0));
        ws.setPricing(500, 200, 3000, 2.5e18);
        vm.stopPrank();
        vm.prank(mallory);
        vm.expectRevert(Wallstrike.NotGuardian.selector);
        ws.pause();
    }

    function test_GuardianCanPauseButNotUnpause() public {
        address guardian = makeAddr("guardian");
        vm.prank(owner);
        ws.setGuardian(guardian);
        vm.prank(guardian);
        ws.pause();
        assertTrue(ws.paused());
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        ws.unpause();
        vm.prank(owner);
        ws.unpause();
        assertFalse(ws.paused());
    }

    function test_SettingsChangeDoesNotTouchOpenSeries() public {
        uint256 id = openAndFund(0, 0, 2 ether, 0);
        Wallstrike.Series memory before = ws.getSeries(id);
        vm.prank(owner);
        ws.setPricing(1000, 300, 3500, 4e18);
        vm.prank(owner);
        ws.setCaps(1 ether, 2.5 ether, 25 ether, 10 ether, 1 ether);
        vm.prank(owner);
        ws.setPricing(2000, 1000, 5000, 4e18);
        Wallstrike.Series memory afterChange = ws.getSeries(id);
        assertEq(afterChange.strike, before.strike);
        assertEq(afterChange.floorRate, before.floorRate);
        assertEq(afterChange.sigma, before.sigma);
        assertEq(afterChange.depositCap, 10 ether);
        assertEq(afterChange.protocolFeeBps, 1000);
        assertEq(afterChange.loanFeeBps, 300);
        assertEq(afterChange.loanLtvBps, 3500);
    }

    // ------------------------------------------------------------------
    // Live pricing
    // ------------------------------------------------------------------

    /// @dev Review finding: the premium was fixed at opening, so a fall during the deposit window or the
    /// auction let buyers take in-the-money puts at out-of-the-money prices.
    function test_PremiumRisesWhenThePriceFallsDuringTheAuction() public {
        uint256 id = openAndFund(0, 0, 5 ether, 0);
        toAuction(id);
        uint256 calm = ws.premiumRate(id);
        // The main pool falls 30% (about 3,567 ticks); refTick has not caught up yet.
        manager.setPool(MAIN_POOL, TickMath.getSqrtPriceAtTick(SPOT_TICK + 3567), SPOT_TICK + 3567, 1e21);
        uint256 stressed = ws.premiumRate(id);
        assertGt(stressed, calm * 2);
        uint256 spot = TickPrice.ethPerImd(SPOT_TICK + 3567);
        uint256 strike = ws.getSeries(id).strike;
        uint256 intrinsic = strike > spot ? (strike - spot) * 1e18 / strike : 0;
        assertGe(stressed, intrinsic);
    }

    function test_PremiumIgnoresAMainPoolPushUpward() public {
        uint256 id = openAndFund(0, 0, 5 ether, 0);
        toAuction(id);
        uint256 calm = ws.premiumRate(id);
        manager.setPool(MAIN_POOL, TickMath.getSqrtPriceAtTick(SPOT_TICK - 3000), SPOT_TICK - 3000, 1e21);
        assertEq(ws.premiumRate(id), calm); // refTick still holds the lower price
    }

    function test_LoanPrincipalUsesTheLivePriceWhenBelowTheStrike() public {
        uint256 id = openAndFund(0, 0, 5 ether, 0);
        toAuction(id);
        int24 crashed = WALL_TICK + 4000;
        manager.setPool(MAIN_POOL, TickMath.getSqrtPriceAtTick(crashed), crashed, 1e21);
        uint256 shares = giveSimd(dave, 100e18);
        uint256 imdValue = simd.convertToAssets(shares);
        vm.startPrank(dave);
        simd.approve(address(ws), shares);
        (, uint256 principal) = ws.borrow(id, shares, 0);
        vm.stopPrank();
        assertApproxEqRel(principal, imdValue * TickPrice.ethPerImd(crashed) / 1e18 * 3500 / 10_000, 1e12);
    }

    function test_SigmaFollowsRealizedVolatility() public {
        // Alternate refTick by 300 ticks every slot: far above the 200% floor once annualized.
        for (uint256 i; i < 336; ++i) {
            int24 t = i % 2 == 0 ? SPOT_TICK : SPOT_TICK + 300;
            setMarket(t, t, WALL_TICK + 300);
            seed(1);
        }
        uint256 vol = recorder.realizedVol(336, 280);
        assertApproxEqRel(vol, 300 * uint256(99995000333308) * 13236 / 100, 1e15); // 300 ticks x sqrt(17520)
        uint256 id = ws.openSeries(0, 0);
        assertApproxEqRel(ws.getSeries(id).sigma, vol * 12_500 / 10_000, 1e12);
    }

    // ------------------------------------------------------------------
    // Loans repaid during the auction
    // ------------------------------------------------------------------

    /// @dev Review finding: repaid loans kept consuming capacity, so a borrow/repay loop could block every
    /// ticket sale and lock writers' ETH until finalize.
    function test_RepaidLoanFreesCapacityAndIsReleased() public {
        uint256 id = openAndFund(0, 0, 2 ether, 0);
        toAuction(id);
        uint256 shares = giveSimd(dave, 1000e18);
        vm.startPrank(dave);
        simd.approve(address(ws), type(uint256).max);
        for (uint256 i; i < 10; ++i) {
            (uint256 loanId, uint256 principal) = ws.borrow(id, shares, 0);
            ws.repay{value: principal}(loanId);
        }
        vm.stopPrank();
        assertEq(ws.capacityLeft(id), 2 ether);
        vm.prank(carol);
        ws.buyTickets{value: 1 ether}(id, 100e18, 1 ether, 0);
        vm.warp(ws.getSeries(id).auctionStart + 1 days);
        assertEq(ws.releasedEth(id), 2 ether - ws.getSeries(id).ticketCollateral);
        toSettled(id);
        vm.startPrank(alice);
        ws.claimRelease(id);
        ws.claim(id);
        vm.stopPrank();
        ws.withdrawFees();
        assertLe(address(ws).balance, 5);
    }

    // ------------------------------------------------------------------
    // Solvency
    // ------------------------------------------------------------------

    function testFuzz_SeriesAlwaysPaysOut(
        uint96 aliceEth,
        uint96 bobEth,
        uint96 buyImd,
        uint96 exerciseImd,
        uint32 buyDelay,
        bool inSimd,
        bool withLoan
    ) public {
        aliceEth = uint96(bound(aliceEth, 0.05 ether, 6 ether));
        bobEth = uint96(bound(bobEth, 0, 4 ether));
        uint256 id = openAndFund(0, 0, aliceEth, bobEth);
        uint256 strike = ws.getSeries(id).strike;
        toAuction(id);
        vm.warp(block.timestamp + bound(buyDelay, 0, 1 days - 1));
        freshen();

        uint256 principal;
        uint256 loanId;
        if (withLoan) {
            uint256 shares = giveSimd(dave, 10e18); // about 0.006 ETH of principal
            vm.startPrank(dave);
            simd.approve(address(ws), shares);
            (loanId, principal) = ws.borrow(id, shares, 0);
            vm.stopPrank();
        }
        uint256 room = uint256(aliceEth) + bobEth - principal;
        uint256 maxImd = (room < 2.5 ether ? room : 2.5 ether) * 1e18 / strike;
        buyImd = uint96(bound(buyImd, 1, maxImd > 1 ? maxImd - 1 : 1));
        vm.prank(carol);
        ws.buyTickets{value: 10 ether}(id, buyImd, 10 ether, 0);

        toExpiry(id);
        exerciseImd = uint96(bound(exerciseImd, 0, buyImd));
        if (exerciseImd != 0) {
            giveImd(carol, exerciseImd);
            giveSimd(carol, uint256(exerciseImd) * 2);
            vm.startPrank(carol);
            imd.approve(address(ws), exerciseImd);
            simd.approve(address(ws), type(uint256).max);
            ws.exercise(id, exerciseImd, inSimd);
            vm.stopPrank();
        }
        if (withLoan && buyDelay % 2 == 0) {
            vm.prank(dave);
            ws.repay{value: principal}(loanId);
        }
        toSettled(id);
        vm.startPrank(alice);
        ws.claimRelease(id);
        ws.claim(id);
        vm.stopPrank();
        if (bobEth != 0) {
            vm.startPrank(bob);
            ws.claimRelease(id);
            ws.claim(id);
            vm.stopPrank();
        }
        ws.withdrawFees();
        assertLe(address(ws).balance, 5);
        assertLe(simd.balanceOf(address(ws)), 5);
        assertLe(imd.balanceOf(address(ws)), 5);
    }
}
