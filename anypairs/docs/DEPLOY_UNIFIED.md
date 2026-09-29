# DEPLOY_UNIFIED.md — deploying the Realm AnyPairs V4 stack on Robinhood Chain (chainid 4663)

**Nothing here has been broadcast.** Every constructor and setter below was read from `src/`. Where this file and the
source disagree, the source wins.

**Unaudited changes are in this stack** (rounds 105–108, see `docs/INTEGRATION_CHECKLIST.md`). Deploy to production only
after review.

---

## `maxCoinTail` has no lowering path, and one cannot be built. Do not retry this.

`maxCoinTail` is a global, monotone ratchet on the singleton hook feeding `_tail()`, the gas reserve every
in-swap step is prechecked against. Launch one gas-heavy coin and the precheck rises for **every pool on the
hook, permanently** -- including long after that coin stops trading. It is bounded (`minDebit` <= 1,133,809, so
`_tail()` <= ~1,613,809) and **liveness-only, never a loss of funds**: when the precheck fails, the work defers
to `distribute` / `runPayouts`.

A lowering path was specified, designed, and **rejected as unbuildable** (2026-09-16). The reason is a proof, not
a preference:

1. **Every raise comes from a coin with a live pool.** `_noteTail` has exactly three callers, each gated on a
   configured pool: `configurePool` (right after `_coinPools[coin].push(id)`), `refreshCoinTail`
   (`_coinPools[coin].length != 0`), and `adminSetRewardsTracker` (after walking `_coinPools[coin]`). There is no
   orphan contributor.
2. **A coin never stops being live.** `_coinPools` has exactly ONE mutation site in the whole contract -- the
   `.push(id)` in `configurePool`. No pop, no delete, no deconfigure; `configured` is never cleared. Pool
   membership is permanent and trading on those pools is permissionless and never expires.
3. **A coin's requirement never decreases.** `_coinTail(coin) = max(SWAP_TAIL_RESERVE, minDebit + SWAP_TAIL_MARGIN)`,
   and `minDebit` derives solely from the coin's `trackerSyncGas`, which is written ONCE and guarded against
   rewriting (`TrackerAlreadySet`) in both `RealmAnyPairsTokenDividend.initTracker` and
   `RealmAnyPairsTokenPlain.attachTracker`. Monotone up, then frozen forever.

From (1)+(2)+(3): `maxCoinTail == max{ _coinTail(c) : c has a configured pool }` **invariantly**. A recompute over
the live set therefore returns the current value or higher -- never lower. **A sound recompute cannot deliver the
feature.**

To lower it at all, the path must EXCLUDE a coin whose pools are still permanently tradeable. The hook has no
on-chain predicate separating "dead" from "merely dormant", and a dormant coin can trade in the very next block.
Excluding it means that coin's next trade fails its `_tail()` precheck and silently defers all its in-swap work,
permanently, with no signal -- converting an admin convenience into an unannounced permanent degradation.

