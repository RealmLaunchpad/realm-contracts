# DEPLOY_UNIFIED.md — deploying the Realm AnyPairs V4 stack on Robinhood Chain (chainid 4663)

**Nothing here has been broadcast.** Every constructor and setter below was read from `src/`. Where this file and the
source disagree, the source wins.

**Unaudited changes are in this stack** (rounds 105–108, see `docs/INTEGRATION_CHECKLIST.md`). Deploy to production only
after review.

---

## 0. What gets deployed

| # | contract | kind | constructor |
|---|---|---|---|
| 1 | `RealmAnyPairsSplitLib` | linked library | — |
| 2 | `RealmAnyPairsV4TokenDeployer` | linked library | — |
| 3 | `RealmAnyPairsV4PairTrackerDeployer` | linked library (also deploys `RealmAnyPairsDividendTrackerAutoBasket`) | — |
| 4 | `RealmAnyPairsV4MultiPairTrackerDeployer` | linked library (checked for code by the launcher) | — |
| 5 | `RealmAnyPairsInSwapRegistry` | owned, never renounceable | `(address owner_)` |
| 6 | `RealmAnyPairsTaxHookPairImmutable` | CREATE2, address must carry hook flags `0x20CC` | `(IPoolManager pm, address owner_, address platform_)` |
| 7 | `RealmAnyPairsV4PairLpLockerImmutable` | CREATE | `(IPoolManager pm, address owner_)` |
| 8 | `RealmAnyPairsV4UnifiedLauncher` | CREATE | `(IPoolManager pm, hook, address weth_, address router_, address v3Factory_, locker, string base, address owner_)` |

Optional, separate: `RealmAnyPairsPlatformFeeConverter` `(weth, router, v3Factory, hook, admin, treasury, maxGasPrice,
tip, poolManager)` — converts platform fees to ETH; not needed by the launch path.

`src/RealmAnyPairsV4PairLauncherImmutable.sol` is **not** part of the stack. Never deploy it.

Order is fixed: **libraries → build linked → registry → mine hook salt → hook → locker → launcher → wiring.** Library
addresses are baked into the hook's and launcher's bytecode, and the hook's CREATE2 address depends on that bytecode.

## 1. Inputs

| input | value |
|---|---|
| PoolManager (Uniswap V4) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| SwapRouter02 (Uniswap V3) | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| Uniswap V3 factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` — the **raw factory**; the launcher does not verify it |
| USDG (reference) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| `OWNER` | Realm's owner key — owns the hook, locker, launcher and registry until renounce |
| `ADMIN` | Realm's admin key — survives renounce; can CTO, lower rates, set platform rates, rescue |
| `PLATFORM` | address that receives the platform fee |
| `BASE_URI` | Realm's token metadata base URI (the launcher appends the coin address + `.json`) |

Re-verify the external addresses on chain before broadcasting (`cast code <addr> --rpc-url $RPC` must be non-empty).

```bash
export RPC=<robinhood rpc>          # the public RPC blocks Foundry's user agent; use a private RPC or a relay
export PK=<deployer private key>     # never echo, never commit
export PM=0x8366a39CC670B4001A1121B8F6A443A643e40951
export WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
export ROUTER=0xCaf681a66D020601342297493863E78C959E5cb2
export V3FACTORY=0x1f7d7550B1b028f7571E69A784071F0205FD2EfA
export OWNER=<owner> ADMIN=<admin> PLATFORM=<platform> BASE_URI=<https://.../t/>
```

## 2. Test first

```bash
forge test --no-match-path "test/fork/*"
FORK_RPC_URL=$RPC forge test --match-path "test/fork/*" -vv
```

## 3. Libraries

```bash
forge create --rpc-url $RPC --private-key $PK --broadcast src/RealmAnyPairsSplitLib.sol:RealmAnyPairsSplitLib
forge create --rpc-url $RPC --private-key $PK --broadcast src/RealmAnyPairsV4TokenDeployer.sol:RealmAnyPairsV4TokenDeployer
forge create --rpc-url $RPC --private-key $PK --broadcast src/RealmAnyPairsV4PairTrackerDeployer.sol:RealmAnyPairsV4PairTrackerDeployer
forge create --rpc-url $RPC --private-key $PK --broadcast src/RealmAnyPairsV4MultiPairTrackerDeployer.sol:RealmAnyPairsV4MultiPairTrackerDeployer
export SPLITLIB=<addr> TOKENDEP=<addr> PAIRTRKDEP=<addr> MULTITRKDEP=<addr>
```

Every later build and `forge create` must link them. Pass them on the command line — **never commit a `libraries` pin to
`foundry.toml`** (it would redirect the test suite to on-chain code):

```bash
export LIBS="--libraries src/RealmAnyPairsSplitLib.sol:RealmAnyPairsSplitLib:$SPLITLIB \
  --libraries src/RealmAnyPairsV4TokenDeployer.sol:RealmAnyPairsV4TokenDeployer:$TOKENDEP \
  --libraries src/RealmAnyPairsV4PairTrackerDeployer.sol:RealmAnyPairsV4PairTrackerDeployer:$PAIRTRKDEP \
  --libraries src/RealmAnyPairsV4MultiPairTrackerDeployer.sol:RealmAnyPairsV4MultiPairTrackerDeployer:$MULTITRKDEP"
