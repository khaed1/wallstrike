// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @notice Converts ETH/IMD pool ticks to prices.
/// @dev In POOL4 and the main ETH/IMD pool, currency0 is native ETH and currency1 is IMD, so
/// tick = log_1.0001(IMD per ETH). A higher tick therefore means cheaper IMD.
library TickPrice {
    uint256 internal constant Q96 = 2 ** 96;

    /// @notice ETH (in wei) paid for 1e18 wei of IMD at `tick`.
    function ethPerImd(int24 tick) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        return FullMath.mulDiv(FullMath.mulDiv(1e18, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }
}
