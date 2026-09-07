// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmBondingCurve} from "../interfaces/IRealmBondingCurve.sol";

/// @title ConstantProductBondingCurveConfigurable
/// @notice Identical math to `ConstantProductBondingCurve`, but with the shape constants
///         `K`, `T0`, `E0` supplied at deploy time as immutables instead of being hardcoded.
///         Used to deploy the per-allocation creator-vault curves (one instance per locked
///         allocation: 5%, 10%, 15%, 20%, 25%, 30%).
///
///         A creator-vault token locks `vaultBps` of the 1B supply in vesting vaults, so only
///         `S = TOTAL_SUPPLY * (10000 - vaultBps) / 10000` tokens are sold on the curve. The
///         constants are solved so that EVERY graduation invariant is identical to the base curve
///         (eth reserves at graduation, eth into liquidity, tokens into liquidity, graduation
///         price and marketcap); only the starting market cap / starting price is relaxed (it
///         rises, so the start→graduation multiplier shrinks). See
///         `simulations/script/find_creator_vault_curve_params.py`.
///
/// @dev    The graduation threshold / max-excess remain `constant` and IDENTICAL to the base curve,
///         because the launchpad enforces the same graduation window for every token regardless of
///         which curve it uses. Only `K`, `T0`, `E0` change between instances.
contract ConstantProductBondingCurveConfigurable is IRealmBondingCurve {
    // the bonding curve follows the constant product formula:
    // K = (t + T0) * (e + E0)
    // `t` is the reserves of the token in the bonding curve (not sold yet)
    // `e` is the reserves of ETH in the bonding curve (collected from purchases)
    // The token reserves can be expressed as a function of the eth reserves:
    // t = K / (e + E0) - T0

    /// @notice Constant K for the bonding curve formula
    uint256 public immutable K;
    /// @notice Constant T0 for the bonding curve formula
    uint256 public immutable T0;
    /// @notice Constant E0 for the bonding curve formula
    uint256 public immutable E0;

    /// @notice The graduation threshold in terms of ETH reserves. Set per liquidity tier at deploy.
    uint256 internal immutable _GRADUATION_THRESHOLD;

    /// @notice Max amount of eth above the graduation that the curve accepts. Set per liquidity tier at deploy.
    uint256 internal immutable _MAX_EXCESS_OVER_THRESHOLD;

    error InvalidCurveConstants();

    /// @param k Constant K (solved numerically per allocation + liquidity tier)
    /// @param t0 Constant T0 (solved numerically per allocation + liquidity tier)
    /// @param e0 Constant E0 (solved numerically per allocation + liquidity tier)
    /// @param graduationThreshold ETH reserves at which graduation can be triggered (tier-specific)
    /// @param maxExcessOverThreshold_ Max ETH accepted above the graduation threshold
    /// @dev Minimal sanity checks: a non-zero E0/K (the formula divides by `e + E0`), a non-zero
    ///      threshold, and a positive token reserve both at zero eth and at the max graduation
    ///      reserves. These catch a grossly-misconfigured deployment without re-implementing the
    ///      off-chain solver on-chain.
    constructor(uint256 k, uint256 t0, uint256 e0, uint256 graduationThreshold, uint256 maxExcessOverThreshold_) {
        require(e0 > 0 && k > 0 && graduationThreshold > 0, InvalidCurveConstants());
        // token reserves must be strictly positive across the whole live range [0, maxEthReserves]
        require(k / e0 > t0, InvalidCurveConstants());
        require(k / (graduationThreshold + maxExcessOverThreshold_ + e0) > t0, InvalidCurveConstants());
        K = k;
        T0 = t0;
        E0 = e0;
        _GRADUATION_THRESHOLD = graduationThreshold;
        _MAX_EXCESS_OVER_THRESHOLD = maxExcessOverThreshold_;
        // emit the constructor args (not the immutables) to sidestep reading immutables during construction
        emit RealmBondingCurveDeployed(k, t0, e0, graduationThreshold, maxExcessOverThreshold_);
    }

    /// @notice Returns the ETH reserves threshold at which graduation can be triggered
    function ethGraduationThreshold() external view returns (uint256) {
        return _GRADUATION_THRESHOLD;
    }

    /// @notice Returns the maximum ETH excess allowed above the graduation threshold
    function maxExcessOverThreshold() external view returns (uint256) {
        return _MAX_EXCESS_OVER_THRESHOLD;
    }

    /// @notice Returns the graduation configuration
    function getGraduationConfig() external view returns (GraduationConfig memory) {
        return GraduationConfig({
            ethGraduationThreshold: _GRADUATION_THRESHOLD, maxExcessOverThreshold: _MAX_EXCESS_OVER_THRESHOLD
        });
    }

    /// @notice Returns the absolute maximum ETH reserves (graduation threshold + max excess)
    function maxEthReserves() external view returns (uint256) {
        return _maxEthReserves();
    }

    /// @notice Calculates how many tokens can be purchased with a given amount of ETH
    function buyTokensWithExactEth(uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensReceived, bool canGraduate)
    {
        uint256 newEthReserves = ethReserves + ethAmount;
        if (newEthReserves > _maxEthReserves()) {
            revert MaxEthReservesExceeded();
        }

        tokensReceived = K * ethAmount / ((ethReserves + E0) * (ethReserves + ethAmount + E0));
        canGraduate = newEthReserves >= _GRADUATION_THRESHOLD;
    }

    /// @notice Calculates how much ETH will be received when selling an exact amount of tokens
    function sellExactTokens(uint256 ethReserves, uint256 tokenAmount) external view returns (uint256 ethReceived) {
        ethReceived = tokenAmount * (ethReserves + E0) ** 2 / (K + tokenAmount * (ethReserves + E0));
    }

    /// @notice Calculates how much ETH is required to buy an exact amount of tokens
    function buyExactTokens(uint256 ethReserves, uint256 tokenAmount)
        external
        view
        returns (uint256 ethRequired, bool canGraduate)
    {
        uint256 A = ethReserves + E0;
        uint256 denom = K - tokenAmount * A;
        if (denom == 0) revert InsufficientLiquidity();

        uint256 num = tokenAmount * A * A;
        // Ceiling division: round up so the user pays more ETH
        ethRequired = (num + denom - 1) / denom;

        uint256 newEthReserves = ethReserves + ethRequired;
        if (newEthReserves > _maxEthReserves()) revert MaxEthReservesExceeded();

        canGraduate = newEthReserves >= _GRADUATION_THRESHOLD;
    }

    /// @notice Calculates how many tokens must be sold to receive an exact amount of ETH
    function sellTokensForExactEth(uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensRequired)
    {
        uint256 A = ethReserves + E0;
        if (A <= ethAmount) revert InsufficientLiquidity();

        uint256 num = K * ethAmount;
        uint256 denom = A * (A - ethAmount);
        // Ceiling division: round up so the user sells more tokens
        tokensRequired = (num + denom - 1) / denom;
    }

    /// @notice Returns the token reserves for a given amount of ETH reserves
    function getTokenReserves(uint256 ethReserves) external view returns (uint256) {
        return _getTokenReserves(ethReserves);
    }

    ///////////////////////////// INTERNALS //////////////////////////////////

    function _getTokenReserves(uint256 ethReserves) internal view returns (uint256) {
        return K / (ethReserves + E0) - T0;
    }

    function _maxEthReserves() internal view returns (uint256) {
        return _GRADUATION_THRESHOLD + _MAX_EXCESS_OVER_THRESHOLD;
    }
}
