// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";

/// @title UniswapV4PoolConstantsArc
/// @notice ARC (Circle L1, native currency = USDC) variant of `UniswapV4PoolConstants`.
/// @dev ARC has no ETH: the native currency is USDC ($1), 18-dec at `msg.value`. Everything left here
///      (fee, spacing, pool key) is price-independent, so it matches the ETH library; the file stays so
///      the `chain-arc-*` retarget has the same symbols to swap in.
library UniswapV4PoolConstantsArc {
    /// @notice LP fees in pips. 0 because LP fees are charged by the hook (RealmSwapHook). Chain-invariant.
    uint24 internal constant LP_FEE = 0;

    /// @notice Tick spacing. Chain-invariant (pool granularity, not a price).
    int24 internal constant TICK_SPACING = 200;

    /// @notice The canonical PoolKey of a graduated Realm token's V4 pool: `(native USDC, token)` with
    ///         this library's fee/spacing and the graduator's hook. THE single source of truth — the
    ///         graduator, the buy-back mixin and the token's liquidity leg must all target the same
    ///         pool, so none of them may hand-roll the key.
    function realmPoolKey(address token, address hook) internal pure returns (PoolKey memory) {
        return realmPoolKey(token, address(0), hook);
    }

    /// @notice The canonical PoolKey of a Realm token against an ARBITRARY quote, with the currencies
    ///         sorted as Uniswap V4 requires. `quote == address(0)` is native USDC, which always sorts
    ///         as `currency0` and reproduces the native-only overload above exactly.
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
