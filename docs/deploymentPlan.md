# Deployment plan

Realm deploys on **Sepolia** (11155111) and **Robinhood Chain mainnet** (4663). Every manifest slot is
`address(0)` on both except `SWAP_HOOK`, which is inherited from the Livo deployment because Uniswap has
already whitelisted that hook.

## What gets deployed

| # | Contract | Notes |
|---|---|---|
| **Phase 0 — compile-time constants** ||
| 1 | `RealmKeepersRegistry` | plain, owner = treasury -> `DeploymentAddresses.REALM_KEEPERS_REGISTRY` |
| 2 | `RealmDividendSwapRegistry` | impl + UUPS proxy -> `DeploymentAddresses.DIVIDEND_SWAP_REGISTRY` (the PROXY) |
| 3 | `SwapLpFeeRouter` | **implementation only** — upgrade target for the inherited `LP_FEE_ROUTER` proxy |
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

Not deployed: `LivoSwapHook` (inherited), and the dividend-logic extensions (self-deployed by the
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

## The inherited hook and the LP fee router

`LivoSwapHook.FEE_ROUTER` is an **immutable** and Realm reuses the already-whitelisted hook, so the
router address is fixed. Both are inherited from the Livo deployment and recorded in the manifests:

| Chain | `SWAP_HOOK` | `LP_FEE_ROUTER` (proxy) |
|---|---|---|
| Sepolia | `0x681F2EEf3F43CfC6Eea7BFdAa801135E04ff00cC` | `0x0cEC114e1b8712EBd9d67a773381410F0F78985A` |
| Robinhood mainnet | `0xdB1902Bc975992828616b0224D9C5Ff907E9c0Cc` | `0x3175bB69cfeE26FC90ea0A33E45BbDe466053f43` |

Realm's router policy therefore ships as an **upgrade of that proxy**, not a new deployment — which is
why `DeployRealmPrereqs` deploys the `SwapLpFeeRouter` implementation and no proxy. Both proxies are
owned by the old `livo.dev` key (`0xBa489180Ea6EEB25cA65f123a46F3115F388f181`), so that key must sign:

```bash
cast send <LP_FEE_ROUTER> 'upgradeToAndCall(address,bytes)' <SwapLpFeeRouter impl> 0x \
    --rpc-url <chain> --account <old livo.dev>
```

Then set `LP_FEE_ROUTER_IMPL` in the manifest and `just export-deployments`.

⚠️ `LivoSwapHook.TREASURY` is also immutable and cannot be fixed by the upgrade. It is the old Livo
treasury on both chains (Sepolia `0xBa4891…f181`, Robinhood `0x2F56CB…329D`). It is only used on the
**router-failure fallback path**, so as long as the router works no fee reaches it — but a router
outage sends LP fees to an address Realm does not control. Replacing the hook is the only fix, and
that costs the Uniswap whitelisting.

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
