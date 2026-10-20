// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OptionMath} from "../src/libraries/OptionMath.sol";
import {TickPrice} from "../src/libraries/TickPrice.sol";

/// @dev Reference values come from Python's math.erf (exact normal CDF) Black-Scholes.
contract MathTest is Test {
    function test_NormCdf() public pure {
        assertApproxEqAbs(OptionMath.normCdf(-3e18), 0.001349898032e18, 1e11);
        assertApproxEqAbs(OptionMath.normCdf(-1e18), 0.158655253931e18, 1e11);
        assertApproxEqAbs(OptionMath.normCdf(-0.5e18), 0.308537538726e18, 1e11);
        assertApproxEqAbs(OptionMath.normCdf(0), 0.5e18, 1e11);
        assertApproxEqAbs(OptionMath.normCdf(0.3e18), 0.617911422189e18, 1e11);
        assertApproxEqAbs(OptionMath.normCdf(1e18), 0.841344746069e18, 1e11);
        assertApproxEqAbs(OptionMath.normCdf(2.5e18), 0.993790334674e18, 1e11);
        assertEq(OptionMath.normCdf(11e18), 1e18);
        assertEq(OptionMath.normCdf(-11e18), 0);
    }

    function test_PutMatchesReference() public pure {
        assertApproxEqRel(OptionMath.put(1e18, 0.9e18, 2e18, 8 days), 0.068755124574e18, 1e12);
        assertApproxEqRel(OptionMath.put(1e18, 0.9e18, 2e18, 31 days), 0.171259371076e18, 1e12);
        assertApproxEqAbs(OptionMath.put(1e18, 0.6e18, 2e18, 31 days), 0.04613273734e18, 2e11);
        assertApproxEqRel(OptionMath.put(1e18, 1.1e18, 0.5e18, 365 days / 4), 0.161904264138e18, 1e12);
        assertApproxEqRel(OptionMath.put(1e18, 0.8e18, 3.5e18, 8 days), 0.100329260752e18, 1e12);
    }

    function test_PutRateAtRealisticPrices() public pure {
        // Spot 0.0025 ETH/IMD, strike at the buy wall 0.0016889, 200% vol, 31 days.
        assertApproxEqRel(OptionMath.putRate(0.0025e18, 0.0016889e18, 2e18, 31 days), 0.103573336641e18, 1e12);
    }

    function test_PutEdgeCases() public pure {
        assertEq(OptionMath.put(1e18, 0.9e18, 2e18, 0), 0);
        assertEq(OptionMath.put(0.8e18, 0.9e18, 2e18, 0), 0.1e18);
        assertEq(OptionMath.put(1e18, 0.9e18, 0, 30 days), 0);
    }

    function testFuzz_PutWithinNoArbitrageBounds(uint256 spot, uint256 strike, uint256 sigma, uint256 tenor) public pure {
        spot = bound(spot, 1e12, 1e21);
        strike = bound(strike, spot / 4, spot * 2);
        sigma = bound(sigma, 0.1e18, 5e18);
        tenor = bound(tenor, 1 days, 60 days);
        uint256 p = OptionMath.put(spot, strike, sigma, tenor);
        uint256 intrinsic = strike > spot ? strike - spot : 0;
        assertLe(p, strike + strike / 1e9);
        assertGe(p + strike / 1e9, intrinsic);
    }

    function test_TickPrice() public pure {
        assertEq(TickPrice.ethPerImd(0), 1e18);
        assertApproxEqRel(TickPrice.ethPerImd(63_840), 1688894981040327, 1e12);
        assertApproxEqRel(TickPrice.ethPerImd(62_852), 1864269930042605, 1e12);
        assertApproxEqRel(TickPrice.ethPerImd(60_015), 2475779594203105, 1e12);
        assertGt(TickPrice.ethPerImd(60_000), TickPrice.ethPerImd(60_001));
    }
}
