// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LimitReason} from "src/interfaces/IRealmQuoter.sol";

/// @title IRealmQuoter2
/// @notice v2 of `IRealmQuoter`: identical surface, except the two buy quotes now also report
///         `canGraduate` — `true` when broadcasting the quoted buy would top the bonding curve past
///         its graduation threshold and trigger graduation within the same tx. Lets the frontend
///         warn (or relabel the CTA) before a graduating buy. Reuses the `LimitReason` enum from
///         `IRealmQuoter`.
/// @dev    Same non-revert guarantee as `IRealmQuoter`: every quote returns rather than reverts, and
///         the numeric fields are safe to broadcast against `RealmLaunchpad` without any cap-related
///         revert. See `IRealmQuoter` for the full contract-level documentation; this interface only
///         widens the two buy-quote structs.
interface IRealmQuoter2 {
    /// @notice Result of `quoteBuyTokensWithExactEth`.
    /// @param ethSpent ETH the caller will actually spend (≤ requested `ethValue`). Use this
    ///        value as `msg.value` on the corresponding `buyTokensWithExactEth` call. Equal to
    ///        the input `ethValue` when `reason == NONE`.
    /// @param ethFee Trading fee deducted from `ethSpent` (in ETH).
    /// @param tokensToReceive Tokens the buyer will receive in exchange for `ethSpent`.
    /// @param canGraduate True if broadcasting this buy would trigger graduation.
    /// @param reason Which cap clamped the input, or `NONE` if the request was honored.
    struct BuyExactEthQuote {
        uint256 ethSpent;
        uint256 ethFee;
        uint256 tokensToReceive;
        bool canGraduate;
        LimitReason reason;
    }

    /// @notice Result of `quoteBuyExactTokens`.
    /// @param tokensReceived Tokens the buyer will actually receive (≤ requested `tokenAmount`).
    ///        When `reason == SNIPER_CAP` this may be a few wei below the sniper cap because
    ///        the bonding curve's inverse is not exactly invertible — see contract docs.
    /// @param ethFee Trading fee in ETH.
    /// @param ethForReserves ETH that goes into the curve reserves.
    /// @param totalEthNeeded `msg.value` the caller must send on `buyTokensWithExactEth`.
    /// @param canGraduate True if broadcasting this buy would trigger graduation.
    /// @param reason Which cap clamped the input, or `NONE`.
    struct BuyExactTokensQuote {
        uint256 tokensReceived;
        uint256 ethFee;
        uint256 ethForReserves;
        uint256 totalEthNeeded;
        bool canGraduate;
        LimitReason reason;
    }

    /// @notice Result of `quoteSellExactTokens`.
    /// @param tokensSold Tokens the seller will actually sell (≤ requested `tokenAmount`).
    /// @param ethPulledFromReserves Pre-fee ETH amount removed from curve reserves.
    /// @param ethFee Trading fee in ETH.
    /// @param ethForSeller Net ETH the seller receives.
    /// @param reason Which cap clamped the input, or `NONE`.
    struct SellExactTokensQuote {
        uint256 tokensSold;
        uint256 ethPulledFromReserves;
        uint256 ethFee;
        uint256 ethForSeller;
        LimitReason reason;
    }

    /// @notice Result of `quoteSellTokensForExactEth`.
    /// @param ethReceived Net ETH the seller receives (≤ requested `ethAmount`).
    /// @param ethFee Trading fee in ETH.
    /// @param ethPulledFromReserves Pre-fee ETH amount removed from curve reserves.
    /// @param tokensRequired Tokens the seller must approve / send on `sellExactTokens`.
    /// @param reason Which cap clamped the input, or `NONE`.
    struct SellForExactEthQuote {
        uint256 ethReceived;
        uint256 ethFee;
        uint256 ethPulledFromReserves;
        uint256 tokensRequired;
        LimitReason reason;
    }

    /// @notice Quote a buy with an exact ETH input, taking every cap into account.
    /// @param token The token to buy.
    /// @param buyer The address that will receive the tokens. Must match the actual `msg.sender`
    ///        of the eventual `buyTokensWithExactEth` call — the sniper cap is buyer-aware.
    /// @param ethValue The ETH amount the caller would like to spend.
    /// @return q See `BuyExactEthQuote`. `q.ethSpent ≤ ethValue` and is safe to use as
    ///         `msg.value` on `RealmLaunchpad.buyTokensWithExactEth(token, 0, deadline)`.
    function quoteBuyTokensWithExactEth(address token, address buyer, uint256 ethValue)
        external
        view
        returns (BuyExactEthQuote memory q);

    /// @notice Quote a buy targeting an exact token output, taking every cap into account.
    /// @param token The token to buy.
    /// @param buyer The address that will receive the tokens.
    /// @param tokenAmount The number of tokens the caller would like to receive.
    /// @return q See `BuyExactTokensQuote`. `q.totalEthNeeded` is safe to use as `msg.value`.
    /// @dev   When the sniper cap is binding, `q.tokensReceived` may be a few wei below the cap
    ///        (≤ `~1e9` token-wei, i.e. `< 1e-9` whole tokens) because the curve is not
    ///        symmetrically invertible. The frontend can ignore this drift for any practical
    ///        display purpose.
    function quoteBuyExactTokens(address token, address buyer, uint256 tokenAmount)
        external
        view
        returns (BuyExactTokensQuote memory q);

    /// @notice Quote a sell with an exact token input.
    /// @dev   Sells are not subject to the sniper cap (it only fires on launchpad → buyer
    ///        transfers). Possible non-`NONE` reasons: `INVALID_TOKEN`, `GRADUATED`,
    ///        `INSUFFICIENT_RESERVES`.
    function quoteSellExactTokens(address token, uint256 tokenAmount)
        external
        view
        returns (SellExactTokensQuote memory q);

    /// @notice Quote a sell targeting an exact ETH output (post-fee).
    /// @dev   Same caveats as `quoteSellExactTokens`.
    function quoteSellTokensForExactEth(address token, uint256 ethAmount)
        external
        view
        returns (SellForExactEthQuote memory q);

    /// @notice Largest ETH amount `buyer` may spend on `token` right now without tripping any
    ///         cap. Buyer-aware variant of `RealmLaunchpad.getMaxEthToSpend`.
    /// @return maxEth The safe upper bound. Spending exactly `maxEth` via
    ///         `RealmLaunchpad.buyTokensWithExactEth{value: maxEth}(token, 0, deadline)` is
    ///         guaranteed not to revert with any cap-related error.
    /// @return reason Which cap defines `maxEth`. Possible values: `GRADUATION_EXCESS`,
    ///         `SNIPER_CAP`, `INVALID_TOKEN`, or `GRADUATED`. (`NONE` is never returned — there
    ///         is always a defining cap pre-graduation.)
    function getMaxEthToSpend(address token, address buyer) external view returns (uint256 maxEth, LimitReason reason);
}
