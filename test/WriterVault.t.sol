// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Wallstrike} from "../src/Wallstrike.sol";
import {WriterVault} from "../src/WriterVault.sol";

contract WriterVaultTest is BaseTest {
    WriterVault internal vault;
    address internal erin = makeAddr("erin"); // a later depositor

    function setUp() public override {
        super.setUp();
        seed(336);
        vault = new WriterVault(ws, 0, 0); // line 0, 7-day series
        vm.deal(erin, 100 ether);
    }

    function _deposit(address user, uint256 eth) internal {
        vm.prank(user);
        vault.deposit{value: eth}();
    }

    /// @dev Sells tickets for `imdAmount` in the vault's current series and returns the series id.
    function _sellTickets(uint256 imdAmount) internal returns (uint256 id) {
        id = vault.activeSeries();
        toAuction(id);
        vm.prank(carol);
        ws.buyTickets{value: 10 ether}(id, imdAmount, 10 ether, 0);
    }

    function _exercise(uint256 id, uint256 imdAmount) internal {
        toExpiry(id);
        giveImd(carol, imdAmount);
        vm.startPrank(carol);
        imd.approve(address(ws), imdAmount);
        ws.exercise(id, imdAmount, false);
        vm.stopPrank();
    }

    /// @dev Advances a week with the keeper recording every slot, so the next series can open.
    function _nextWeek() internal {
        seed(336);
    }

    function test_DepositsWaitForTheRoundAndBecomeShares() public {
        _deposit(alice, 3 ether);
        _deposit(bob, 1 ether);
        assertEq(vault.accountOf(alice).shares, 0);
        assertEq(vault.pendingDepositEth(), 4 ether);

        uint256 id = vault.startRound();
        assertEq(vault.activeSeries(), id);
        assertEq(ws.writerDeposit(id, address(vault)), 4 ether);
        assertEq(address(vault).balance, 0);
        assertApproxEqRel(vault.accountOf(alice).shares, 3 * vault.accountOf(bob).shares, 1e12);
        assertEq(vault.totalShares(), vault.accountOf(alice).shares + vault.accountOf(bob).shares);
    }

    function test_StartRoundOpensTheSeriesIfNeeded() public {
        _deposit(alice, 1 ether);
        assertEq(ws.seriesCount(), 0);
        uint256 id = vault.startRound();
        assertEq(id, 1);
        Wallstrike.Series memory s = ws.getSeries(id);
        assertEq(s.line, 0);
        assertEq(s.tenorId, 0);
    }

    function test_JoinsAnAlreadyOpenSeries() public {
        uint256 id = ws.openSeries(0, 0);
        _deposit(alice, 1 ether);
        assertEq(vault.startRound(), id);
    }

    function test_CannotJoinAfterTheDepositWindow() public {
        uint256 id = ws.openSeries(0, 0);
        toAuction(id);
        _deposit(alice, 1 ether);
        vm.expectRevert(WriterVault.DepositWindowClosed.selector);
        vault.startRound();
    }

    function test_OneRoundAtATime() public {
        _deposit(alice, 1 ether);
        vault.startRound();
        vm.expectRevert(WriterVault.RoundActive.selector);
        vault.startRound();
        vm.expectRevert(); // the series has not settled yet
        vault.endRound();
    }

    function test_RoundWithoutExerciseRollsPremiumsIntoShares() public {
        _deposit(alice, 4 ether);
        vault.startRound();
        uint256 id = _sellTickets(500e18);
        toSettled(id);
        vault.endRound();
        uint256 value = vault.previewWithdraw(vault.accountOf(alice).shares);
        assertGt(value, 4 ether); // premiums earned
        assertApproxEqAbs(value, 4 ether + ws.getSeries(id).premiums, 1e6);

        // Round 2 starts with nobody doing anything: the shares roll over.
        _nextWeek();
        uint256 id2 = vault.startRound();
        assertEq(ws.writerDeposit(id2, address(vault)), 4 ether + ws.getSeries(id).premiums);
    }

    function test_DeliveredImdIsSharedProRata() public {
        _deposit(alice, 3 ether);
        _deposit(bob, 1 ether);
        vault.startRound();
        uint256 id = _sellTickets(1000e18);
        _exercise(id, 1000e18);
        toSettled(id);
        vault.endRound();

        vm.prank(alice);
        (, uint256 aliceImd,) = vault.claim();
        vm.prank(bob);
        (, uint256 bobImd,) = vault.claim();
        assertApproxEqAbs(aliceImd, 750e18, 1e10);
        assertApproxEqAbs(bobImd, 250e18, 1e10);
        assertEq(imd.balanceOf(alice), aliceImd);
        assertLe(imd.balanceOf(address(vault)), 1e10);
    }

    function test_LaterDepositorGetsNoEarlierImd() public {
        _deposit(alice, 2 ether);
        vault.startRound();
        uint256 id = _sellTickets(500e18);
        _deposit(erin, 2 ether); // queued for round 2
        _exercise(id, 500e18);
        toSettled(id);
        vault.endRound();
        _nextWeek();
        vault.startRound();

        vm.prank(erin);
        (, uint256 erinImd,) = vault.claim();
        assertEq(erinImd, 0);
        vm.prank(alice);
        (, uint256 aliceImd,) = vault.claim();
        assertApproxEqAbs(aliceImd, 500e18, 1e10);
        assertGt(vault.accountOf(erin).shares, 0);
    }

    function test_QueuedWithdrawalIsPaidAtTheEndWithItsShareOfImd() public {
        _deposit(alice, 2 ether);
        _deposit(bob, 2 ether);
        vault.startRound();
        uint256 id = _sellTickets(1000e18);
        uint256 aliceShares = vault.accountOf(alice).shares;
        vm.prank(alice);
        vault.requestWithdraw(aliceShares); // queued: the ETH is at risk until the round ends
        assertEq(vault.pendingWithdrawShares(), aliceShares);
        _exercise(id, 1000e18);
        toSettled(id);
        vault.endRound();

        WriterVault.Account memory a = vault.accountOf(alice);
        assertEq(a.shares, 0);
        assertApproxEqAbs(a.imdOwed, 500e18, 1e10);
        uint256 finalEth = ws.getSeries(id).finalEth + ws.releasedEth(id);
        assertApproxEqAbs(a.ethOwed, finalEth / 2, 1e6);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.claim();
        assertApproxEqAbs(alice.balance - before, finalEth / 2, 1e6);

        // Bob stays in; round 2 deploys only his half.
        _nextWeek();
        uint256 id2 = vault.startRound();
        assertApproxEqAbs(ws.writerDeposit(id2, address(vault)), finalEth / 2, 1e6);
    }

    function test_WithdrawBetweenRoundsIsInstant() public {
        _deposit(alice, 2 ether);
        vault.startRound();
        uint256 id = _sellTickets(100e18);
        toSettled(id);
        vault.endRound();
        uint256 shares = vault.accountOf(alice).shares;
        uint256 expected = vault.previewWithdraw(shares);
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.withdraw(shares);
        assertEq(alice.balance - before, expected);
        assertGt(expected, 2 ether);
        assertEq(vault.totalShares(), 0);
    }

    function test_CancelDepositBeforeTheRound() public {
        _deposit(alice, 1 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.cancelDeposit();
        assertEq(alice.balance - before, 1 ether);
        assertEq(vault.pendingDepositEth(), 0);
        vm.prank(alice);
        vm.expectRevert(WriterVault.NothingPending.selector);
        vault.cancelDeposit();
    }

    function test_CannotCancelAfterTheRoundStarts() public {
        _deposit(alice, 1 ether);
        vault.startRound();
        vm.prank(alice);
        vm.expectRevert(WriterVault.NothingPending.selector);
        vault.cancelDeposit();
    }

    function test_OnlyWallstrikeCanSendEth() public {
        vm.prank(mallory);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_CannotWithdrawMoreThanOwned() public {
        _deposit(alice, 1 ether);
        vault.startRound();
        uint256 shares = vault.accountOf(alice).shares;
        vm.prank(alice);
        vm.expectRevert(WriterVault.InsufficientShares.selector);
        vault.requestWithdraw(shares + 1);
    }

    // ------------------------------------------------------------------
    // Review fixes
    // ------------------------------------------------------------------

    function test_InstantWithdrawRevertsDuringARound() public {
        _deposit(alice, 1 ether);
        vault.startRound();
        uint256 shares = vault.accountOf(alice).shares;
        vm.prank(alice);
        vm.expectRevert(WriterVault.RoundActive.selector);
        vault.withdraw(shares);
    }

    function test_RequestWithdrawOnlyDuringARound() public {
        _deposit(alice, 1 ether);
        uint256 id = vault.startRound();
        toSettled(id);
        vault.endRound();
        uint256 shares = vault.accountOf(alice).shares;
        vm.prank(alice);
        vm.expectRevert(WriterVault.NoActiveRound.selector);
        vault.requestWithdraw(shares);
    }

    function test_CancelWithdrawUntilTheAuction() public {
        _deposit(alice, 1 ether);
        uint256 id = vault.startRound();
        uint256 shares = vault.accountOf(alice).shares;
        vm.prank(alice);
        vault.requestWithdraw(shares);
        vm.prank(alice);
        vault.cancelWithdraw();
        assertEq(vault.accountOf(alice).shares, shares);
        assertEq(vault.pendingWithdrawShares(), 0);

        vm.prank(alice);
        vault.requestWithdraw(shares);
        toAuction(id);
        vm.prank(alice);
        vm.expectRevert(WriterVault.AuctionStarted.selector);
        vault.cancelWithdraw();
    }

    /// @dev Review finding: endRound and startRound could be bundled so holders never had an idle window.
    function test_TwelveHoursBetweenRounds() public {
        _deposit(alice, 1 ether);
        uint256 id = vault.startRound();
        toSettled(id);
        seed(336); // the keeper keeps recording, so a series could open
        vault.endRound();
        seed(23); // 11.5 hours later
        vm.expectRevert(WriterVault.TooSoon.selector);
        vault.startRound();
        uint256 shares = vault.accountOf(alice).shares;
        vm.prank(alice);
        vault.withdraw(shares / 2); // the window to leave exists
        seed(1);
        vault.startRound();
    }

    /// @dev Review finding: dust or forced ETH could start a round with no shares at risk.
    function test_NoRoundWithoutSharesOrBelowTheMinimum() public {
        vm.deal(address(vault), 1 ether); // forced ETH, as through selfdestruct
        vm.expectRevert(WriterVault.NothingToDeploy.selector);
        vault.startRound();
        vm.deal(address(vault), 0);
        _deposit(mallory, 0.05 ether);
        vm.expectRevert(WriterVault.NothingToDeploy.selector);
        vault.startRound();
        _deposit(alice, 0.05 ether);
        vault.startRound(); // 0.1 ETH: enough
    }

    function test_RoundWithUnpaidLoanSharesTheSimd() public {
        _deposit(alice, 2 ether);
        vault.startRound();
        uint256 id = vault.activeSeries();
        toAuction(id);
        uint256 shares = giveSimd(dave, 1000e18);
        vm.startPrank(dave);
        simd.approve(address(ws), shares);
        ws.borrow(id, shares, 0);
        vm.stopPrank();
        toSettled(id);
        vault.endRound();
        vm.prank(alice);
        (,, uint256 simdOut) = vault.claim();
        assertApproxEqAbs(simdOut, shares, 1e12);
        assertEq(simd.balanceOf(alice), simdOut);
    }

    /// @dev Several users, two rounds, random amounts: everything paid out equals everything that came in.
    function testFuzz_VaultConservesValue(uint96 aEth, uint96 bEth, uint96 eEth, uint96 sold, uint96 exercised, bool aliceLeaves)
        public
    {
        aEth = uint96(bound(aEth, 0.1 ether, 5 ether));
        bEth = uint96(bound(bEth, 0.1 ether, 5 ether));
        eEth = uint96(bound(eEth, 0.1 ether, 5 ether));
        _deposit(alice, aEth);
        _deposit(bob, bEth);
        uint256 id = vault.startRound();
        uint256 strike = ws.getSeries(id).strike;
        uint256 maxImd = (uint256(aEth) + bEth < 2.5 ether ? uint256(aEth) + bEth : 2.5 ether) * 1e18 / strike;
        sold = uint96(bound(sold, 1e18, maxImd - 1e18));
        _sellTickets(sold);
        _deposit(erin, eEth);
        if (aliceLeaves) {
            uint256 aliceShares = vault.accountOf(alice).shares;
            vm.prank(alice);
            vault.requestWithdraw(aliceShares);
        }
        exercised = uint96(bound(exercised, 0, sold));
        if (exercised != 0) _exercise(id, exercised);
        toSettled(id);
        vault.endRound();
        _nextWeek();
        uint256 id2 = vault.startRound();
        toSettled(id2);
        vault.endRound();

        address[3] memory users = [alice, bob, erin];
        uint256 imdPaid;
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(users[i]);
            (, uint256 imdOut,) = vault.claim();
            uint256 shares = vault.accountOf(users[i]).shares;
            if (shares != 0) vault.withdraw(shares);
            vm.stopPrank();
            imdPaid += imdOut;
        }
        assertApproxEqAbs(imdPaid, exercised, 1e10);
        assertLe(address(vault).balance, 1e9); // rounding dust only
        assertEq(vault.totalShares(), 0);
        assertLe(vault.reservedEth(), 1e9); // rounding dust only
    }
}
