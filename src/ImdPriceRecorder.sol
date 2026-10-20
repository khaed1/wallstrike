// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICappedBurnHook} from "./interfaces/ICappedBurnHook.sol";
import {IStakedIMD} from "./interfaces/IStakedIMD.sol";

/// @title ImdPriceRecorder
/// @notice Builds the IMD price history that no on-chain source provides. Every 30 minutes anyone can
/// record one sample: POOL4's lagged reference tick, the top of POOL4's buy wall, and the sIMD exchange
/// rate. A sample counts only if POOL4 is healthy and its reference tick is within 400 ticks of the main
/// hookless ETH/IMD pool, so moving one pool alone cannot produce a counted sample.
/// @dev Ticks are log_1.0001(IMD per ETH): a higher tick means cheaper IMD. `refTick` follows the closing
/// tick of the previous block that swapped in POOL4: the first POOL4 swap of a block updates it, but only
/// toward that earlier close and by at most `maxRefStep` ticks, so no transaction can set the value it
/// reads. That is what makes the means below expensive to push. No owner, no parameters.
contract ImdPriceRecorder {
    using StateLibrary for IPoolManager;

    uint256 public constant INTERVAL = 30 minutes;
    uint256 public constant RING = 512;
    /// @notice Maximum distance between POOL4's refTick and the main pool's tick for a valid sample.
    int24 public constant MAX_DIVERGENCE = 400;
    /// @notice A sample is invalid if the hook owner has loosened refTick's rate limit beyond this.
    int24 public constant MAX_REF_STEP = 200;
    uint256 internal constant SLOTS_PER_YEAR = 365 days / INTERVAL;
    /// @notice ln(1.0001) in 18-decimal fixed point: the log-price change of one tick.
    uint256 internal constant LN_TICK_WAD = 99995000333308;

    struct Sample {
        uint32 slot;
        int24 refTick;
        int24 wallTick;
        bool valid;
        uint96 simdRate;
    }

    ICappedBurnHook public immutable hook;
    IPoolManager public immutable poolManager;
    IStakedIMD public immutable simd;
    PoolId public immutable mainPoolId;

    Sample[RING] internal _samples;
    uint32 public latestSlot;

    event Recorded(uint256 indexed slot, int24 refTick, int24 mainTick, int24 wallTick, uint256 simdRate, bool valid);

    error AlreadyRecorded();
    error Stale();
    error NotEnoughSamples(uint256 valid, uint256 required);

    constructor(ICappedBurnHook hook_, IPoolManager poolManager_, IStakedIMD simd_, PoolId mainPoolId_) {
        hook = hook_;
        poolManager = poolManager_;
        simd = simd_;
        mainPoolId = mainPoolId_;
    }

    /// @notice Records the sample for the current 30-minute slot. A slot that already has a valid sample
    /// cannot be overwritten; an invalid one can be replaced by a later valid one.
    function poke() external returns (bool valid) {
        uint32 slot = uint32(block.timestamp / INTERVAL);
        Sample storage stored = _samples[slot % RING];
        bool slotTaken = stored.slot == slot;
        if (slotTaken && stored.valid) revert AlreadyRecorded();

        int24 ref = hook.refTick();
        (int24 wallTick,) = _backstop();
        (uint160 mainSqrtPrice, int24 mainTick,,) = poolManager.getSlot0(mainPoolId);
        uint256 rate = simd.convertToAssets(1e24);

        valid = _healthy() && mainSqrtPrice != 0 && poolManager.getLiquidity(mainPoolId) != 0
            && _absDiff(ref, mainTick) <= uint24(MAX_DIVERGENCE) && rate != 0 && rate <= type(uint96).max;
        if (slotTaken && !valid) revert AlreadyRecorded();

        _samples[slot % RING] = Sample({
            slot: slot, refTick: ref, wallTick: wallTick, valid: valid, simdRate: valid ? uint96(rate) : 0
        });
        if (slot > latestSlot) latestSlot = slot;
        emit Recorded(slot, ref, mainTick, wallTick, rate, valid);
    }

    /// @notice Mean refTick over the valid samples of the last `slots` slots, rounded toward the higher
    /// tick (cheaper IMD). Reverts unless at least `minValid` of them are valid.
    function meanTick(uint256 slots, uint256 minValid) external view returns (int24) {
        uint32 current = _currentSlot();
        int256 sum;
        uint256 count;
        for (uint256 i; i < slots && i <= current; ++i) {
            Sample memory s = _samples[(current - i) % RING];
            if (s.slot == current - i && s.valid) {
                sum += s.refTick;
                ++count;
            }
        }
        if (count < minValid || count == 0) revert NotEnoughSamples(count, minValid);
        int256 mean = sum / int256(count);
        if (mean * int256(count) < sum) ++mean;
        return int24(mean);
    }

    /// @notice 25th percentile of the buy wall's top tick over the valid samples of the last `slots` slots,
    /// counted from the lowest tick (the highest IMD price). Moving it toward cheaper IMD takes a wall held
    /// there for three quarters of the window.
    function lowWallTick(uint256 slots, uint256 minValid) external view returns (int24) {
        uint32 current = _currentSlot();
        int24[] memory ticks = new int24[](slots);
        uint256 count;
        for (uint256 i; i < slots && i <= current; ++i) {
            Sample memory s = _samples[(current - i) % RING];
            if (s.slot == current - i && s.valid) ticks[count++] = s.wallTick;
        }
        if (count < minValid || count == 0) revert NotEnoughSamples(count, minValid);
        for (uint256 i = 1; i < count; ++i) {
            int24 key = ticks[i];
            uint256 j = i;
            while (j > 0 && ticks[j - 1] > key) {
                ticks[j] = ticks[j - 1];
                --j;
            }
            ticks[j] = key;
        }
        return ticks[count / 4];
    }

    /// @notice Annualized volatility (1e18 = 100%) of refTick across consecutive valid samples in the last
    /// `slots` slots. Reverts unless at least `minPairs` consecutive pairs exist. refTick is rate limited,
    /// so this understates sudden moves; callers add a markup.
    function realizedVol(uint256 slots, uint256 minPairs) external view returns (uint256) {
        uint32 current = _currentSlot();
        uint256 sumSq;
        uint256 pairs;
        bool havePrev;
        int256 prev;
        for (uint256 i; i < slots && i <= current; ++i) {
            Sample memory s = _samples[(current - i) % RING];
            if (s.slot == current - i && s.valid) {
                if (havePrev) {
                    int256 d = prev - s.refTick;
                    sumSq += uint256(d * d);
                    ++pairs;
                }
                prev = s.refTick;
                havePrev = true;
            } else {
                havePrev = false;
            }
        }
        if (pairs < minPairs || pairs == 0) revert NotEnoughSamples(pairs, minPairs);
        return Math.sqrt(sumSq * SLOTS_PER_YEAR * LN_TICK_WAD * LN_TICK_WAD / pairs);
    }

    /// @notice The higher tick (the cheaper IMD price) of POOL4's current refTick and the main pool's
    /// current tick. Pricing puts off the lower price never undercharges writers; whoever moves the main
    /// pool to raise a price only makes buyers walk away.
    function pessimisticTick() external view returns (int24) {
        int24 ref = hook.refTick();
        (, int24 mainTick,,) = poolManager.getSlot0(mainPoolId);
        return ref > mainTick ? ref : mainTick;
    }

    /// @notice The sIMD rate (IMD per 1e24 shares) of the most recent valid sample in the current or
    /// previous slot.
    function recentSimdRate() external view returns (uint256) {
        uint32 current = _currentSlot();
        for (uint256 i; i < 2 && i <= current; ++i) {
            Sample memory s = _samples[(current - i) % RING];
            if (s.slot == current - i && s.valid) return s.simdRate;
        }
        revert Stale();
    }

    function sample(uint256 slot) external view returns (Sample memory s) {
        s = _samples[slot % RING];
        if (s.slot != slot) delete s;
    }

    /// @notice True when POOL4 is open, funded, rebalancing, and its refTick rate limit is intact.
    function healthy() external view returns (bool) {
        return _healthy();
    }

    function _healthy() internal view returns (bool) {
        if (!hook.marketOpen() || hook.positionLiquidity() == 0 || !hook.rebalanceEnabled()) return false;
        int24 step = hook.maxRefStep();
        if (step <= 0 || step > MAX_REF_STEP) return false;
        (, uint128 wallLiquidity) = _backstop();
        return wallLiquidity != 0;
    }

    function _backstop() internal view returns (int24 lower, uint128 liquidity) {
        (lower,, liquidity) = hook.backstop();
    }

    function _currentSlot() internal view returns (uint32) {
        return uint32(block.timestamp / INTERVAL);
    }

    function _absDiff(int24 a, int24 b) internal pure returns (uint24) {
        return a > b ? uint24(a - b) : uint24(b - a);
    }
}