There is a second, independent reason: `_coinTail` reads the coin's **self-reported** `syncGasParams()`, and
`configurePool` is launcher-gated rather than token-type-gated. A recompute-based path would move the trust from
"the admin types a number" to "**the coin** reports a number it can lower at will", letting one coin shrink the
global reserve for every other pool. That is strictly worse than the status quo. (`_coinTail` also falls back to
the `SWAP_TAIL_RESERVE` floor when its 30k-gas staticcall fails, so a transient read failure during a recompute
would lower the tail while the coin's real need is unchanged.)

**Decision: accept the ratchet as-is.** If the cost ever needs attacking, the headroom is NOT in `maxCoinTail` --
it is the `SWAP_HOP_GAS * SWAP_HOPS_COVERED` (420,000) multi-hop allowance `_tail()` adds on top, roughly 26% of
the bound. Narrowing that changes the multi-hop safety property (an earlier pool cannot see a later hop's coin),
so it is a design decision, not a tuning exercise.


## Contract size limit on Robinhood Chain — MEASURED, not assumed

**The limit is 98,304 bytes of runtime code — exactly 4x the EIP-170 standard of 24,576.**

`forge build --sizes` will end with `Error: some contracts exceed the runtime size limit (EIP-170: 24,576 bytes)`
and report large negative margins for `RealmAnyPairsV4PairTrackerDeployer`, `RealmAnyPairsTaxHookPairImmutable`,
`RealmAnyPairsV4UnifiedLauncher` and `RealmAnyPairsDividendTrackerAutoBasket`. **That error is Foundry applying
stock EVM rules; it does not know this chain is non-standard.** Foundry does not enforce EIP-170 in tests, so the
suite is silent either way.

How the limit was established (2026-09-16, Robinhood mainnet, chainId 0x1237): `eth_estimateGas` on a contract
creation whose initcode is `PUSH2 <n>; PUSH1 0; RETURN` — i.e. it returns `n` zero bytes as the new contract's
code — binary-searched on `n`. `eth_estimateGas` runs a full state transition and applies the code-size check, so
this measures the chain rather than the client's `eth_call` shortcut. Result: **98,304 accepted, 98,305 rejected
with `max code size exceeded`.** Reproduce it before trusting it if the chain is ever upgraded.

Margins at the audited tree:

| contract | runtime bytes | margin to 98,304 |
|---|---|---|
| `RealmAnyPairsV4PairTrackerDeployer` | 56,293 | +42,011 |
| `RealmAnyPairsTaxHookPairImmutable` | 55,166 | +43,138 |
| `RealmAnyPairsV4UnifiedLauncher` | 40,489 | +57,815 |
| `RealmAnyPairsDividendTrackerAutoBasket` | 37,911 | +60,393 |

**This is chain-specific and it is the single hardest constraint on deploying this stack.** A chain without the
raised limit (Ethereum mainnet, most L2s) CANNOT host the hook, the launcher or the tracker deployer as built.
Porting there is not a configuration change; it is a decomposition of contracts that are 2.2x over the standard
cap. Check this number first on any new chain.


## 0. SETUP — restore the pinned dependency tree FIRST

**A fresh clone does not build.** This repository carries no `lib/` directory; `foundry.toml` only names remapping
paths. Restore the exact dependency tree before anything else:

```bash
bash scripts/install-deps.sh      # idempotent, safe to re-run
rm -rf cache out && forge build   # COLD build, TWICE -- see the warning below
rm -rf cache out && forge build
forge test --threads 1            # expect: 549 tests, 0 failed -- see the measured breakdown below
```

> **THE NUMBERS, MEASURED ON THIS TREE ON 2026-09-16** (`--threads 1` throughout; re-measure, never predict):
>
> | command | suites | tests |
> |---|---|---|
> | `forge test` | 102 | **549 passed, 0 failed** |
> | `forge test --no-match-path "test/{fork,stress}/*"` — the audit loop | 99 | **542 passed, 0 failed** |
> | `forge test --match-path "test/fork/*"` | 2 | 5 |
> | `forge test --match-path "test/stress/*"` | 1 | 2, both no-ops until `FOUNDRY_PROFILE=stress` / `STRESS=1` arms the harness |
>
> This line has been stale before -- it read "476 tests, 0 failed (471 excluding the 5 fork tests)" against a tree
> that produced 529 on the audit loop -- and a reproducibility gate citing an impossible number is worse than no
> gate at all, because the first person to run it learns to ignore the gate rather than the tree. Update it in the
> same change that moves it.

> **THE COLD `forge test` PATH IS PART OF THE GATE, not only the cold build.** On a cold cache, `forge test` with a
> `--no-match-path` filter compiles the tree under Foundry's REDUCED OUTPUT SELECTION, which is a different codegen
> path from the full `forge build` above -- and round 17 found a frame that `via_ir` could allocate on the one and
> not on the other. Adding four test fixtures was enough to tip it: `rm -rf cache out && forge build` then the audit
> loop passed, while `rm -rf cache out && forge build --skip test` then the SAME audit loop failed to compile with
> `Variable ... is 1 too deep in the stack`, reproducibly, naming no file. The cause was `{AB.InputBasket}` -- a
> struct with TWO dynamic members -- being built inline in four `setUp()` bodies alongside the rest of their locals;
> each now builds it in its own frame (`_inputs`), as `test/consistency/TrackerAdapters.sol` does. Both cold paths
> pass as of 2026-09-16.
>
> The lesson for whoever hits this next: a green `forge build` is NOT evidence that `forge test` compiles from cold,
> because the two ask solc for different things. Run **both** cold. And **do not "fix" it by turning off `via_ir` or
> `isolate`** -- both are required (see `foundry.toml`); give the offending frame margin instead, which is what
> rounds 13, 14 and 17 each did.

> **Verify with a COLD build, not `forge test` alone.** Audit round 13 found that this tree compiled or failed
> depending on how Foundry grouped sources into compilation units: the same commit, the same pinned dependencies and
> a byte-identical `foundry.toml` built cleanly in one checkout and failed with
> `Variable ... is 1 too deep in the stack` in another. A warm incremental build masked it, so a green suite was not
> evidence the tree builds. The offending frame was given margin, but the lesson stands -- `rm -rf cache out && forge
> build` in a fresh checkout is the check that means something.
>
> **AUDIT ROUND 14 update: run it TWICE.** Three symptoms have been seen across reviewers on identical trees -- a
> solc-internal `Invalid IR ... Quote is not terminated` at an emitted `/// @src` debug comment, two hangs, and a
> `std::bad_alloc` -- while other cold builds of the same tree succeed. It is flaky under load rather than a
> deterministic break. The `/// @src` variant was addressed at source (every multi-line `if (...)` condition in the
> AutoBasket is now single-line, since the breaking snippets are exactly the multi-line spans), and a real
> stack-depth frame was fixed in round 13. Two consecutive clean cold builds is the bar before a deploy build or a
> block-explorer verification is considered reproducible.

> **AUDIT ROUND 14 — OPERATOR ACTION:** every V4-routed quote needs `setV4FloorRate(quote, rate)` before it will
> convert at all; without one it skips (`SKIP_NO_FLOOR`). **The rate does NOT expire** — that was a deliberate
> decision, to avoid a recurring admin task whose failure mode is a silent halt of fee conversion.
>
> **What that means for you.** The spot term can be collapsed by an attacker, so the admin rate is effectively the
> whole floor. A rate left far BELOW market is exploitable in proportion to how far the price has moved (bounded per
> block by `maxInPerCall`, per conversion by the 2% reimbursement cap, but NOT by time). A rate above market is
> harmless — it just skips.
>
> **So monitor, because nothing on chain will:**
> * alert on `FloorBound(quote, floorOut, adminRate, adminBound)` with `adminBound == true` — that is the admin
>   number pricing the conversion instead of the market, and the cue to re-price;
> * surface `v4Floor(quote)` → `(rate, setAt, setAtBlock, ageSeconds)` on the ops dashboard;
> * **re-price after any large move in the pair**, and note that `setRoute` / `setV4Route` CLEAR the rate, so a route
>   change stops that quote converting until you set it again.

`dependencies.lock` is the authority. Everything is pinned **by commit hash**, not by tag, because a tag can be moved:

| package | commit | version | imports |
|---|---|---|---|
| `Uniswap/v4-core` | `d153b048868a60c2403a3ef5b2301bb247884d46` | 1.0.2 | 381 |
| `OpenZeppelin/openzeppelin-contracts` | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` | 5.7.0 | 69 |
| `OpenZeppelin/uniswap-hooks` | `2ae32be4906d300fc49b4384842ef6bc3e902d73` | 1.2.2 | **1 file** |
| `foundry-rs/forge-std` | tag `v1.16.2` (hash unverified, test-only) | 1.16.2 | 21 |

> **`uniswap-hooks` supplies exactly ONE file** — `src/utils/CurrencySettler.sol`, imported by
> `RealmAnyPairsTaxHookPairImmutable`, `RealmAnyPairsV4PairLpLockerImmutable` and `RealmAnyPairsPlatformFeeConverter`.
> A dependency audit that counts imports per package will flag it as dead weight. **It is not.** Removing it breaks the
> build of the three largest contracts in the tree.

> **`v4-periphery` and `solmate` are gone.** Both had remappings and were imported by nothing. Do not re-add a
> remapping without an import to justify it.

**Why this mechanism and not bare git submodules.** `.gitmodules` records a URL and a branch — it does **not** record
the commit. A submodule's pin lives in the superproject's tree object, so it pins only once the repository is itself a
git repository *and* the submodule commit has been committed. This tree is currently not a git repository at all, so a
`.gitmodules` alone would pin nothing. A `.gitmodules` is checked in for the day it is initialised (with the hashes in
comments); `scripts/install-deps.sh` is what actually pins today, and it keeps working afterwards.

**Changing a dependency is a source change.** Bump the hash in `dependencies.lock`, re-run the script, rebuild, and run
the whole suite. This is not ceremony: audit round 12 found that
`RealmAnyPairsV4PairLauncherImmutable._finishLaunch` (that contract was deleted in round 17) and
`RealmAnyPairsV4UnifiedLauncher._finishLaunch` sat **one stack
slot** inside the via-IR limit, so the tree compiled against one copy of v4-core and failed against another with
`Variable ... is 1 too deep in the stack`. Both frames were fixed by packing their parameters into a `FinishParams`
struct (they now build at `optimizer_runs` 200 through 100,000), but the general lesson stands: a different inlining
decision in a dependency can break this build, and an unpinned tree hides that until deploy day.

---

## 0. What gets deployed

| # | contract | kind | constructor |
|---|---|---|---|
| 1 | `RealmAnyPairsSplitLib` | linked library | — |
| 2 | `RealmAnyPairsV4TokenDeployer` | linked library | — |
| 3 | `RealmAnyPairsV4PairTrackerDeployer` | linked library (also deploys `RealmAnyPairsDividendTrackerAutoBasket`) | — |
| 4 | `RealmAnyPairsInSwapRegistry` | owned, never renounceable | `(address owner_)` |
| 5 | `RealmAnyPairsTaxHookPairImmutable` | CREATE2, address must carry hook flags `0x28CC` | `(IPoolManager pm, address owner_, address platform_)` |
| 6 | `RealmAnyPairsV4PairLpLockerImmutable` | CREATE | `(IPoolManager pm, address owner_)` |

> **AUDIT ROUND 12 — READ BEFORE DEPLOYING.**
> * **Every Realm pool is a ZERO-FEE pool.** `RealmAnyPairsTaxHookPairImmutable.POOL_FEE` is **0** (was 3000) and
>   `_shape` refuses any other fee with `BadPoolFee`. Both launchers' `LP_FEE` is 0 to match. Anything off chain that
>   derives a Realm pool id or builds a Realm `PoolKey` must use `fee = 0`.
> * **The LP locker no longer compounds.** `compound()` and all of its machinery are deleted, so there is no keeper
>   call, no cron and no post-deploy step for it. The locker's runtime size fell from 19,477 to 12,441 bytes.
> * **Locked liquidity now grows only from the tax's LP slice** (the hook's in-swap auto-liquidity step). It does not
>   grow from trading fees, because there are none. Expect no third-party LPs, and note that moving a Realm pool's
>   price is cheaper without a fee toll.
| 7 | `RealmAnyPairsV4UnifiedLauncher` | CREATE | `(IPoolManager pm, hook, address weth_, address router_, address v3Factory_, locker, string base, address owner_)` |
> * **REFERRALS NO LONGER EXIST.** `markReferred`, `referrerOf`, `REFERRAL_BPS` and the referral payout slot are
>   removed from the hook, and the launcher's six `*Ref` entry points (`launchRef`, `launchWithMetaRef`,
>   `launchRewardsRef`, `launchRewardsWithMetaRef`, `launchRewardsBasketRef`, `launchRewardsBasketWithMetaRef`) are
>   gone along with the `referrer` field in every launch param struct. **Do not wire a frontend to any of them.** The
>   platform now receives the whole platform cut; the trader pays exactly what they paid before.

Optional, separate: `RealmAnyPairsPlatformFeeConverter` `(weth, router, v3Factory, hook, admin, treasury, maxGasPrice,
tip, poolManager)` — converts platform fees to ETH; not needed by the launch path.

`src/RealmAnyPairsV4PairLauncherImmutable.sol` **no longer exists** — it was deleted in audit round 17 (it was
never deployed, and as a test harness it had drifted out of guard parity with the unified launcher). If you are
working from an older runbook that told you to skip it, there is now nothing to skip. Deleted in the same round:
`src/RealmAnyPairsDividendTrackerEthBasket.sol`, `src/RealmAnyPairsDividendTrackerMultiBasket.sol` and
`src/RealmAnyPairsDividendTrackerBasket.sol` (no production path constructed any of them), and
`RealmAnyPairsV4PairTrackerDeployer.deployBasketTracker` (its only caller was that harness).
**THREE tracker variants remain:** `RealmAnyPairsDividendTracker` (native), `…Quote` and `…AutoBasket`. **Every
basket launch — pair, native and multi-pair — deploys `…AutoBasket`.**

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

**THREE libraries, not four (audit round 10).** `RealmAnyPairsV4MultiPairTrackerDeployer` has been removed: nothing
called its only function, because a multi-pair launch deploys the auto-basket tracker like every other basket launch.
If you are following an older copy of this file, skip it -- do not deploy it, do not export `MULTITRKDEP`, and do not
pass it to `--libraries`. The launcher no longer checks for it and will revert `DeployerLibraryMissing` only for the
two that remain.

```bash
forge create --rpc-url $RPC --private-key $PK --broadcast src/RealmAnyPairsSplitLib.sol:RealmAnyPairsSplitLib
forge create --rpc-url $RPC --private-key $PK --broadcast src/RealmAnyPairsV4TokenDeployer.sol:RealmAnyPairsV4TokenDeployer
forge create --rpc-url $RPC --private-key $PK --broadcast src/RealmAnyPairsV4PairTrackerDeployer.sol:RealmAnyPairsV4PairTrackerDeployer
export SPLITLIB=<addr> TOKENDEP=<addr> PAIRTRKDEP=<addr>
```

Every later build and `forge create` must link them. Pass them on the command line — **never commit a `libraries` pin to
`foundry.toml`** (it would redirect the test suite to on-chain code):

```bash
export LIBS="--libraries src/RealmAnyPairsSplitLib.sol:RealmAnyPairsSplitLib:$SPLITLIB \
  --libraries src/RealmAnyPairsV4TokenDeployer.sol:RealmAnyPairsV4TokenDeployer:$TOKENDEP \
  --libraries src/RealmAnyPairsV4PairTrackerDeployer.sol:RealmAnyPairsV4PairTrackerDeployer:$PAIRTRKDEP"
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

The hook's address must have low 14 bits `0x28CC` (before-initialize, **before-add-liquidity**, before-swap,
after-swap and both return-delta flags); the launcher reverts `BadHookFlags()` otherwise. An address ending in `28cc`
satisfies it.

> **CHANGED IN AUDIT ROUND 11: `0x20CC` -> `0x28CC`.** `BEFORE_ADD_LIQUIDITY` (`1 << 11`) is now required, because the
> hook refuses third-party liquidity on a guarded pool while its coin's max-wallet window is live (finding H-1). A hook
> mined for the old `0x20CC` will be refused by the launcher. **Mine a new address.**

```bash
ARGS=$(cast abi-encode "c(address,address,address)" $PM $OWNER $PLATFORM)
INIT=$(forge inspect $LIBS src/RealmAnyPairsTaxHookPairImmutable.sol:RealmAnyPairsTaxHookPairImmutable bytecode)${ARGS#0x}
DEPLOYER2=0x4e59b44847b379578588920cA78FbF26c0B4956C   # the standard CREATE2 factory; confirm it has code on chain
cast create2 --deployer $DEPLOYER2 --init-code $INIT --ends-with 28CC
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
