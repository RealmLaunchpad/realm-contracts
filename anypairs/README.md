# Realm AnyPairs — immutable Uniswap V4 launch stack

A self-contained Foundry project, separate from the Realm contracts in the repository root. Coins launch against **any
quote** (native ETH, USDG, tokenized stocks, any ERC-20), with a creator tax, platform fee, dev buy, vesting vaults,
anti-snipe guards, and holder rewards in any token or basket of tokens — converted and sent automatically.

> **Unaudited changes.** This stack derives from an audited codebase, but rounds 105–108 (platform fee inside the
> trade, creator rate changes, reward routes, auto-converting rewards, fee-converter V4 TWAP) are new and unaudited.
> **Nothing is deployed.**

## Layout

| path | what |
|---|---|
| `src/` | the stack: `RealmAnyPairsV4UnifiedLauncher`, `RealmAnyPairsTaxHookPairImmutable`, `RealmAnyPairsV4PairLpLockerImmutable`, `RealmAnyPairsInSwapRegistry`, four linked libraries, and the per-launch tokens, trackers and vaults |
| `test/` | unit, hook end-to-end, and `test/fork/` Robinhood Chain mainnet fork tests |
| `docs/DEPLOY_UNIFIED.md` | deploy runbook: order, constructor arguments, wiring, smoke test, renounce |
| `docs/INTEGRATION_CHECKLIST.md` | ABI and behaviour for the frontend and indexer |
| `artifacts/TestPoolManager.json` | prebuilt V4 PoolManager used by the tests |
| `lib/` | pinned submodules (below) |

## Build and test

```bash
cd anypairs
git submodule update --init lib/forge-std lib/openzeppelin-contracts lib/v4-core lib/uniswap-hooks
forge build
forge test --no-match-path "test/fork/*"
FORK_RPC_URL=$ROBINHOOD_RPC_URL forge test --match-path "test/fork/*" -vv
```

The public Robinhood RPC rejects Foundry's user agent; use a private RPC for fork tests.

## Pinned libraries

| submodule | commit | version |
|---|---|---|
| `lib/forge-std` | `8bbcf6e` | v1.10.0 |
| `lib/openzeppelin-contracts` | `cab1993` | v5.7.0 |
| `lib/v4-core` | `d153b04` | 1.0.2 (the root project's `lib/v4-core` is the older v4.0.0 layout and does not compile this stack) |
| `lib/uniswap-hooks` | `2ae32be` | 1.2.2 |
