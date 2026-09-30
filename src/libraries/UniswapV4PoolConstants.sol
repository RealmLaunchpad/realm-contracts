// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";

/// @title UniswapV4PoolConstants
/// @notice Shared Uniswap V4 pool configuration constants used by the direct graduator and the tokens.
library UniswapV4PoolConstants {
    /// @notice LP fees in pips, i.e. 1e6 = 100%, so 10000 = 1%
    /// @dev Set to 0 because LP fees are now charged by the hook (RealmSwapHook)
    uint24 internal constant LP_FEE = 0;

    /// @notice Tick spacing used to be 200 for volatile pairs in univ3. (60 for 0.3% fee tier)
    /// @dev The larger the spacing the cheaper to swap gas-wise
    int24 internal constant TICK_SPACING = 200;

    /// @notice The canonical PoolKey of a graduated Realm token's V4 pool: `(ETH, token)` with this
    ///         library's fee/spacing and the graduator's hook. THE single source of truth — the
    ///         graduator, the buy-back mixin and the token's liquidity leg must all target the same
    ///         pool, so none of them may hand-roll the key.
    function realmPoolKey(address token, address hook) internal pure returns (PoolKey memory) {
        return realmPoolKey(token, address(0), hook);
    }

    /// @notice The canonical PoolKey of a Realm token against an ARBITRARY quote, with the currencies
    ///         sorted as Uniswap V4 requires. `quote == address(0)` is native, which always sorts as
    ///         `currency0` and reproduces the native-only overload above exactly.
    /// @dev THE single source of truth for every venue: the direct graduator, the buy-back mixin and
    ///      the tokens' liquidity leg must all target the same pool, so none of them may hand-roll the
    ///      key. Sorting here is what lets a token be `currency0` or `currency1` depending on the quote
    ///      it launched against, without any caller having to know.
    function realmPoolKey(address token, address quote, address hook) internal pure returns (PoolKey memory) {
        (address c0, address c1) = quote < token ? (quote, token) : (token, quote);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }
}
