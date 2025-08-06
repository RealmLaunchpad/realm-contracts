// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

struct TokenData {
    /// @notice Bonding curve address. Cannot be altered once is set
    address bondingCurve;
    /// @notice Creator of the token. Cannot be altered once is set
    address creator;
    /// @notice Total ETH collected by the token purchases, which will be used mostly for liquidity
    uint256 ethCollected;
    /// @notice ETH fees collected for the creator, claimable at any time
    uint256 creatorFeesCollected;
    /// @notice Trading (buy) fee in basis points (100 bps = 1%)
    uint96 buyFeeBps;
    /// @notice Trading (sell) fee in basis points (100 bps = 1%)
    uint96 sellFeeBps;
    /// @notice Share of the fees in each trade that goes to the creator, in basis points (100 bps = 1%)
    uint96 creatorFeeBps;
    /// @notice This is set to true once graduated, meaning it is no longer tradable from the launchpad
    bool graduated;
}

library TokenDataLib {
    using TokenDataLib for TokenData;

    function exists(TokenData storage self) internal view returns (bool) {
        return self.creator != address(0);
    }

    function notGraduated(TokenData storage self) internal view returns (bool) {
        return !self.graduated;
    }
}
