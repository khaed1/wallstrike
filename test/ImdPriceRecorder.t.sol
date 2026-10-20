// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./Base.t.sol";
import {ImdPriceRecorder} from "../src/ImdPriceRecorder.sol";

contract ImdPriceRecorderTest is BaseTest {
    function test_PokeRecordsValidSample() public {
        seed(1);
        ImdPriceRecorder.Sample memory s = recorder.sample(block.timestamp / 30 minutes);
        assertTrue(s.valid);
        assertEq(s.refTick, SPOT_TICK);
        assertEq(s.wallTick, WALL_TICK);
        assertEq(s.simdRate, simd.convertToAssets(1e24));
    }

    function test_ValidSampleCannotBeOverwritten() public {
        seed(1);
        vm.expectRevert(ImdPriceRecorder.AlreadyRecorded.selector);
        recorder.poke();
    }

    function test_InvalidSampleReplacedByValidOne() public {
        vm.warp(block.timestamp + 30 minutes);
        setMarket(SPOT_TICK, SPOT_TICK + 401, WALL_TICK); // main pool pushed away
        assertFalse(recorder.poke());
        vm.expectRevert(ImdPriceRecorder.AlreadyRecorded.selector); // another invalid one is refused
        recorder.poke();
        setMarket(SPOT_TICK, SPOT_TICK + 400, WALL_TICK);
        assertTrue(recorder.poke());
    }

    function test_SampleInvalidWhenPoolUnhealthy() public {
        hook.setMaxRefStep(201);
        seed(1);
        assertFalse(recorder.sample(block.timestamp / 30 minutes).valid);
        hook.setMaxRefStep(200);
        hook.setMarketOpen(false);
        seed(1);
        assertFalse(recorder.sample(block.timestamp / 30 minutes).valid);
        hook.setMarketOpen(true);
        hook.setWall(WALL_TICK, 0);
        seed(1);
        assertFalse(recorder.sample(block.timestamp / 30 minutes).valid);
    }

    function test_MeanTickRoundsTowardCheaperImd() public {
        seed(1);
        setMarket(SPOT_TICK + 1, SPOT_TICK + 1, WALL_TICK);
        seed(1);
        assertEq(recorder.meanTick(2, 2), SPOT_TICK + 1); // mean 60000.5 rounds up
    }

    function test_MeanTickIgnoresInvalidAndOldSamples() public {
        seed(10);
        setMarket(SPOT_TICK + 100, SPOT_TICK + 600, WALL_TICK); // invalid: diverged
        seed(5);
        assertEq(recorder.meanTick(15, 10), SPOT_TICK);
        vm.expectRevert(abi.encodeWithSelector(ImdPriceRecorder.NotEnoughSamples.selector, 10, 11));
        recorder.meanTick(15, 11);
        vm.warp(block.timestamp + 30 days); // everything is now outside the window
        vm.expectRevert(abi.encodeWithSelector(ImdPriceRecorder.NotEnoughSamples.selector, 0, 1));
        recorder.meanTick(336, 1);
    }

    function test_MedianWallTick() public {
        int24[5] memory walls = [int24(64_000), 63_000, 65_000, 63_500, 64_500];
        for (uint256 i; i < walls.length; ++i) {
            setMarket(SPOT_TICK, SPOT_TICK, walls[i]);
            seed(1);
        }
        assertEq(recorder.medianWallTick(5, 5), 64_000);
        setMarket(SPOT_TICK, SPOT_TICK, 70_000);
        seed(1);
        assertEq(recorder.medianWallTick(6, 6), 64_500); // even count: the higher middle tick
    }

    function test_RecentSimdRateGoesStale() public {
        seed(1);
        assertEq(recorder.recentSimdRate(), simd.convertToAssets(1e24));
        vm.warp(block.timestamp + 30 minutes);
        assertEq(recorder.recentSimdRate(), simd.convertToAssets(1e24));
        vm.warp(block.timestamp + 30 minutes);
        vm.expectRevert(ImdPriceRecorder.Stale.selector);
        recorder.recentSimdRate();
    }
}
