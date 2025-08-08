// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "src/interfaces/ILivoBondingCurve.sol";
import "src/interfaces/ILivoGraduator.sol";

struct TokenConfig {
    /// @notice Bonding curve address. Cannot be altered once is set
    ILivoBondingCurve bondingCurve;
    /// @notice Graduation manager address assigned to this token. Cannot be altered once is set
    ILivoGraduator graduator;
    /// @notice Graduation fee in ETH, paid at graduation
    uint256 graduationEthFee;
    /// @notice Threshold in ETH that must be collected before graduation can happen
    uint256 graduationThreshold;
    /// @notice Reserved supply of tokens for creator at graduation
    uint256 creatorReservedSupply;
    /// @notice Creator of the token. Cannot be altered once is set
    address creator;
    /// @notice Trading (buy) fee in basis points (100 bps = 1%)
    uint16 buyFeeBps;
    /// @notice Trading (sell) fee in basis points (100 bps = 1%)
    uint16 sellFeeBps;
    /// @notice Share of the fees in each trade that goes to the creator, in basis points (100 bps = 1%)
    uint16 creatorFeeBps;
}

struct TokenState {
    /// @notice Total ETH collected by the token purchases, which will be used mostly for liquidity
    uint256 ethCollected;
    /// @notice ETH fees collected for the creator, claimable at any time
    uint256 creatorFeesCollected;
    /// @notice Amount of tokens in circulation (that have been sold)
    uint256 circulatingSupply;
    /// @notice This is set to true once graduated, meaning it is no longer tradable from the launchpad
    bool graduated;
}

library TokenDataLib {
    function exists(TokenConfig storage config) internal view returns (bool) {
        return config.creator != address(0);
    }

    function notGraduated(TokenState storage state) internal view returns (bool) {
        return !state.graduated;
    }

    function meetsGraduationCriteria(TokenState storage state, TokenConfig storage config) internal view returns (bool) {
        return state.ethCollected >= config.graduationThreshold + config.graduationEthFee;
    }

    function minimumEthForGraduation(TokenConfig storage config) internal view returns (uint256) {
        return config.graduationThreshold + config.graduationEthFee;
    }
}
