// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";

struct TokenConfig {
    /// @notice Bonding curve address. Cannot be altered once is set
    IRealmBondingCurve bondingCurve;
}

struct TokenState {
    /// @notice Total ETH collected by the token purchases, which will be used mostly for liquidity
    uint256 ethCollected;
    /// @notice Amount of tokens in circulation outside Realm Launchpad (that have been sold)
    uint256 releasedSupply;
    /// @notice This is set to true once graduated, meaning it is no longer tradable from the launchpad
    bool graduated;
}

library TokenDataLib {
    function exists(TokenConfig storage config) internal view returns (bool) {
        // NB: in createToken, bondingCurve==address(0) is not allowed
        return address(config.bondingCurve) != address(0);
    }

    function notGraduated(TokenState storage state) internal view returns (bool) {
        return !state.graduated;
    }
}