forge build $LIBS
```

## 4. In-swap registry

```bash
forge create --rpc-url $RPC --private-key $PK --broadcast \
  src/RealmAnyPairsInSwapRegistry.sol:RealmAnyPairsInSwapRegistry --constructor-args $OWNER
export REGISTRY=<addr>
```

A **denylist** that ships empty: every quote may be paid out mid-swap unless the owner denies it. It has no
`renounceOwnership`, so its owner keeps the kill switch forever:

```bash
cast send $REGISTRY "setDeniedBatch(address[],bool)" "[<quote>,...]" true --rpc-url $RPC --private-key <owner key>
```

Deny a quote whose token starts giving control to recipients on transfer (a proxy upgrade adding callbacks or
rebasing). Denial only moves that quote's payouts from push to pull; trading and funds are unaffected. Ownership moves
two-step (`transferOwnership` → `acceptOwnership`). Keep the owner key offline; no multisig is used.

## 5. Hook — CREATE2 with a mined salt

The hook's address must have low 14 bits `0x20CC` (before-initialize, before-swap, after-swap and both return-delta
flags); the launcher reverts `BadHookFlags()` otherwise. An address ending in `20cc` satisfies it.

```bash
ARGS=$(cast abi-encode "c(address,address,address)" $PM $OWNER $PLATFORM)
INIT=$(forge inspect $LIBS src/RealmAnyPairsTaxHookPairImmutable.sol:RealmAnyPairsTaxHookPairImmutable bytecode)${ARGS#0x}
DEPLOYER2=0x4e59b44847b379578588920cA78FbF26c0B4956C   # the standard CREATE2 factory; confirm it has code on chain
cast create2 --deployer $DEPLOYER2 --init-code $INIT --ends-with 20CC
# -> salt + address
cast send $DEPLOYER2 "$(cast concat-hex <salt> $INIT)" --rpc-url $RPC --private-key $PK
export HOOK=<mined address>
cast code $HOOK --rpc-url $RPC | head -c 10   # non-empty
```

The hook refuses to construct if `RealmAnyPairsSplitLib` has no code at the linked address (`SplitLibraryMissing`).

## 6. LP locker

```bash
forge create $LIBS --rpc-url $RPC --private-key $PK --broadcast \
  src/RealmAnyPairsV4PairLpLockerImmutable.sol:RealmAnyPairsV4PairLpLockerImmutable --constructor-args $PM $OWNER
export LOCKER=<addr>
```

## 7. Launcher — 8 arguments, in this order

| # | arg | value |
|---|---|---|
| 1 | `pm` | `$PM` |
| 2 | `pairHook` | `$HOOK` |
| 3 | `weth_` | `$WETH` |
| 4 | `router_` | `$ROUTER` |
| 5 | `v3Factory_` | `$V3FACTORY` |
| 6 | `pairLocker` | `$LOCKER` |
| 7 | `base` | `$BASE_URI` |
| 8 | `owner_` | `$OWNER` |

```bash
forge create $LIBS --rpc-url $RPC --private-key $PK --broadcast \
  src/RealmAnyPairsV4UnifiedLauncher.sol:RealmAnyPairsV4UnifiedLauncher \
  --constructor-args $PM $HOOK $WETH $ROUTER $V3FACTORY $LOCKER "$BASE_URI" $OWNER
export LAUNCHER=<addr>
```

`--constructor-args` is variadic: keep it last on the line. Reverts: `ZeroAddress()` (an empty variable),
`BadHookFlags()` (the hook address), `DeployerLibraryMissing()` (a library not linked or without code). A wrong but
non-zero `v3Factory_` is **not** caught — double-check it.

## 8. Wiring

Send as `$OWNER` (or the deploy key while it is still owner). **Arm the launcher last**: until the two `setLauncher`
calls, nothing can launch.

```bash
# hook
cast send $HOOK "setSwapConfig(address,address)" $WETH $ROUTER --rpc-url $RPC --private-key $PK
cast send $HOOK "setInSwapRegistry(address)" $REGISTRY --rpc-url $RPC --private-key $PK
# optional: platform fee schedule for coins launched from now on (defaults: share 2000, floor 20, cap 100 bps)
# cast send $HOOK "setPlatformRates(uint16,uint16,uint16)" 2000 20 100 --rpc-url $RPC --private-key $PK

# admin keys (survive renounce)
cast send $HOOK "setAdmin(address)" $ADMIN --rpc-url $RPC --private-key $PK
cast send $LOCKER "setAdmin(address)" $ADMIN --rpc-url $RPC --private-key $PK
cast send $LAUNCHER "setAdmin(address)" $ADMIN --rpc-url $RPC --private-key $PK

# LAST: arm the launcher on both the hook and the locker (both, or neither)
cast send $HOOK "setLauncher(address,bool)" $LAUNCHER true --rpc-url $RPC --private-key $PK
cast send $LOCKER "setLauncher(address,bool)" $LAUNCHER true --rpc-url $RPC --private-key $PK
```

A launcher armed on the hook but not the locker can open pools it cannot lock LP for.

## 9. Smoke test — before renouncing

On a throwaway wallet, one launch per family (native, native-rewards, pair, pair-rewards, pair-basket, multi-pair — all
with `*WithMeta`), then for each:

- buy and sell; `totalFeeBpsOf` equals what was charged (a 5% coin charges 5.00%);
- the coin address ends in `0x1110`;
- a basket coin with a stock leg: `setRoute` to the stock's hooked pool, a swap converts (`Converted`), a later swap
  pushes the stock to a holder, `claimPending` and `claimAs` work;
- the creator raises and lowers rates; the admin can only lower;
- `rescue` on a coin sends a stray token to the launcher.

## 10. Renounce — optional, irreversible

`renounceOwnership` reverts until the contract is renounce-ready (`_requireRenounceReady`):

- **hook**: a launcher is allowlisted, `admin` is set, `setSwapConfig` is set, `setInSwapRegistry` is set;
- **locker**: a launcher is allowlisted;
- **launcher**: it is allowlisted on both the hook and the locker.

After renounce, only `admin` keeps powers (CTO, lowering rates, platform rates for future coins, rescue, rotating the
admin). The registry is never renounced.

```bash
cast send $HOOK "renounceOwnership()" --rpc-url $RPC --private-key <owner key>
cast send $LOCKER "renounceOwnership()" --rpc-url $RPC --private-key <owner key>
cast send $LAUNCHER "renounceOwnership()" --rpc-url $RPC --private-key <owner key>
```

## 11. Verify on Blockscout

Verify each contract with its constructor arguments and, for the hook, locker and launcher, the four library links.

```bash
forge verify-contract <addr> <path>:<Contract> --chain 4663 --verifier blockscout \
  --verifier-url <robinhood blockscout api> $LIBS --constructor-args <abi-encoded args>
```

## 12. After deploy

Record every address, then follow `docs/INTEGRATION_CHECKLIST.md` §1–§3 for the frontend and indexer.
