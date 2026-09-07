# Realm V4 hooks — diff against the already-whitelisted hook

Two hooks are submitted for whitelisting. Both derive from `LivoSwapHook`, which Uniswap has already
whitelisted and which has been live since 2026-05.

| Reference (whitelisted) | Address |
|---|---|
| `LivoSwapHook` — Ethereum Sepolia | `0x681F2EEf3F43CfC6Eea7BFdAa801135E04ff00cC` |
| `LivoSwapHook` — Robinhood Chain mainnet | `0xdB1902Bc975992828616b0224D9C5Ff907E9c0Cc` |

## Why redeploy at all

`LivoSwapHook.TREASURY` and `LivoSwapHook.FEE_ROUTER` are `immutable`, and both point at addresses the
Realm protocol does not control (the fee-router proxy is owned by a retired key). Neither can be
repointed, so a new deployment is the only way to move them. **That is the entire motivation** — no fee
logic, permission or accounting change is intended.

## Hook A — `RealmSwapHook`

A rename of `LivoSwapHook`. Nothing else. Compiled runtime bytecode is **97.40% byte-identical**
(6162 bytes, 160 differing). Every differing byte is accounted for below — there are no others:

| Runtime offset | Reference | This hook | Cause |
|---|---|---|---|
| 2774, 3135 | `keccak("LivoSwapSell(...)")` | `keccak("RealmSwapSell(...)")` | event renamed |
| 3513, 3675 | `keccak("LivoSwapBuy(...)")` | `keccak("RealmSwapBuy(...)")` | event renamed |
| 6119 | metadata hash | metadata hash | inside the CBOR trailer; changes with any source byte |

The two renamed events are emitted for off-chain indexing only. They are not read by any contract.

The source also adds `virtual` to `_afterSwap()` so Hook B can extend it. This produces **zero**
codegen change — verified by the diff above containing no other differences.

## Hook B — `RealmHook`

`RealmSwapHook` plus one event. The complete source diff is an event declaration and this override:

- `_afterSwap()` reads the pool's post-swap `sqrtPriceX96` and `liquidity` via `StateLibrary`, emits
  `RealmPoolState(address indexed token, bytes32 poolId, uint160 sqrtPriceX96, uint128 liquidity)`,
  then calls `super._afterSwap()` unchanged.

Cost: one `LOG2` and two warm `extsload` reads per swap. It exists so our indexer can stop subscribing
to the singleton `PoolManager.Swap`, where ~99% of the events it receives belong to other people's
pools. Nothing else differs from Hook A.

## Unchanged in both hooks

| Property | Status |
|---|---|
| Persistent storage | **None.** `forge inspect <hook> storage` returns an empty layout for both, exactly as for `LivoSwapHook`. Only two `transient` slots, used within a single swap. |
| Hook permissions | Identical — `BEFORE_SWAP`, `AFTER_SWAP`, `BEFORE_SWAP_RETURNS_DELTA`, `AFTER_SWAP_RETURNS_DELTA` (mask `0xCC`) |
| Fee math and settlement | Byte-identical bytecode across all four swap legs |
| Delta returned to the `PoolManager` | Unchanged |
| External calls made | Unchanged (fee router, then the token's `accrueFees()`) |
| Ownership | Still ownerless — no admin, no upgrade path, no setters |

## Reproducing the Hook A diff

```
git show 6d375c5:src/hooks/LivoSwapHook.sol > src/hooks/LivoSwapHook.sol
forge build
# compare .deployedBytecode.object of
#   out/LivoSwapHook.sol/LivoSwapHook.json
#   out/RealmSwapHook.sol/RealmSwapHook.json
```

Deployed runtime bytecode additionally differs at the 15 `immutable` splice sites (11 for
`BaseHook.poolManager`, 2 each for `FEE_ROUTER` and `TREASURY`), which carry the new addresses — the
change described under "Why redeploy at all".
