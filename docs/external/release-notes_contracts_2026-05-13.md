# Realm Contracts — Release Notes (2026-05-13)

Changes shipped to mainnet on 2026-05-13. This release consolidates the factory
surface into two unified factories, replaces the per-token fee handlers with a
singleton, and ships a new Uniswap V2 taxable-token family.

---

## TL;DR

- **Two factories instead of seven.** Every token variant (base, sniper-protected,
  taxable, taxable + sniper-protected) now ships from a single `RealmFactoryUniV2Unified`
  and a single `RealmFactoryUniV4Unified`. Old factory addresses are retired.
- **One fee handler, not many.** `RealmMasterFeeHandler` is now the single fee router
  for every Realm token (V2 + V4, taxable or not, single or multi-receiver). The old
  `RealmFeeHandler` and the per-token `RealmFeeSplitter` clones are gone.
- **Direct fees.** Up to one fee receiver per token can opt into synchronous ETH
  forwarding instead of pull-based claims.
- **V2 taxable tokens.** Tokens that graduate to a Uniswap V2 pair can now carry
  buy/sell taxes (capped at 5% per side) with intrinsic taxation and auto swap-back.
- **Charity mode.** Tax durations beyond 1 year (up to 120 years) unlocked when a
  single non-deployer fee receiver is configured and ownership is renounced at deploy.

---

## Index

