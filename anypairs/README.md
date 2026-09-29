# Realm AnyPairs — immutable Uniswap V4 launch stack

A self-contained Foundry project, separate from the Realm contracts in the repository root. Coins launch against **any
quote** (native ETH, USDG, tokenized stocks, any ERC-20), with a creator tax, platform fee, dev buy, vesting vaults,
anti-snipe guards, and holder rewards in any token or basket of tokens — converted and sent automatically.

> **Twenty rounds of adversarial review; rounds 19 and 20 were clean on both auditors.** Nothing is deployed.
> Every finding through round 20 is fixed and carries a regression test. Two consecutive clean rounds was the exit
> condition; this tree met it. That is not the same as a third-party audit — it is adversarial self-review.

**Source only.** The test suite (565 tests) stays in the development tree, including one regression suite per audit
finding. `foundry.toml` ships byte-identical to that tree so the build configuration cannot drift.

## Layout

| path | what |
|---|---|
| `src/` | the stack: `RealmAnyPairsV4UnifiedLauncher`, `RealmAnyPairsTaxHookPairImmutable`, `RealmAnyPairsV4PairLpLockerImmutable`, `RealmAnyPairsInSwapRegistry`, the linked libraries, and the per-launch tokens, trackers and vaults |
| `docs/DEPLOY_UNIFIED.md` | deploy runbook: order, constructor arguments, wiring, smoke test, renounce — **and the measured chain size limit** |
| `docs/INTEGRATION_CHECKLIST.md` | ABI and behaviour for the frontend and indexer |
| `dependencies.lock` | the authoritative dependency pins, by commit hash |
| `scripts/install-deps.sh` | materialises `lib/` from `dependencies.lock` |
| `lib/` | pinned submodules (below) |

## Three reward tracker variants

`RealmAnyPairsDividendTracker` (native), `…Quote`, `…AutoBasket`. There were six; `…Basket`, `…EthBasket` and
`…MultiBasket` were deleted because nothing in production ever deployed them. Most audit findings in rounds 8–16 were
drift between those near-identical copies — a rule applied to some variants and silently omitted in others. The
development tree now enforces shared rules across every surviving variant with a consistency suite that fails when a
variant is omitted.

## Build

```bash
cd anypairs
git submodule update --init lib/v4-core lib/openzeppelin-contracts lib/uniswap-hooks lib/forge-std
forge build --threads 1
```

`bash scripts/install-deps.sh` is the alternative: it reads `dependencies.lock` and clones each dependency at its
pinned commit. Either produces the same tree.

**`via_ir` is a requirement, not a preference.** Several frames exceed the EVM's sixteen reachable stack slots, so the
legacy code generator cannot compile this stack at all — it fails with a genuine `Stack too deep`. A cold `src/` build
is about 40 seconds.

**Use `--threads 1`.** Parallel compilation of this tree has produced `std::bad_alloc` and *spurious* stack-too-deep
under memory pressure. Both clear on retry and neither is a source defect.

**A warm build is not evidence the tree builds.** solc 0.8.30 groups compilation units unstably under via-IR, and
these contracts sit close enough to the stack limit that a cached build can pass where a cold one fails. Verify with
`rm -rf cache out && forge build --skip test --threads 1` **twice**, in a fresh checkout.

**No `libraries = [...]` pin is committed.** The linker bakes library addresses into every dependent's bytecode. Pin
the deployed library addresses in the deploy build only — see `docs/DEPLOY_UNIFIED.md`.

## Contract size — read this before deploying anywhere new

`forge build --sizes` **will report an EIP-170 error**. That is Foundry applying stock EVM rules; it does not know the
target chain is non-standard. **Robinhood Chain's limit is 98,304 bytes — exactly 4x the EIP-170 standard of 24,576** —
measured 2026-09-16 by binary search with `eth_estimateGas` (98,304 accepted, 98,305 rejected `max code size
exceeded`). Every contract has over 42,000 bytes of margin.

**This is the hardest constraint on deploying this stack.** A chain without the raised limit — Ethereum mainnet, most
L2s — **cannot host** the hook, the launcher or the tracker deployer as built. Porting is not a configuration change;
it is a decomposition of contracts that are 2.2x over the standard cap. Check this number first on any new chain.

## Pinned libraries

| submodule | commit | version |
|---|---|---|
| `lib/v4-core` | `d153b04` | 1.0.2 (the root project's `lib/v4-core` is the older v4.0.0 layout and does not compile this stack) |
| `lib/openzeppelin-contracts` | `cab1993` | v5.7.0 |
| `lib/uniswap-hooks` | `2ae32be` | 1.2.2 — **one** file is imported (`src/utils/CurrencySettler.sol`); do not remove it as unused |
| `lib/forge-std` | `bf647bd` | v1.16.2, referenced by the remappings; test-only |

A dependency bump is a source change: the launcher frames sit close enough to the via-IR stack limit that a different
inlining decision in v4-core has broken the build before. Re-run the full suite after any change here.

## Design decisions that look like bugs and are not

Reviewers keep re-reporting these. They are deliberate:

- **Any token can be a reward or a quote.** That is the product — "any pairs, any rewards". A creator choosing an
  illiquid or malicious reward token is user risk, surfaced in the frontend, not a contract defect.
- **Conversions price at spot and can be sandwiched beyond the slippage band.** Accepted; the slippage setting is the
  mitigation.
- **Reward routes are set by the creator at launch and afterwards only by admin.** Automatic route discovery was
  removed: it cannot be made sound without an out-of-block price source, and same-transaction manipulation broke three
  successive designs.
- **The pool fee is 0%,** so there are no LP trading fees and no fee compounding.
- **V4 floor rates never expire.** The `FloorBound` event is the intended monitoring signal in place of an expiry.
- **Passing *more* gas can cause a revert** in multi-coin batches ("gas bands"). Known and accepted.
- **There are no keepers or bots anywhere** in this system, by design.
- **`maxCoinTail` only ratchets up.** A lowering path was specified and proven unbuildable — the value is already
  exactly the maximum over every live coin's requirement, so any lowering would have to exclude a still-tradeable coin.
  Bounded, liveness-only, never a loss. The full proof is in `docs/DEPLOY_UNIFIED.md`.
- **`withdrawQuoteRefund` is creator-only.** A permissionless push of another party's refund was removed by decision
  after every griefing variant found in review started from "a stranger can fire it".
