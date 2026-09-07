// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {RealmSwapHook} from "src/hooks/RealmSwapHook.sol";

/// @title RealmHook
/// @notice `RealmSwapHook` plus a per-swap `RealmPoolState` log carrying the post-swap pool price and
///         active liquidity, so indexers no longer have to subscribe to the V4 `PoolManager`.
/// @dev Identical fee behaviour to `RealmSwapHook` — this contract adds one event and changes nothing
///      else. Deployed as a separate hook because the base contract is the conservative candidate for
///      Uniswap's hook whitelist; whichever gets approved becomes the manifest's `SWAP_HOOK`.
///
/// @dev WHY: indexing V4 spot price today means subscribing to the singleton `PoolManager.Swap`, which
///      fires for EVERY pool on the chain — Realm's pools are a fraction of a percent of them, so the
///      indexer burns almost all of its sync budget filtering foreign swaps. `sqrtPriceX96` and
///      `liquidity` are the only two fields it reads from that event (`id` just maps pool→token, which
///      the hook already knows), so emitting them here removes the subscription entirely.
///
/// @dev The values are read from the pool AFTER the swap and BEFORE the fee settlement in
///      `RealmSwapHook._afterSwap`. That ordering is deliberate on two counts:
///      - It is the same state `PoolManager.Swap` reports: V4 emits that event from `_swap`, and the
///        hook's fee `take` moves a currency delta without touching `slot0` or `liquidity`, so reading
///        before or after settlement yields identical values.
///      - It keeps `RealmPoolState` at a LOWER log index than the `RealmSwapBuy`/`RealmSwapSell` that
///        follows, mirroring the `PoolManager.Swap` → hook ordering indexers already rely on to have
///        fresh reserves in hand when they process the trade.
contract RealmHook is RealmSwapHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Post-swap state of the token's V4 pool, emitted once per swap leg.
    /// @dev Mirrors the two fields indexers consume from `PoolManager.Swap`. Virtual reserves at the
    ///      active concentrated-liquidity point are `eth = L * 2**96 / sqrtPriceX96` and
    ///      `token = L * sqrtPriceX96 / 2**96`; spot price follows from their ratio.
    /// @param token         The pool's `currency1` (ETH is always `currency0` on Realm pools).
    /// @param sqrtPriceX96  Post-swap `slot0.sqrtPriceX96`.
    /// @param liquidity     Active liquidity at the post-swap tick.
    event RealmPoolState(address indexed token, uint160 sqrtPriceX96, uint128 liquidity);

    constructor(IPoolManager _poolManager, address _router, address _treasury)
        RealmSwapHook(_poolManager, _router, _treasury)
    {}

    /// @inheritdoc RealmSwapHook
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        emit RealmPoolState(Currency.unwrap(key.currency1), sqrtPriceX96, poolManager.getLiquidity(id));

        return super._afterSwap(sender, key, params, delta, hookData);
    }
}
