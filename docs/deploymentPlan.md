# Deployment plan

Realm deploys on **Sepolia** (11155111) and **Robinhood Chain mainnet** (4663). Every manifest slot is
`address(0)` on both — Realm now deploys its own swap hook and LP fee router too, so nothing is inherited
from the Livo deployment.

## What gets deployed

| # | Contract | Notes |
|---|---|---|
| **Phase 0 — compile-time constants** ||
| 1 | `RealmKeepersRegistry` | plain, owner = treasury -> `DeploymentAddresses.REALM_KEEPERS_REGISTRY` |
| 2 | `RealmDividendSwapRegistry` | impl + UUPS proxy -> `DeploymentAddresses.DIVIDEND_SWAP_REGISTRY` (the PROXY) |
| 3 | `SwapLpFeeRouter` | impl + UUPS proxy -> `LP_FEE_ROUTER_IMPL` / `LP_FEE_ROUTER`. Must precede the hook, which holds the proxy as an immutable |
| **Phase 1 — the stack** ||
| 4 | `RealmMasterFeeHandler` | |
| 5 | `RealmLaunchpad` | owner = broadcaster, treasury from `DeploymentAddresses` |
| 6 | `RealmQuoter` | |
| 7 | `RealmUniV4LiquidityAdder` | chain-shared singleton |
| 8 | `RealmGraduatorUniswapV2` | |
| 9 | `RealmGraduatorUniswapV4` ×3 | DEFAULT / THIN / THICK, all pointed at `SWAP_HOOK` |
| 10 | `ConstantProductBondingCurve` | the DEFAULT tier's no-vault base curve |
| 11 | `ConstantProductBondingCurveConfigurable` ×21 | 6 DEFAULT vault curves + (base + 6 vault) × THIN, THICK |
| 12 | `RealmCreatorVault` | clone master |
| 13 | `RealmCreatorVaultFactory` | impl + UUPS proxy |
| 14 | `RealmToken` | clone master |
| 15 | `RealmTaxableTokenUniV2` | clone master; deploys `RealmDividendLogicUniV2` in its constructor |
| 16 | `RealmTaxableTokenUniV4` | clone master; deploys `RealmDividendLogicUniV4` in its constructor |
| 17 | `RealmFactoryUniV2Unified` | impl + UUPS proxy, whitelisted on the launchpad by the script |
| 18 | `RealmFactoryUniV4Unified` | impl + UUPS proxy, whitelisted on the launchpad by the script |

Not deployed: `RealmSwapHook` (inherited), and the dividend-logic extensions (self-deployed by the
taxable token constructors).

## Sequence

```bash
# 0. Retarget the build to the chain, then phase 0.
just deploy-prereqs-sepolia          # or: just deploy-prereqs-robinhood

# 1. Paste REALM_KEEPERS_REGISTRY + DIVIDEND_SWAP_REGISTRY into that chain's library in
#    src/config/DeploymentAddresses.sol. They are baked into the taxable token bytecode and clones
#    cannot be repointed, so this MUST happen before phase 1. Paste LP_FEE_ROUTER_IMPL into
#    src/config/manifest.<chain>.sol and upgrade the inherited router proxy onto it (see below).
forge build

# 2. Phase 1 — the whole stack in one broadcast. Refuses to run if step 1 was skipped.
just deploy-stack-sepolia            # or: just deploy-stack-robinhood

# 3. Paste the printed manifest block into src/config/manifest.<chain>.sol, then:
just export-deployments

# 4. Mirror the new addresses in ../indexer config.yaml + config.dev.yaml + config.prod.yaml.

# 5. Appoint operational admins/keepers from the treasury account:
cast send <KEEPERS_REGISTRY> 'setAdmin(address,bool)' <admin> true --account realm.admin
cast send <DIVIDEND_SWAP_REGISTRY> 'setAdmin(address,bool)' <admin> true --account realm.admin

# 6. Smoke test: create a token through the V4 factory.
FACTORY_ADDRESS=<factoryV4 proxy> forge script CreateV4Token --rpc-url sepolia --account realm.dev --slow --broadcast
```

Verification on Robinhood uses Blockscout, not Etherscan — the `*-robinhood` recipes do not pass
`--verify`; verify from the CLI with `--verifier blockscout --verifier-url <explorer>/api/`.

## The swap hook and the LP fee router

Realm deploys its **own** hook rather than reusing the Livo one. The Livo hook's `TREASURY` and
`FEE_ROUTER` are `immutable` and point at Livo-controlled addresses, so a router outage would send LP
fees to an address Realm does not control, and the router proxy is owned by the retired `livo.dev` key.
Neither is fixable without a new hook — hence the redeploy, which costs a fresh Uniswap whitelisting.

Order matters: `DeployRealmPrereqs` deploys the `SwapLpFeeRouter` proxy first, because the hook takes it
as a constructor immutable. Later router policy changes ship as an `upgradeToAndCall` on that proxy,
whose owner is now the `realm.dev` deployer.

**Two hook variants are deployed, and both are submitted to Uniswap for whitelisting:**

| Contract | Script / recipe | Difference |
|---|---|---|
| `RealmSwapHook` | `DeployRealmSwapHook` / `just deploy-swap-hook-<chain>` | Logic-for-logic the already-whitelisted hook — the conservative candidate |
| `RealmHook` | `DeployRealmHook` / `just deploy-realm-hook-<chain>` | Same, plus a `RealmPoolState(token, sqrtPriceX96, liquidity)` log per swap |

`RealmPoolState` carries the only two fields the indexer reads from the singleton
`UniswapV4PoolManager.Swap` event, at the same log position relative to the hook's own events. On a
`RealmHook` pool the indexer can therefore drop that subscription entirely, instead of filtering every
V4 swap on the chain to find the ~0.4% that are Realm's. See §6.0 of `docs/events-per-entry-point.md`.

Both hook addresses must be **mined**: a V4 hook advertises its callbacks in the low 14 bits of its own
address (mask `0xCC` here), so the scripts brute-force a CREATE2 salt via `HookMiner.find`. Paste
whichever variant Uniswap approves into the manifest's `SWAP_HOOK`, then `just export-deployments`.

## Upgrades

Every dependency a unified factory holds is a constructor immutable, so changing token impls,
graduators, curves or the vault factory means a new factory implementation:

```bash
# after updating src/config/manifest.<chain>.sol with the new addresses
just upgrade-factories-sepolia       # or: just upgrade-factories-robinhood
```

The factory proxy addresses never move, so integrators need no changes.

## Ownership handover

The broadcaster ends up owning the launchpad, both factory proxies and the vault factory proxy. The
treasury owns the two registries (it appoints admins and nothing else).

- **`RealmLaunchpad` -> multisig.** Critical: whitelist/blacklist factories, trading fees, treasury
  address, community takeover.
- **Factory + vault factory proxies -> multisig.** They authorize UUPS upgrades.
- **Graduators, `RealmMasterFeeHandler`** — no owner-only critical functions; leave the deployer.
