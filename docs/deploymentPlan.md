# Deployment plan

Realm deploys on **Sepolia** (11155111), **Robinhood Chain mainnet** (4663) and **Robinhood Chain testnet** (46630, `*-robinhood-testnet` recipes). Every manifest slot is
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
| 9 | `ConstantProductBondingCurve` | the DEFAULT tier's no-vault base curve |
| 10 | `ConstantProductBondingCurveConfigurable` ×21 | 6 DEFAULT vault curves + (base + 6 vault) × THIN, THICK |
| 11 | `RealmCreatorVault` | clone master |
| 12 | `RealmCreatorVaultFactory` | impl + UUPS proxy |
| 13 | `RealmToken` | clone master |
| 14 | `RealmTaxableTokenUniV2` | clone master; deploys `RealmDividendLogicUniV2` in its constructor |
| 15 | `RealmTaxableTokenUniV4` | clone master; deploys `RealmDividendLogicUniV4` in its constructor |
| 16 | `RealmFactoryUniV2Unified` | impl + UUPS proxy, whitelisted on the launchpad by the script |
| 17 | `RealmAssetsWhitelist` | direct venue's ERC20-quote whitelist, no approvers yet |
| 18 | `RealmDirectGraduatorUniV4` | direct venue's graduator, bound to `SWAP_HOOK` / `SWAP_HOOK_ANY_PAIR` |
| 19 | `RealmFactoryUniV4Direct` | impl + UUPS proxy; no launchpad, so nothing to whitelist |

Not deployed by `DeployRealmStack`: the hook (its own script, above) and the dividend-logic extensions
(self-deployed by the taxable token constructors).

## Sequence

```bash
# 0. Retarget the build to the chain, then phase 0.
just deploy-prereqs-sepolia          # or: just deploy-prereqs-rh

# 1. Paste REALM_KEEPERS_REGISTRY + DIVIDEND_SWAP_REGISTRY into that chain's library in
#    src/config/DeploymentAddresses.sol. They are baked into the taxable token bytecode and clones
#    cannot be repointed, so this MUST happen before phase 1. Paste LP_FEE_ROUTER_IMPL into
#    src/config/manifest.<chain>.sol and upgrade the inherited router proxy onto it (see below).
forge build

# 2. Phase 1 — the whole stack in one broadcast. Refuses to run if step 1 was skipped.
just deploy-stack-sepolia            # or: just deploy-stack-rh

# 3. Paste the printed manifest block into src/config/manifest.<chain>.sol, then:
just export-deployments

# 4. Mirror the new addresses in ../indexer config.yaml + config.dev.yaml + config.prod.yaml.

# 5. Appoint the admin + keeper on both registries (they ship empty). Admin defaults to the
#    broadcasting account; REALM_KEEPER comes from the manifest. Idempotent.
just configure-registries-sepolia     # or: just configure-registries-rh[-testnet]

# 6. Smoke test: create a token through `RealmFactoryUniV2Unified` and `RealmFactoryUniV4Direct`
#    (no dedicated script).
```

Verification on Robinhood uses Blockscout, not Etherscan — the `*-robinhood*` recipes pass
`--verify --verifier blockscout --verifier-url <explorer>/api/` (the `robinhood_verify` /
`robinhood_testnet_verify` justfile variables). To verify a past broadcast after the fact, re-run its
recipe's `forge script` with `--resume` and the same verify flags; it reads `broadcast/` and only verifies.

## The swap hook and the LP fee router

Realm deploys its **own** hook rather than reusing the Livo one. The Livo hook's `TREASURY` and
`FEE_ROUTER` are `immutable` and point at Livo-controlled addresses, so a router outage would send LP
fees to an address Realm does not control, and the router proxy is owned by the retired `livo.dev` key.
Neither is fixable without a new hook — hence the redeploy, which costs a fresh Uniswap whitelisting.

Order matters: `DeployRealmPrereqs` deploys the `SwapLpFeeRouter` proxy first, because the hook takes it
as a constructor immutable. Later router policy changes ship as an `upgradeToAndCall` on that proxy,
whose owner is now the `realm.dev` deployer.

