# Creator-Vault System — Deployment Runbook

How to deploy the creator-vault feature (per-allocation bonding curves + vesting vaults) to a chain
and wire it into the existing unified factories.

> Deploy from the branch that contains the creator-vault code. The `forge script` commands compile and
> deploy **the currently checked-out source**, so make sure the working tree is the code you intend to ship.

## TL;DR

Two on-chain broadcasts, with a manifest edit + `just export-deployments` after each:

1. `DeployCreatorVaultSystem` → deploys the 6 curves, the vault impl, and the vault factory (proxy + impl).
2. Edit `src/config/manifest.<chain>.sol` with the **9** addresses from step 1.
3. `RedeployAllTokensAndUpgradeFactories` → redeploys all 6 token impls + both factory impls (now wired to
   the vault system) and UUPS-upgrades the two factory proxies **in place**.
4. Edit `src/config/manifest.<chain>.sol` with the **8** addresses from step 3.

The factory **proxy** addresses never change, so the launchpad whitelist and all integrators/frontends are
untouched.

## ⚠️ Ordering is load-bearing — do not reorder

The vault addresses live as **compile-time `constant`s** in `manifest.<chain>.sol`, read by
`CreatorVaultScriptConfig.factoryFor()` / `curvesFor()` and baked into the factory **immutables** by step 3.

- The constants are read at **compile time**, so you must **edit the `.sol` and let `forge script`
  recompile** between step 1 and step 3 — there is no on-chain value to "set later".
- There is **no `address(0)` guard** on the vault wiring. If you run step 3 while the manifest still has
  the vault addresses at `address(0)`, the factories get baked with zero curves/factory and **every
  vault-token `createToken` reverts** at `LAUNCHPAD.launchToken` (non-vault tokens still work). The
  failure is loud, but it means redeploying the factories again. Just don't skip step 2.

## Why a full token redeploy (step 3) is required

This PR changed `RealmToken._initializeRealmToken` (the mint split) **and** the `IRealmToken.InitializeParams`
struct (added `vaultAllocation`). Therefore:

- All **6 token implementations** have new bytecode (every variant inherits `_initializeRealmToken`).
- A new factory passes the new `InitializeParams` layout, so it **cannot** call old token impls.
- Both **factory implementations** changed (vault logic + new constructor args).

`RedeployAllTokensAndUpgradeFactories` redeploys exactly these 6 token impls + 2 factory impls together and
upgrades the proxies, which is the only consistent combination.

---

## Step 1 — Deploy the vault system

```bash
# Sepolia ONLY: switch the hardcoded tax-token addresses to Sepolia first.
# (Skip on mainnet — the default import is mainnet, and the scripts assert it.)
just chain-sepolia

forge script DeployCreatorVaultSystem \
  --rpc-url <mainnet|sepolia> --account livo.dev --slow --broadcast --verify
```

- Has **no manifest dependency** — safe to run first.
- Deploys: the 6 `ConstantProductBondingCurveConfigurable` curves (5%→30%, in order), the `RealmCreatorVault`
  implementation, the `RealmCreatorVaultFactory` implementation, and its `ERC1967Proxy`.
- The broadcaster (`livo.dev`) becomes the vault-factory owner.

## Step 2 — Fill the manifest (9 constants)

Edit `src/config/manifest.<chain>.sol` (all currently `address(0)`), copying from step 1's console log:

| Constant | Source row in the log |
| --- | --- |
| `CREATOR_VAULT_IMPL` | `RealmCreatorVault (impl)` |
| `CREATOR_VAULT_FACTORY` | `RealmCreatorVaultFactory (proxy)` |
| `CREATOR_VAULT_FACTORY_IMPL` | `RealmCreatorVaultFactory (impl)` |
| `VAULT_CURVE_5` | `VAULT_CURVE bps 500 …` |
| `VAULT_CURVE_10` | `VAULT_CURVE bps 1000 …` |
| `VAULT_CURVE_15` | `VAULT_CURVE bps 1500 …` |
| `VAULT_CURVE_20` | `VAULT_CURVE bps 2000 …` |
| `VAULT_CURVE_25` | `VAULT_CURVE bps 2500 …` |
| `VAULT_CURVE_30` | `VAULT_CURVE bps 3000 …` |

> Keep the curve order exact: `VAULT_CURVE_5..30` map to `vaultBondingCurves()[0..5]` →
> the factory's `VAULT_CURVE_5..30` immutables → `_resolveBondingCurve(500..3000)`. A wrong order silently
> mis-prices vault tokens.

```bash
just export-deployments   # refresh deployments.<chain>.md
# commit the manifest + .md
```

## Step 3 — Redeploy token impls + upgrade both factories

```bash
# Sepolia ONLY, again (this script also redeploys the tax tokens):
just chain-sepolia

forge script RedeployAllTokensAndUpgradeFactories \
  --rpc-url <mainnet|sepolia> --account livo.dev --slow --broadcast --verify
```

- **Precondition:** step 2 is done and committed (the factory immutables read those constants now).
- **`livo.dev` must own both factory proxies** — the script asserts owner equality and `_authorizeUpgrade`
  reverts otherwise.
- Redeploys 6 token impls + both factory impls (wired to the fresh token impls **and** the vault factory +
  6 curves via `CreatorVaultScriptConfig`), then `upgradeToAndCall(newImpl, "")` on each proxy.
- Proxy addresses are **unchanged** → no launchpad whitelisting or integrator action.

## Step 4 — Fill the manifest (5 constants)

Edit `src/config/manifest.<chain>.sol` from step 3's log:

```
TOKEN_IMPL                                 TAXABLE_TOKEN_V4_IMPL              (V4 tax)
TAXABLE_TOKEN_V2_IMPL                      FACTORY_UNIV2_UNIFIED_IMPL
FACTORY_UNIV4_UNIFIED_IMPL
```

> Update only the `_IMPL` constants. Do **not** touch `FACTORY_UNIV2_UNIFIED` / `FACTORY_UNIV4_UNIFIED`
> (the proxies) — they are unchanged.

```bash
just export-deployments   # then commit
```

---

## Rehearse before broadcasting

Run each step **without `--broadcast`** (and without `--verify`) for a dry simulation against the RPC:

```bash
forge script DeployCreatorVaultSystem --rpc-url <mainnet|sepolia> --account livo.dev
forge script RedeployAllTokensAndUpgradeFactories --rpc-url <mainnet|sepolia> --account livo.dev
```

(The step-3 dry run only succeeds after step 2 is committed, since it reads the populated manifest.)

## Notes / gotchas

- **ABIs:** already regenerated and committed (all 3 `createToken` overloads present) — no `just abis` needed.
- **Vault factory:** permissionless `createVault`; nothing to whitelist.
- **Sepolia tax-token import:** `RealmTaxableTokenUniV2/V4` hardcode `DeploymentAddresses` for gas; `just
  chain-sepolia` flips the import to Sepolia. The redeploy scripts assert the import matches the target
  chain and revert otherwise.
- **Verification:** `--verify` needs the explorer API key configured in `foundry.toml`/env; drop it and verify
  later if needed.