- [1. New features](#1-new-features)
- [2. Configuration changes](#2-configuration-changes)
- [3. Fixes & hardening](#3-fixes--hardening)
- [4. Removed / deprecated](#4-removed--deprecated)
- [5. Mainnet deployment addresses](#5-mainnet-deployment-addresses)
- [6. Integrator migration checklist](#6-integrator-migration-checklist)

---

## 1. New features

### 1.1 Unified factories

`RealmFactoryUniV2Unified` and `RealmFactoryUniV4Unified` replace the previous fleet
(`RealmFactoryUniV2`, `RealmFactoryUniV2SniperProtected`, `RealmFactoryUniV4`,
`RealmFactoryTaxToken`, `RealmFactoryUniV4SniperProtected`,
`RealmFactoryTaxTokenSniperProtected`, `RealmFactoryExtendedTax`).

Each unified factory dispatches between **four** token implementations at create
time based on whether `TaxConfigInit` and/or `AntiSniperConfigs` are configured:

- base → `RealmToken`
- anti-sniper only → `RealmTokenSniperProtected`
- tax only → `RealmTaxableTokenUniV2` / `RealmTaxableTokenUniV4`
- tax + anti-sniper → `RealmTaxableTokenUniV2SniperProtected` /
  `RealmTaxableTokenUniV4SniperProtected`

A new view `previewTokenImplementation(feeReceivers, supplyShares, taxCfg, antiSniperCfg)`
returns the implementation that will be cloned, so the off-chain salt mining step
keeps working unchanged.

See [`docs/external/factory-createToken-integration.md`](./factory-createToken-integration.md)
for the full integrator guide.

### 1.2 `RealmMasterFeeHandler` singleton

A single fee handler now routes ETH for every Realm token:

- **Multi-receiver** per token, configured at deploy via `FeeShare[]` (sum of `shares`
  in bps must equal `10_000`). Up to **32 receivers** per token, of which up to **4**
  may be direct.
- **Direct fees**: any single receiver can opt in by setting
  `directFeesEnabled = true` on their `FeeShare`. Their slice is forwarded on every
  `depositFees` call with a gas-capped `.call` (`100_000` gas). Failed forwards fall
  back to per-account pending claims, so a hostile receiver can never DoS the swap
  or graduation hot paths.
- **Claimable receivers** use an O(1)-per-deposit cumulative-share accumulator —
  per-deposit gas no longer scales with recipient count.
- **Mutable shares**: an admin or the token's current non-zero owner can call
  `setShares(token, feeShares)` to rebalance. Any direct-receiver residue parked in
  pending claims is preserved across updates.
- **Two-tier admin**: `Ownable2Step` owner sets admins; admins can update shares for
  any token.

Per-call event sequence (claim / deposit / rebalance) is documented in
[`docs/events-per-entry-point.md`](../events-per-entry-point.md).

### 1.3 Uniswap V2 taxable tokens

A new taxable-token family for tokens that graduate to a V2 pair:

| Implementation                              | Anti-sniper | Tax cap |
| ------------------------------------------- | ----------- | ------- |
| `RealmTaxableTokenUniV2`                     | no          | 5%      |
| `RealmTaxableTokenUniV2SniperProtected`      | yes         | 5%      |

V2 has no swap callbacks, so taxes are taken **intrinsically**: every pair-touching
transfer in the post-graduation window diverts `amount * bps / 10_000` to the token
contract. The contract auto-swaps the accumulated balance back to ETH on the V2
router and routes it through `RealmMasterFeeHandler.depositFees`:

- Auto-trigger fires on sells when the contract balance crosses `SWAP_THRESHOLD`
  (0.05% of total supply) and caps each back-swap at `2 * SWAP_THRESHOLD` so a
  single trader's price impact stays bounded.
- After the tax window closes, a sub-threshold residual is drained on the next sell
  (one-shot post-window cleanup) so nothing strands forever.
- Owner-triggered `swapBack(swapAmount, amountOutMinWei)` lets the protocol admin
  drain larger residuals via a private mempool with explicit slippage protection.

V2 tax cap is **5% per side** (V4 stays at 4%). The V2 swap-back path needs more
headroom to amortise per-sell router gas, so a slightly higher cap keeps the tax
slice meaningful.

### 1.4 Charity mode (extended tax durations)

Tax `taxDurationSeconds` is now allowed up to **120 years** (was 14 days at the
start of the previous release window), unlocked when the deploy opts into
"charity mode":

- exactly one fee receiver, distinct from the deployer (`msg.sender`)
- token ownership renounced at creation (`tokenOwner == address(0)`)

The default cap remains **365 days** (raised from 180 days during this release).
V2 deploys always satisfy the ownership rule (V2-family tokens are always
ownerless); on V4 the deployer must pass `renounceOwnership_ = true`.

The charity address is **not verified on-chain** — a deployer can pass any
non-deployer address. The on-chain rules only prevent the most trivial abuse;
off-chain UI / curation owns the social trust signal.

### 1.5 V2 graduator: lazy pair deployment + triggerer compensation

`RealmGraduatorUniswapV2` no longer pre-deploys the Uniswap V2 pair at token
creation. The pair address is predicted from `CREATE2` (init code hash baked
into the graduator per chain via `DeploymentAddresses`) and the pair contract is
deployed lazily inside `graduateToken()`. Token-creation gas drops accordingly;
graduation gas goes up by ~one pair deployment.

To offset the extra graduation gas, the graduation triggerer (`tx.origin`) is
compensated:

| Setting                              | Value       |
| ------------------------------------ | ----------- |
| `TRIGGERER_GRADUATION_COMPENSATION`  | 0.005 ETH   |

The compensation was introduced at 0.002 ETH alongside lazy pair deployment and
bumped to 0.005 ETH within this release after measuring real-world graduation
gas.

### 1.6 New events

| Event                                                            | Source                       |
| ---------------------------------------------------------------- | ---------------------------- |
| `CreatorFeesDeposited(token, amount)`                            | `RealmMasterFeeHandler`       |
| `SharesUpdated(token, recipients, sharesBps)`                    | `RealmMasterFeeHandler`       |
| `DirectReceiverRegistered(token, receiver)`                      | `RealmMasterFeeHandler`       |
| `DirectReceiverRemoved(token, receiver)`                         | `RealmMasterFeeHandler`       |
| `RealmTaxableTokenInitialized(buyTaxBps, sellTaxBps, duration)`   | `RealmTaxableToken` (V2 + V4) |
| `CreatorTaxSwapback(tokenAmountIn, ethAmount)`                   | `RealmTaxableTokenUniV2`      |
| `CreatorTaxesAccrued(token, amount)`                             | `LivoSwapHook` (V4)          |

---

## 2. Configuration changes

### 2.1 Tax caps

| Setting                                  | Old     | New      |
| ---------------------------------------- | ------- | -------- |
| Standard `MAX_TAX_DURATION_SECONDS`      | 14 days | 365 days |
| `MAX_CHARITY_TAX_DURATION_SECONDS`       | —       | 120 years |
| `MAX_TAX_BPS` (V2)                       | —       | 500 (5%) |
| `MAX_TAX_BPS` (V4)                       | 400     | 400 (4%) |

### 2.2 Graduator V2

| Setting                              | Old           | New           |
| ------------------------------------ | ------------- | ------------- |
| `TRIGGERER_GRADUATION_COMPENSATION`  | none          | 0.005 ETH     |
| Pair deployment                      | At creation   | At graduation |

`CREATOR_GRADUATION_COMPENSATION` (0.125 ETH) is unchanged.

### 2.3 Fee-handler limits

| Limit                          | Value                                    |
| ------------------------------ | ---------------------------------------- |
| `MAX_FEE_RECEIVERS` per token  | 32                                       |
| `MAX_DIRECT_RECEIVERS` per token | 4 (factory caps to 1 at create time)  |
| `DIRECT_FORWARD_GAS`           | 100_000 per direct receiver per deposit  |

---

## 3. Fixes & hardening

- **V2 auto swap-back skips when the graduator is the seller.** Graduation
  `addLiquidityETH` transfers token from the graduator to the pair with the pair's
  reserves still zero; firing the swap-back there would revert the entire
  graduation tx and could be griefed by pre-funding the contract with
  `>= SWAP_THRESHOLD` tokens.
- **Post-window residual drain on V2 taxable tokens.** Sub-threshold tax balances
  stuck at window expiry now get drained on the next sell instead of stranding,
  since no fresh tax can flow in to push them across the threshold.
- **`RealmMasterFeeHandler` hardened post-review.** Ownable2Step, gas-capped
  forwards, `ReentrancyGuardTransient` shared between `depositFees`, `setShares`,
  and `claim`, and explicit duplicate / direct-receiver caps.
- **Factory rejects inconsistent token configs.** A non-zero `taxDurationSeconds`
  with zero bps (or vice versa) now reverts at the factory layer rather than
  silently deploying a misconfigured token. Same for anti-sniper sentinels.
- **Sniper-protection `factory` slot moved to transient storage.** The
  `factory` address used to exempt the launchpad→factory hop from the per-tx /
  per-wallet caps no longer lives in persistent storage — it's set in the deploy
  tx and auto-clears at end of tx.
- **V2 graduator init code hash centralised in `DeploymentAddresses`.** Per-chain
  value, baked into the graduator at deploy. Eliminates a class of "pair address
  mispredicted" bugs across Sepolia / mainnet.
- **`_inSwap` guard for V2 taxable tokens moved to transient storage.** No SSTORE
  cost on every back-swap.

---

## 4. Removed / deprecated

The following contracts no longer exist on mainnet and their addresses are
removed from `deployments.mainnet.md`:

- `RealmFeeHandler` — replaced by `RealmMasterFeeHandler`.
- `RealmFeeSplitter` (impl + per-token clones) — replaced by per-token configs
  inside `RealmMasterFeeHandler`.
- `RealmFactoryUniV2`, `RealmFactoryUniV2SniperProtected`, `RealmFactoryUniV4`,
  `RealmFactoryTaxToken`, `RealmFactoryUniV4SniperProtected`,
  `RealmFactoryTaxTokenSniperProtected`, `RealmFactoryExtendedTax` — replaced by
  the two unified factories.
- `DeployersWhitelist` — the extended-tax-duration deployer whitelist is gone,
  superseded by charity mode (no whitelist gating; structural rules only).
- `IRealmTaxableTokenUniV4` interface — replaced by the venue-agnostic
  `IRealmTaxableToken` / `IRealmTaxableTokenSniperProtected`.

### ABI / function removals on `IRealmToken`

- `feeReceiver()` view — fee receivers are now sourced from the master fee handler;
  use `getFeeReceivers()` which returns the full `(recipients, sharesBps)` list.
- `setFeeReceiver(address)` — replaced by
  `RealmMasterFeeHandler.setShares(token, FeeShare[])` (admin- or owner-gated).
- `FeeReceiverUpdated` event — replaced by `SharesUpdated`.
- `InitializeParams.feeReceiver` — removed; fee receivers are passed through
  `registerFees(FeeShare[])` instead.

### ABI changes on `IRealmFactory.FeeShare`

The `FeeShare` struct now carries a third field:

```solidity
struct FeeShare {
    address account;
    uint256 shares;            // bps; sum across array must == 10_000
    bool    directFeesEnabled; // at most one entry across the array may set this
}
```

Single-receiver deploys keep working with a one-element array; multi-receiver
deploys no longer need a separate `createTokenWithFeeSplit` entry point (already
gone in the previous release) — the unified `createToken` handles both.

---

## 5. Mainnet deployment addresses

Generated from `deployments.mainnet.sol`. Full list and Sepolia equivalents live in
[`deployments.mainnet.md`](../../deployments.mainnet.md) /
[`deployments.sepolia.md`](../../deployments.sepolia.md).

| Contract                                     | Address                                      |
| -------------------------------------------- | -------------------------------------------- |
| `RealmFactoryUniV2Unified`                    | `0x97BF1fC5Ee72Dd8c9686386ff00c99b6e3b9C00D` |
| `RealmFactoryUniV4Unified`                    | `0xD8Ccee63514E8B0862f9E0fF82223b2DCa943936` |
| `RealmMasterFeeHandler`                       | `0x6F0f4F70a403B9191D6adf2C10750Ab8436345cC` |
| `RealmToken` (impl)                           | `0x79E3a3473ad2d9285A7C87ACfb4A5C871396240d` |
| `RealmTokenSniperProtected` (impl)            | `0xb9f3c1dB897F24385eEE4feD03C5cd732E9dd087` |
| `RealmTaxableTokenUniV4` (impl)               | `0xF232d7D7B552B3B981FE91B13F715B3c1F075A13` |
| `RealmTaxableTokenUniV4SniperProtected` (impl)| `0x9b8541B251a3ABCE6BbC5419baa478Bbc6B11E00` |
| `RealmTaxableTokenUniV2` (impl)               | `0x56c80E0db3ACD50F1C3a51af2a64C63AfbDf50dF` |
| `RealmTaxableTokenUniV2SniperProtected` (impl)| `0x8CF57ab48D49C9D5d7736459cc291aD0C960BEC2` |

`RealmLaunchpad`, `RealmQuoter`, `LivoSwapHook`, `RealmGraduatorUniswapV2`, and
`RealmGraduatorUniswapV4` addresses are unchanged from the previous release.

---

## 6. Integrator migration checklist

- [ ] Repoint factory calls to `RealmFactoryUniV2Unified` /
      `RealmFactoryUniV4Unified` and update the `createToken` signature to include
      `taxCfg` + `antiSniperCfg` (pass zeroed structs to disable).
- [ ] Add the `directFeesEnabled` boolean to every `FeeShare` entry. Leave
      `false` for the old pull-claim behaviour. At most one entry per token may
      set it to `true`.
- [ ] Index the new `RealmMasterFeeHandler` events (`CreatorFeesDeposited`,
      `SharesUpdated`, `DirectReceiverRegistered`, `DirectReceiverRemoved`)
      keyed by `token`. The old per-clone `RealmFeeSplitter` events are gone.
- [ ] Update fee-receiver UIs to read from
      `RealmMasterFeeHandler.getRecipients(token)` /
      `getDirectReceivers(token)` (or `IRealmToken.getFeeReceivers()`, which now
      delegates to the master handler).
- [ ] Drop any code that reads `token.feeReceiver()` or calls
      `token.setFeeReceiver(...)`. Use `RealmMasterFeeHandler.setShares(token,
      FeeShare[])` for rebalances.
- [ ] If exposing a V2 tax-token deploy flow, surface the 5% per-side cap (V4
      stays at 4%) and the auto swap-back behaviour to creators.
- [ ] If exposing extended tax durations, gate the UI on charity mode: single
      non-deployer fee receiver + renounced ownership. V2 deploys satisfy the
      ownership rule for free.
- [ ] Mine salts against the implementation returned by
      `previewTokenImplementation(...)` — the dispatched impl now depends on
      both `taxCfg` and `antiSniperCfg`.
- [ ] V2 graduation triggerers now receive `0.005 ETH` (was `0.002 ETH`) —
      update any "graduation reward" tooltip if it was hardcoding the old amount.
