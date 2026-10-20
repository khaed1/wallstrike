// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib as F} from "solady/utils/FixedPointMathLib.sol";

/// @notice Black-Scholes pricing for the premium floor. All values are 18-decimal fixed point.
/// @dev Zero interest rate. The normal CDF uses Abramowitz-Stegun 26.2.17 (absolute error < 7.5e-8),
/// which is far below the precision a premium floor needs.
library OptionMath {
    int256 internal constant WAD = 1e18;
    int256 internal constant INV_SQRT_2PI = 398942280401432678; // 1 / sqrt(2 * pi)
    int256 internal constant P = 231641900000000000;
    int256 internal constant B1 = 319381530000000000;
    int256 internal constant B2 = -356563782000000000;
    int256 internal constant B3 = 1781477937000000000;
    int256 internal constant B4 = -1821255978000000000;
    int256 internal constant B5 = 1330274429000000000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Standard normal cumulative distribution function.
    function normCdf(int256 x) internal pure returns (int256) {
        if (x > 10 * WAD) return WAD;
        if (x < -10 * WAD) return 0;
        int256 ax = x < 0 ? -x : x;
        int256 t = F.sDivWad(WAD, WAD + F.sMulWad(P, ax));
        int256 poly = F.sMulWad(t, B1 + F.sMulWad(t, B2 + F.sMulWad(t, B3 + F.sMulWad(t, B4 + F.sMulWad(t, B5)))));
        int256 pdf = F.sMulWad(INV_SQRT_2PI, F.expWad(-F.sMulWad(ax, ax) / 2));
        int256 upper = WAD - F.sMulWad(pdf, poly);
        return x < 0 ? WAD - upper : upper;
    }

    /// @notice European put value per unit of the underlying, in the strike's units.
    /// @param spot Price of the underlying.
    /// @param strike Strike price, same units as `spot`.
    /// @param sigma Annualized volatility (1e18 = 100%).
    /// @param tenor Time to expiry in seconds.
    function put(uint256 spot, uint256 strike, uint256 sigma, uint256 tenor) internal pure returns (uint256) {
        if (tenor == 0 || sigma == 0) return strike > spot ? strike - spot : 0;
        uint256 sigSqrtT = F.mulWad(sigma, F.sqrtWad(tenor * 1e18 / SECONDS_PER_YEAR));
        int256 s = int256(sigSqrtT);
        int256 d1 = F.sDivWad(F.lnWad(int256(F.divWad(spot, strike))) + F.sMulWad(s, s) / 2, s);
        int256 d2 = d1 - s;
        int256 value = F.sMulWad(int256(strike), normCdf(-d2)) - F.sMulWad(int256(spot), normCdf(-d1));
        return value > 0 ? uint256(value) : 0;
    }

    /// @notice Put value as a fraction of the strike (1e18 = 100%).
    function putRate(uint256 spot, uint256 strike, uint256 sigma, uint256 tenor) internal pure returns (uint256) {
        return F.divWad(put(spot, strike, sigma, tenor), strike);
    }
}
