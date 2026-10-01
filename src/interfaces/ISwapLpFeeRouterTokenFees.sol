// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISwapLpFeeRouterTokenFees
/// @notice The token-side LP fee surface of `SwapLpFeeRouter`: LP fees a pool collected in the Realm token
///         itself, held until a keeper sells them for the pool's quote and routes the proceeds through the
///         usual split.
/// @dev Separate from `ISwapLpFeeRouter`, which the whitelisted hooks import and which must not change.
interface ISwapLpFeeRouterTokenFees {
    /// @notice `tokenIn` of `token`'s pending LP fees were sold for `quoteOut` of `quote`. Emitted after the
    ///         swap and before the routing event (`LpFeesRouted` / `LpAssetFeesRouted`) for the proceeds.
    event LpTokenFeesConverted(address indexed token, address indexed quote, uint256 tokenIn, uint256 quoteOut);

    /// @notice Pulls `amount` of `token` from the caller into `token`'s pending bucket for `quote`'s pool.
    ///         Permissionless: the caller donates its own tokens.
    function depositTokenFees(address token, address quote, uint256 amount) external;

    /// @notice `token` LP fees collected in `quote`'s pool and not yet converted.
    function pendingTokenFees(address token, address quote) external view returns (uint256);

    /// @notice Sells the whole pending bucket of (`token`, `quote`) in the token's own pool through the
    ///         `RealmSwapper`, requiring `minOut`, and routes the proceeds through the 30/70 split.
    ///         Keeper-gated (`RealmKeepersRegistry`): a permissionless caller could sandwich it atomically.
    function convertTokenFees(address token, address quote, uint256 minOut) external returns (uint256 quoteOut);
}
