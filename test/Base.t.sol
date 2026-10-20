// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ImdPriceRecorder} from "../src/ImdPriceRecorder.sol";
import {Wallstrike} from "../src/Wallstrike.sol";
import {ICappedBurnHook} from "../src/interfaces/ICappedBurnHook.sol";
import {IStakedIMD} from "../src/interfaces/IStakedIMD.sol";
import {MockIMD, MockStakedIMD, MockCappedBurnHook, MockPoolManager} from "./mocks/Mocks.sol";

abstract contract BaseTest is Test {
    PoolId internal constant MAIN_POOL = PoolId.wrap(keccak256("main ETH/IMD pool"));
    int24 internal constant SPOT_TICK = 60_000; // about 0.00248 ETH per IMD
    int24 internal constant WALL_TICK = 63_840; // about 0.00169 ETH per IMD

    MockIMD internal imd;
    MockStakedIMD internal simd;
    MockCappedBurnHook internal hook;
    MockPoolManager internal manager;
    ImdPriceRecorder internal recorder;
    Wallstrike internal ws;

    address internal owner = makeAddr("owner");
    address internal feeTo = makeAddr("feeTo");
    address internal alice = makeAddr("alice"); // writer
    address internal bob = makeAddr("bob"); // writer
    address internal carol = makeAddr("carol"); // ticket buyer
    address internal dave = makeAddr("dave"); // borrower
    address internal mallory = makeAddr("mallory");

    function setUp() public virtual {
        vm.warp(1_790_000_000);
        vm.roll(26_000_000);
        imd = new MockIMD();
        simd = new MockStakedIMD(address(imd));
        hook = new MockCappedBurnHook();
        manager = new MockPoolManager();
        recorder = new ImdPriceRecorder(
            ICappedBurnHook(address(hook)), IPoolManager(address(manager)), IStakedIMD(address(simd)), MAIN_POOL
        );
        ws = new Wallstrike(IERC20(address(imd)), IStakedIMD(address(simd)), ICappedBurnHook(address(hook)), recorder, owner, feeTo, address(0));

        // sIMD worth about 8 IMD per 1e24 shares, like mainnet.
        imd.mint(address(this), 1_000_000e18);
        imd.approve(address(simd), type(uint256).max);
        simd.deposit(100_000e18, address(this));
        imd.transfer(address(simd), 700_000e18);

        setMarket(SPOT_TICK, SPOT_TICK, WALL_TICK);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dave, 100 ether);
        vm.deal(mallory, 100 ether);
    }

    function setMarket(int24 ref, int24 mainTick, int24 wall) internal {
        hook.setRefTick(ref);
        hook.setWall(wall, 1e20);
        manager.setPool(MAIN_POOL, TickMath.getSqrtPriceAtTick(mainTick), mainTick, 1e21);
    }

    /// @dev Advances one recorder slot at a time and records a sample in each.
    function seed(uint256 samples) internal {
        for (uint256 i; i < samples; ++i) {
            vm.warp(block.timestamp + 30 minutes);
            vm.roll(block.number + 150);
            recorder.poke();
        }
    }

    function giveImd(address to, uint256 amount) internal {
        imd.mint(to, amount);
    }

    function giveSimd(address to, uint256 imdAmount) internal returns (uint256 shares) {
        imd.mint(address(this), imdAmount);
        shares = simd.deposit(imdAmount, to);
    }

    /// @dev Opens a series and fills it with `aliceEth` and `bobEth` of writer deposits.
    function openAndFund(uint8 line, uint8 tenorId, uint256 aliceEth, uint256 bobEth) internal returns (uint256 id) {
        id = ws.openSeries(line, tenorId);
        if (aliceEth != 0) {
            vm.prank(alice);
            ws.deposit{value: aliceEth}(id);
        }
        if (bobEth != 0) {
            vm.prank(bob);
            ws.deposit{value: bobEth}(id);
        }
    }

    function toAuction(uint256 id) internal {
        vm.warp(ws.getSeries(id).auctionStart);
        freshen();
    }

    /// @dev Records a sample for the current slot if it has none, as the keeper would.
    function freshen() internal {
        if (!recorder.sample(block.timestamp / 30 minutes).valid) recorder.poke();
    }

    function toExpiry(uint256 id) internal {
        vm.warp(ws.getSeries(id).expiry);
    }

    function toSettled(uint256 id) internal {
        vm.warp(uint256(ws.getSeries(id).expiry) + ws.EXERCISE_WINDOW());
    }
}
