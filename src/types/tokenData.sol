// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";

struct TokenConfig {
    /// @notice Bonding curve address. Cannot be altered once is set
    ILivoBondingCurve bondingCurve;
    /// @notice Graduation manager address assigned to this token. Cannot be altered once is set
    ILivoGraduator graduator;
    /// @notice Threshold in ETH that must be collected for graduation to happen
    uint256 ethGraduationThreshold;
    /// @notice Max excess eth over graduation threshold
    uint256 maxExcessOverThreshold;
    /// @notice Owner of the token (receives graduation compensation and fees).
    address tokenOwner;
    /// @notice Trading (buy) fee in basis points (100 bps = 1%). Only applies before graduation
    uint16 buyFeeBps;
    /// @notice Trading (sell) fee in basis points (100 bps = 1%). Only applies before graduation
    uint16 sellFeeBps;
}

struct TokenState {
    /// @notice Total ETH collected by the token purchases, which will be used mostly for liquidity
    uint256 ethCollected;
    /// @notice Amount of tokens in circulation outside Livo Launchpad (that have been sold)
    uint256 releasedSupply;
    /// @notice This is set to true once graduated, meaning it is no longer tradable from the launchpad
    bool graduated;
}

library TokenDataLib {
    function exists(TokenConfig storage config) internal view returns (bool) {
        // NB: in createToken, tokenOwner==address(0) is not allowed
        return config.tokenOwner != address(0);
    }

    function notGraduated(TokenState storage state) internal view returns (bool) {
        return !state.graduated;
    }

    /// @dev above this value, the buy transaction should revert
    function maxEthReserves(TokenConfig storage config) internal view returns (uint256) {
        return config.ethGraduationThreshold + config.maxExcessOverThreshold;
    }
}
