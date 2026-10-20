// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice The read-only subset of POOL4's CappedBurnHook that Wallstrike uses.
/// @dev Mainnet: 0xc6c965bd164c483e87d0b550671798e9a3602840 (verified source, solc 0.8.30, not upgradeable).
/// Its owner is an EOA that can retune or close the market at any time, so every value read here is
/// treated as untrusted input and checked before use.
interface ICappedBurnHook {
    /// @notice POOL4's id: native ETH (currency0) / IMD (currency1), fee 10000, tick spacing 60.
    function poolId() external view returns (PoolId);

    /// @notice False once the owner has called closeMarket.
    function marketOpen() external view returns (bool);

    /// @notice Liquidity of the hook's full-range market position.
    function positionLiquidity() external view returns (uint128);

    /// @notice The single-sided ETH buy wall above spot. `tickLower` is the wall's top: the highest IMD
    /// price (in ETH) at which the wall buys. A higher tick means cheaper IMD.
    function backstop() external view returns (int24 tickLower, int24 tickUpper, uint128 liquidity);

    /// @notice Owner kill switch for the permissionless wall rebalance.
    function rebalanceEnabled() external view returns (bool);

    /// @notice Rate-limited follower of the previous swap block's closing tick. A transaction cannot move
    /// it, and one update moves it by at most `maxRefStep` ticks.
    function refTick() external view returns (int24);

    /// @notice The per-update limit on `refTick` movement. The owner can set it from 1 to 2000.
    function maxRefStep() external view returns (int24);
}
