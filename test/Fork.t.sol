// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ImdPriceRecorder} from "../src/ImdPriceRecorder.sol";
import {Wallstrike} from "../src/Wallstrike.sol";
import {WriterVault} from "../src/WriterVault.sol";
import {ICappedBurnHook} from "../src/interfaces/ICappedBurnHook.sol";
import {IStakedIMD} from "../src/interfaces/IStakedIMD.sol";
import {TickPrice} from "../src/libraries/TickPrice.sol";

/// @notice Runs Wallstrike against the real mainnet contracts. Set MAINNET_RPC_URL to run it.
contract ForkTest is Test {
    IERC20 internal constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    IStakedIMD internal constant SIMD = IStakedIMD(0x9Efa934D9fAd4AE28c998a40195646b965a97247);
    ICappedBurnHook internal constant HOOK = ICappedBurnHook(0xc6C965Bd164c483e87d0B550671798e9A3602840);
    IPoolManager internal constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    PoolId internal constant MAIN_POOL = PoolId.wrap(0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3);
    PoolId internal constant POOL4 = PoolId.wrap(0x415829f72e9f54531c26eae76f107618540e898a45d6ae35959e143f5faca704);

    ImdPriceRecorder internal recorder;
    Wallstrike internal ws;
    address internal writer = makeAddr("writer");
    address internal buyer = makeAddr("buyer");
    address internal borrower = makeAddr("borrower");
    bool internal live;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        live = true;
        recorder = new ImdPriceRecorder(HOOK, MANAGER, SIMD, MAIN_POOL);
        ws = new Wallstrike(IMD, SIMD, HOOK, recorder, address(this), address(this), address(0));
        vm.deal(writer, 20 ether);
        vm.deal(buyer, 20 ether);
        vm.deal(borrower, 1 ether);
    }

    function test_Fork_RealPool4Wiring() public {
        if (!live) return;
        assertEq(PoolId.unwrap(HOOK.poolId()), PoolId.unwrap(POOL4));
        assertEq(SIMD.asset(), address(IMD));
        bool valid = recorder.poke();
        ImdPriceRecorder.Sample memory s = recorder.sample(block.timestamp / 30 minutes);
        console2.log("block", block.number);
        console2.log("refTick", s.refTick);
        console2.log("wallTick", s.wallTick);
        console2.log("sIMD rate (IMD per 1e24 shares)", recorder.recentSimdRate());
        console2.log("healthy", recorder.healthy());
        assertTrue(valid, "the live market should produce a valid sample");
        assertGt(s.wallTick, s.refTick, "the wall sits below the market");
    }

    function test_Fork_FullSeriesOnRealContracts() public {
        if (!live) return;
        for (uint256 i; i < 340; ++i) {
            vm.warp(block.timestamp + 30 minutes);
            vm.roll(block.number + 150);
            recorder.poke();
        }
        uint256 id = ws.openSeries(0, 0);
        Wallstrike.Series memory s = ws.getSeries(id);
        (int24 wallTick,,) = HOOK.backstop();
        console2.log("strike (wei per IMD)", s.strike);
        console2.log("wall price (wei per IMD)", TickPrice.ethPerImd(wallTick));
        console2.log("floor premium rate (1e18 = 100%)", s.floorRate);
        assertLe(s.strike, TickPrice.ethPerImd(wallTick));

        vm.prank(writer);
        ws.deposit{value: 5 ether}(id);
        vm.warp(s.auctionStart);
        recorder.poke();

        // A real sIMD holder takes a Floor Loan; a buyer takes tickets for 1,000 IMD.
        deal(address(IMD), borrower, 1000e18);
        vm.startPrank(borrower);
        IMD.approve(address(SIMD), 1000e18);
        (bool ok,) = address(SIMD).call(abi.encodeWithSignature("deposit(uint256,address)", 1000e18, borrower));
        assertTrue(ok);
        uint256 shares = SIMD.balanceOf(borrower);
        SIMD.approve(address(ws), shares);
        (uint256 loanId, uint256 principal) = ws.borrow(id, shares, 0);
        vm.stopPrank();
        console2.log("loan principal for 1,000 IMD of sIMD (wei)", principal);

        vm.prank(buyer);
        uint256 premium = ws.buyTickets{value: 5 ether}(id, 1000e18, 5 ether, 0);
        console2.log("premium for 1,000 IMD of tickets (wei)", premium);

        // At expiry the buyer delivers sIMD; the borrower lets the loan default.
        vm.warp(s.expiry);
        deal(address(IMD), buyer, 2000e18);
        vm.startPrank(buyer);
        IMD.approve(address(SIMD), 2000e18);
        (ok,) = address(SIMD).call(abi.encodeWithSignature("deposit(uint256,address)", 2000e18, buyer));
        assertTrue(ok);
        SIMD.approve(address(ws), type(uint256).max);
        uint256 paid = ws.exercise(id, 1000e18, true); // same block as the deposit: the hold does not matter
        vm.stopPrank();
        assertEq(paid, 1000e18 * s.strike / 1e18);

        vm.warp(uint256(s.expiry) + ws.EXERCISE_WINDOW());
        vm.startPrank(writer);
        ws.claimRelease(id);
        (uint256 eth,, uint256 simdOut) = ws.claim(id);
        vm.stopPrank();
        assertGt(simdOut, shares); // delivered sIMD plus the defaulted loan's collateral
        assertGt(eth, 0);
        assertEq(loanId, 1);
        assertLe(address(ws).balance, ws.feesAccrued() + 5);
    }

    function test_Fork_VaultRoundOnRealContracts() public {
        if (!live) return;
        for (uint256 i; i < 340; ++i) {
            vm.warp(block.timestamp + 30 minutes);
            vm.roll(block.number + 150);
            recorder.poke();
        }
        WriterVault vault = new WriterVault(ws, 0, 0);
        vm.prank(writer);
        vault.deposit{value: 4 ether}();
        uint256 id = vault.startRound();
        Wallstrike.Series memory s = ws.getSeries(id);

        vm.warp(s.auctionStart);
        recorder.poke();
        vm.prank(buyer);
        ws.buyTickets{value: 5 ether}(id, 1000e18, 5 ether, 0);

        vm.warp(s.expiry);
        deal(address(IMD), buyer, 1000e18);
        vm.startPrank(buyer);
        IMD.approve(address(ws), 1000e18);
        ws.exercise(id, 1000e18, false);
        vm.stopPrank();

        vm.warp(uint256(s.expiry) + ws.EXERCISE_WINDOW());
        vault.endRound();
        vm.prank(writer);
        (, uint256 imdOut,) = vault.claim();
        uint256 shares = vault.accountOf(writer).shares;
        console2.log("vault ETH per writer after the round (wei)", vault.previewWithdraw(shares));
        console2.log("IMD delivered to the writer", imdOut);
        assertApproxEqAbs(imdOut, 1000e18, 1e10);
        vm.prank(writer);
        vault.withdraw(shares);
        assertLe(address(vault).balance, 1e9);
    }
}