**`RealmHook` is the deployed hook** (`DeployRealmHook` / `just deploy-realm-hook-<chain>`). Two variants
were originally submitted to Uniswap for whitelisting — `RealmSwapHook`, logic-for-logic the previously
whitelisted hook, and `RealmHook`, the same plus a `RealmPoolState(token, poolId, sqrtPriceX96, liquidity)`
log per swap. Uniswap approved `RealmHook`, so `RealmSwapHook` is now deprecated as a deployment target: it
stays in the tree only as `RealmHook`'s base contract, and has no deploy script or recipe of its own.

`RealmPoolState` carries the only two fields the indexer reads from the singleton
`UniswapV4PoolManager.Swap` event (`sqrtPriceX96`, `liquidity`) plus the pool id as a join key, at the
same log position relative to the hook's own events. On a
`RealmHook` pool the indexer can therefore drop that subscription entirely, instead of filtering every
V4 swap on the chain to find the ~0.4% that are Realm's. See §6.0 of `docs/events-per-entry-point.md`.

The hook address must be **mined**: a V4 hook advertises its callbacks in the low 14 bits of its own
address (mask `0xCC` here), so the script brute-forces a CREATE2 salt via `HookMiner.find`. Paste the
mined address into the manifest's `SWAP_HOOK`, then `just export-deployments`.

## Treasury routing

The treasury address the protocol pushes to (`LAUNCHPAD.treasury()`, the LP fee router's `TREASURY`) is
meant to be the `RealmTreasuryRouter` proxy, which forwards 1/3 to `RealmVoting` and the rest to the team
multisig. It cannot go in with the stack: the router bakes the voting proxy in, and voting needs the
REALM token, which is created through the stack. So the order is stack → REALM token → `RealmVoting`
→ the router. Voting burns REALM through `burnFrom`, so on a chain whose token masters predate it,
redeploy them first (`just redeploy-token-impls-<chain>` covers all three masters and rewires the
factories) and only then create the REALM token.

Voting and the router deploy in ONE broadcast: `DeployRealmTreasuryRouter` inherits `DeployRealmVoting`
and runs it first whenever the manifest's `VOTING` is still zero, keeping that address in memory rather
than through a paste-and-rebuild round trip — the router holds it as an immutable. Paste the REALM token
into the manifest's `REALM_TOKEN` first (or prefix `REALM_TOKEN=<address>`).

```bash
just deploy-treasury-router-rh       # or: -sepolia / -rh-testnet; dry-run without --broadcast first
just export-deployments              # after pasting VOTING(+_IMPL), TREASURY_ROUTER(+_IMPL), LP_FEE_ROUTER_IMPL
```

`just deploy-voting-<chain>` stays as a standalone step for the case where the two have to be deployed
apart: the router leg needs the broadcaster to own the launchpad and the LP router proxy, and voting
does not, so a chain whose launchpad already belongs to the multisig deploys voting with `realm.dev`
and the router through the multisig.

Then set `REALM_TREASURY = TREASURY_ROUTER` in that chain's `DeploymentAddresses` library: token impls bake
it as `DIVIDEND_TREASURY`, so impls deployed before this step keep sweeping to the multisig until redeployed.
The hook's fallback treasury is a constructor immutable and stays where it was (`LEGACY_TREASURY` on
Robinhood mainnet), which is why that address is kept on record.

## Upgrades

Every dependency a unified factory holds is a constructor immutable, so changing token impls,
graduators, curves or the vault factory means a new factory implementation:

```bash
# after updating src/config/manifest.<chain>.sol with the new addresses
just upgrade-factories-sepolia       # or: just upgrade-factories-rh
```

When it is the **token masters** that change (the taxable ones bake per-chain constants, see
`script/BuildTarget.sol`; the base one carries the shared ERC20 surface), one recipe deploys all three
fresh masters AND rewires the factories to them, with nothing to paste in between; the five printed
slots go into the manifest afterwards:

```bash
just redeploy-token-impls-sepolia      # or: just redeploy-token-impls-rh-testnet
just export-deployments
```

Tokens already created keep their old master (clones are not upgradeable).

The factory proxy addresses never move, so integrators need no changes.

## Ownership handover

The broadcaster ends up owning the launchpad, both factory proxies and the vault factory proxy. The
treasury owns the two registries (it appoints admins and nothing else).

- **`RealmLaunchpad` -> multisig.** Critical: whitelist/blacklist factories, trading fees, treasury
  address, community takeover.
- **Factory + vault factory proxies -> multisig.** They authorize UUPS upgrades.
- **Graduators, `RealmMasterFeeHandler`** — no owner-only critical functions; leave the deployer.
