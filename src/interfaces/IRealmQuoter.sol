// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Reason a quoter clamped (or refused) the caller's input.
/// @dev    Returned in every quote struct as `reason`. `NONE` means the quote was honored
///         verbatim; any other value means the input was reduced (or the quote refused) because
///         the named cap was binding. Each variant maps to a specific recoverable UX state — the
///         frontend should branch on this code to display the right copy/affordance.
///
///         Enum-to-uint mapping (ABI-side; Solidity emits enums as `uint8`):
///         | Reason                | Code |
///         | --------------------- | ---- |
///         | NONE                  | 0    |
///         | INVALID_TOKEN         | 1    |
///         | GRADUATED             | 2    |
///         | GRADUATION_EXCESS     | 3    |
///         | SNIPER_CAP            | 4    |
///         | NOT_ENOUGH_SUPPLY     | 5    |
///         | INSUFFICIENT_RESERVES | 6    |
enum LimitReason {
    /// @notice No cap was binding. The quote matches the caller's exact request.
    /// @dev    UX: render the trade with no warning. The returned numbers are byte-identical
    ///         to what `RealmLaunchpad.quoteBuy*` / `quoteSell*` would return for the same input.
    NONE,
    /// @notice The token isn't registered with this launchpad. All numeric fields are zero.
    /// @dev    UX: probably a stale URL or a token from a different deployment. Disable the
    ///         trade form and surface a clear error. Verify the token address.
    INVALID_TOKEN,
    /// @notice The token has already graduated. Pre-graduation entry points are locked.
    /// @dev    UX: redirect the user to the post-graduation venue (Uniswap V2/V4 pool). All
    ///         numeric fields are zero. Use the post-graduation router/hook for trading.
    GRADUATED,
    /// @notice The launchpad's per-curve graduation excess cap (`maxEthReserves - ethCollected`,
    ///         fee-inclusive) was the binding cap. Source: `RealmLaunchpad.getMaxEthToSpend`.
    /// @dev    UX: show the user that they're about to top off the curve and (likely) trigger
    ///         graduation. The returned `ethSpent` is the maximum the curve will accept right
    ///         now without reverting with `MaxEthReservesExceeded`.
    GRADUATION_EXCESS,
    /// @notice The token's anti-sniper cap was the binding cap. Source: `IRealmToken.maxTokenPurchase(buyer)`.
    ///         Combines the per-tx cap (`maxBuyPerTxBps × TOTAL_SUPPLY`) and the per-wallet cap
    ///         (`maxWalletBps × TOTAL_SUPPLY - balanceOf(buyer)`); the smaller wins. Only applies
    ///         pre-graduation, only on bonding-curve buys, only inside the protection window, and
    ///         only for non-whitelisted buyers.
    /// @dev    UX: explain that this token has temporary anti-sniper limits and show the
    ///         remaining window (`launchTimestamp + protectionWindowSeconds - block.timestamp`).
    ///         The returned `ethSpent` / `totalEthNeeded` is the largest amount that won't trip
    ///         the cap given the buyer's current balance.
    SNIPER_CAP,
    /// @notice The launchpad's available token balance (`balanceOf(launchpad)`) was the binding
    ///         cap. Practically only fires on `quoteBuyExactTokens` when the user requested more
    ///         tokens than remain in the bonding curve.
    /// @dev    UX: tell the user "only X tokens left on the bonding curve". Numeric output is
    ///         clamped to the available supply.
    NOT_ENOUGH_SUPPLY,
    /// @notice The launchpad's ETH reserves for this token (`ethCollected`) were not large
    ///         enough to honor the requested sell. Only used by the sell quotes.
    /// @dev    UX: the input has been reduced to the largest sell the launchpad's reserves can
    ///         currently service. In normal launchpad operation this is dead code; it's only
    ///         reachable if the launchpad's accounting was perturbed externally.
    INSUFFICIENT_RESERVES
}

/// @title IRealmQuoter
/// @notice Single source of truth for trade quoting on the Realm bonding curve. Aggregates caps
///         from `RealmLaunchpad` (graduation excess, available supply, ETH reserves) and from the
///         token (per-buyer anti-sniper cap), clamps the caller's input to whatever cap is
///         currently binding, and tells the caller which cap clamped via a `LimitReason` code.
/// @dev    **Non-revert guarantee.** Every quote returns rather than reverts. When `reason` is
///         `INVALID_TOKEN` or `GRADUATED`, the numeric fields are all zero and the caller should
///         not broadcast the trade. For all other `reason` values, the numeric fields are
///         consistent with each other and the buy/sell *will not revert with any cap-related
///         error* if the caller broadcasts the corresponding launchpad call:
///         - `RealmLaunchpad.buyTokensWithExactEth{value: q.ethSpent}(token, 0, deadline)` —
///           safe to call when `q = quoter.quoteBuyTokensWithExactEth(...)`.
///         - `RealmLaunchpad.buyTokensWithExactEth{value: q.totalEthNeeded}(token, 0, deadline)` —
///           safe to call when `q = quoter.quoteBuyExactTokens(...)`.
///         - `RealmLaunchpad.sellExactTokens(token, q.tokensSold, 0, deadline)` —
///           safe to call when `q = quoter.quoteSellExactTokens(...)`.
///         - `RealmLaunchpad.sellExactTokens(token, q.tokensRequired, 0, deadline)` —
///           safe to call when `q = quoter.quoteSellTokensForExactEth(...)`.
///
///         Slippage / deadline / msg.value-mismatch reverts are still possible — those aren't
///         caps and remain the caller's responsibility.
interface IRealmQuoter {
    /// @notice Result of `quoteBuyTokensWithExactEth`.
    /// @param ethSpent ETH the caller will actually spend (≤ requested `ethValue`). Use this
    ///        value as `msg.value` on the corresponding `buyTokensWithExactEth` call. Equal to
    ///        the input `ethValue` when `reason == NONE`.
    /// @param ethFee Trading fee deducted from `ethSpent` (in ETH).
    /// @param tokensToReceive Tokens the buyer will receive in exchange for `ethSpent`.
    /// @param reason Which cap clamped the input, or `NONE` if the request was honored.
    struct BuyExactEthQuote {
        uint256 ethSpent;
        uint256 ethFee;
        uint256 tokensToReceive;
        LimitReason reason;
    }

    /// @notice Result of `quoteBuyExactTokens`.
    /// @param tokensReceived Tokens the buyer will actually receive (≤ requested `tokenAmount`).
    ///        When `reason == SNIPER_CAP` this may be a few wei below the sniper cap because
    ///        the bonding curve's inverse is not exactly invertible — see contract docs.
    /// @param ethFee Trading fee in ETH.
    /// @param ethForReserves ETH that goes into the curve reserves.
    /// @param totalEthNeeded `msg.value` the caller must send on `buyTokensWithExactEth`.
    /// @param reason Which cap clamped the input, or `NONE`.
    struct BuyExactTokensQuote {
        uint256 tokensReceived;
        uint256 ethFee;
        uint256 ethForReserves;
        uint256 totalEthNeeded;
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
