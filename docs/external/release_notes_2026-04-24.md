# Realm Release Notes — 2026-04-29

Integrator-facing changes shipping in this release. Two themes:

1. A unified `createToken` ABI across every factory variant, plus a new sniper-protected family.
2. A new `RealmQuoter` contract that replaces direct `RealmLaunchpad.quote*` calls as the recommended quoting path for the frontend.

---

## Index

### Part A — Create Token

- [1. Factories](#1-factories)
- [2. Unified `createToken`](#2-unified-createtoken)
- [3. Other ABI changes](#3-other-abi-changes)
- [4. Events](#4-events)
- [5. Migration checklist for integrators](#5-migration-checklist-for-integrators)

### Part B — Buy / Sell Quoting

- [6. Sniper protection — what changes for quoting](#6-sniper-protection--what-changes-for-quoting)
- [7. `RealmQuoter`](#7-realmquoter)
- [8. Migration checklist](#8-migration-checklist)

---

# Part A — Create Token

Summary of breaking changes for any integrator that calls a Realm factory or indexes its events.
This branch unifies `createToken` across every factory variant, adds a sniper-protection family,
and changes the deployer-buy / fee-split UX.

---

## 1. Factories

### Renamed

| Old                | New                  |
| ------------------ | -------------------- |
| `RealmFactoryBase`  | `RealmFactoryUniV4`   |

### New factories

| Factory                              | Token deployed                          | Notes                                                                  |
| ------------------------------------ | --------------------------------------- | ---------------------------------------------------------------------- |
| `RealmFactoryUniV2SniperProtected`    | `RealmTokenSniperProtected`              | V2 graduator, ownership renounced at creation                          |
| `RealmFactoryUniV4SniperProtected`    | `RealmTokenSniperProtected`              | V4 graduator                                                           |
| `RealmFactoryTaxTokenSniperProtected` | `RealmTaxableTokenUniV4SniperProtected`  | V4 graduator + buy/sell taxes + sniper caps                            |

`RealmFactoryUniV4`, `RealmFactoryTaxToken`, `RealmFactoryExtendedTax` and `RealmFactoryUniV2` keep
their names but their `createToken` signatures changed (see §2).

---

## 2. Unified `createToken`

The previous two-entry-point split (`createToken` + `createTokenWithFeeSplit`) is **gone**. Each
factory now exposes a single `createToken` that handles:

- 1 fee receiver → no splitter is deployed (`FEE_HANDLER` is the routing target).
- ≥ 2 fee receivers → a `RealmFeeSplitter` clone is deployed and used as both `feeHandler` and
  `feeReceiver` on the token.
- `msg.value > 0` → the factory buys supply on the bonding curve and distributes it across the
  `supplyShares` recipients in the same tx (formerly "deployer buy").
- `msg.value == 0` → `supplyShares` MUST be empty; otherwise the call reverts with
  `InvalidSupplyShares`.

### Common arguments

```solidity
struct FeeShare    { address account; uint256 shares; } // shares in bps; sum must == 10_000
struct SupplyShare { address account; uint256 shares; } // shares in bps; sum must == 10_000

struct TaxConfigInit {       // tax variants only
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint32 taxDurationSeconds;
}

struct AntiSniperConfigs {   // sniper-protected variants only
    uint16   maxBuyPerTxBps;          // 10..300 (0.1%..3%)
    uint16   maxWalletBps;            // 10..300 (0.1%..3%) and >= maxBuyPerTxBps
    uint40   protectionWindowSeconds; // 60..86_400 (1m..24h)
    address[] whitelist;              // bypass the caps during the window
}
```

### Per-factory signatures

```solidity
// RealmFactoryUniV2 (ownership renounced — no `renounceOwnership` flag)
createToken(
    string name, string symbol, bytes32 salt,
    FeeShare[] feeReceivers, SupplyShare[] supplyShares
) payable returns (address token, address feeSplitter)

// RealmFactoryUniV4
createToken(
    string name, string symbol, bytes32 salt,
    FeeShare[] feeReceivers, SupplyShare[] supplyShares,
    bool renounceOwnership
) payable returns (address token, address feeSplitter)

// RealmFactoryTaxToken / RealmFactoryExtendedTax
createToken(
    string name, string symbol, bytes32 salt,
    FeeShare[] feeReceivers, SupplyShare[] supplyShares,
    bool renounceOwnership,
    TaxConfigInit taxCfg
) payable returns (address token, address feeSplitter)

// RealmFactoryUniV2SniperProtected (no `renounceOwnership` flag)
createToken(
    string name, string symbol, bytes32 salt,
    FeeShare[] feeReceivers, SupplyShare[] supplyShares,
    AntiSniperConfigs antiSniperCfg
) payable returns (address token, address feeSplitter)

// RealmFactoryUniV4SniperProtected
createToken(
    string name, string symbol, bytes32 salt,
    FeeShare[] feeReceivers, SupplyShare[] supplyShares,
    bool renounceOwnership,
    AntiSniperConfigs antiSniperCfg
) payable returns (address token, address feeSplitter)

// RealmFactoryTaxTokenSniperProtected
createToken(
    string name, string symbol, bytes32 salt,
    FeeShare[] feeReceivers, SupplyShare[] supplyShares,
    bool renounceOwnership,
    TaxConfigInit taxCfg,
    AntiSniperConfigs antiSniperCfg
) payable returns (address token, address feeSplitter)
```

`feeSplitter` is `address(0)` when `feeReceivers.length == 1`.

`renounceOwnership = true` sets `tokenOwner = address(0)` at deploy; `false` sets it to
`msg.sender`. The V2 factories always renounce.

`RealmFactoryExtendedTax.createToken` is `onlyOwner`.

---

## 3. Other ABI changes

### Factories — `IRealmFactory`

| Old                           | New                                                |
| ----------------------------- | -------------------------------------------------- |
| `quoteDeployerBuy(...)`       | `quoteBuyOnDeploy(...)` — same signature/semantics |
| `error InvalidDeployerBuy()`  | `error InvalidBuyOnDeploy()`                       |
| —                             | `error InvalidSupplyShares()`                      |
| —                             | `error InvalidShares()`                            |
| `setMaxDeployerBuyBps(...)`   | `setMaxBuyOnDeployBps(...)`                        |
| `maxDeployerBuyBps()`         | `maxBuyOnDeployBps()`                              |

---

## 4. Events

### Renamed / re-shaped

| Old (on `main`)                                                              | New                                                                                                  |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `DeployerBuy(token, buyer, ethSpent, tokensBought)`                          | `BuyOnDeploy(token, buyer, ethSpent, tokensBought, address[] recipients, uint256[] amounts)` — adds the per-recipient breakdown of the buy-on-deploy distribution |

### New

```solidity
// SniperProtection — emitted from the sniper-protected token's initializer
event SniperProtectionInitialized(
    uint16 maxBuyPerTxBps,
    uint16 maxWalletBps,
    uint40 protectionWindowSeconds,
    address[] whitelist
);
```

### Unchanged

`TokenCreated`, `FeeSplitterCreated`, `TokenImplementationUpdated`, and every event emitted
inside `RealmToken` / `RealmTaxableTokenUniV4` / launchpad / graduators / fee handler / fee
splitter keep their previous signatures.

### Event ordering (sniper-protected variants)

Identical to the corresponding non-protected factory, with **one extra event**
`SniperProtectionInitialized` inserted from the token initializer (after the `1e27` mint, before
OpenZeppelin's `Initialized`). For tax sniper-protected, it fires after
`RealmTaxableTokenInitialized`. See `docs/events-per-entry-point.md` §14 for the exact sequence.

---

## 5. Migration checklist for integrators

- [ ] Update factory addresses (see `deployments.sepolia.md` / `deployments.mainnet.md`).
- [ ] Replace any `createTokenWithFeeSplit` calls with `createToken` using a `FeeShare[]` of
      length ≥ 2.
- [ ] Wrap single-receiver calls with `[FeeShare({account, shares: 10_000})]`.
- [ ] If you were doing a deployer buy, build a `SupplyShare[]` (cap aggregated by
      `maxBuyOnDeployBps`, default 10%) — empty array when `msg.value == 0`.
- [ ] Pass `renounceOwnership` explicitly (false to keep the deployer as `tokenOwner`).
- [ ] Repack tax args into `TaxConfigInit`.
- [ ] Index `BuyOnDeploy` (not `DeployerBuy`) events
- [ ] If using sniper-protected factories, index `SniperProtectionInitialized` and call
      `maxTokenPurchase(buyer)` — or the new `RealmQuoter` — when surfacing buy limits.

---

# Part B — Buy / Sell Quoting

A new `RealmQuoter` contract replaces the previous "call `RealmLaunchpad.quote*` directly" flow as
the recommended quoting path for the frontend. It exists because sniper-protected tokens add a
**per-buyer** cap (per-tx + per-wallet) that the launchpad's own `quote*` functions don't know
about, and because the bonding curve is not symmetrically invertible — feeding
`maxTokenPurchase(buyer)` straight back into `quoteBuyExactTokens` reverts.

---

## 6. Sniper protection — what changes for quoting

For tokens deployed via `RealmFactory*SniperProtected`, during the protection window
(`launchTimestamp + protectionWindowSeconds`):

- Each non-whitelisted buyer can receive at most `maxBuyPerTxBps × 1e27 / 10_000` tokens per tx.
- Their wallet balance after the buy must stay below `maxWalletBps × 1e27 / 10_000`.
- The cap is **buyer-aware**: the same `quoteBuyExactTokens` call yields different ceilings for
  different buyers depending on their current balance.
- `RealmLaunchpad.buyTokensWithExactEth` reverts with `MaxBuyPerTxExceeded` /
  `MaxWalletExceeded` if either cap is breached.

Token-side primitive (already exposed on every token via `IRealmToken`):

```solidity
function maxTokenPurchase(address buyer) external view returns (uint256);
```

Returns the largest token amount `buyer` may receive from the launchpad right now.
`type(uint256).max` when no cap applies (non-protected, graduated, window expired, or
whitelisted).

⚠️ **Do not feed this value directly into `RealmLaunchpad.quoteBuyExactTokens` followed by
`buyTokensWithExactEth`.** The bonding curve uses ceiling rounding so
`forward(inverse(T)) > T` by 1–2 wei, which still trips the cap. Use `RealmQuoter` (next section)
which handles this with a 1–3 iteration decrement loop.

---

## 7. `RealmQuoter`

A stateless, view-only contract bound to a single launchpad. It composes:

- `RealmLaunchpad.getMaxEthToSpend(token)` — graduation excess cap.
- `RealmLaunchpad.quoteBuy* / quoteSell*` — bonding-curve math.
- `IRealmToken.maxTokenPurchase(buyer)` — per-buyer sniper cap (gracefully handles tokens that
  don't expose it; legacy tokens are treated as "no cap").

### Non-revert guarantee

Every `RealmQuoter` function **returns** rather than reverts. When the returned `reason` is
`INVALID_TOKEN` or `GRADUATED`, all numeric fields are zero. For all other reasons, broadcasting
the corresponding launchpad call with the returned amount is guaranteed not to revert with any
cap-related error. Slippage / deadline / `msg.value` mismatch reverts remain the caller's
responsibility.

### `LimitReason` enum

| Value (uint8) | Name                  | Meaning                                                                                |
| -------------:| --------------------- | -------------------------------------------------------------------------------------- |
| 0             | `NONE`                | No cap was binding; the request was honored as-is.                                     |
| 1             | `INVALID_TOKEN`       | Token not registered with this launchpad. Numeric fields are 0.                        |
| 2             | `GRADUATED`           | Token already graduated; pre-graduation entry points are locked. Numeric fields are 0. |
| 3             | `GRADUATION_EXCESS`   | Curve-side cap (`maxEthReserves - ethCollected`) was the binding cap.                  |
| 4             | `SNIPER_CAP`          | Per-buyer anti-sniper cap was the binding cap.                                         |
| 5             | `NOT_ENOUGH_SUPPLY`   | Launchpad's remaining token balance was the binding cap.                               |
| 6             | `INSUFFICIENT_RESERVES` | Launchpad's ETH reserves can't service the requested sell.                          |

### Functions

```solidity
struct BuyExactEthQuote {
    uint256 ethSpent;        // <= input ethValue; pass as msg.value to buyTokensWithExactEth
    uint256 ethFee;
    uint256 tokensToReceive;
    LimitReason reason;
}

function quoteBuyTokensWithExactEth(address token, address buyer, uint256 ethValue)
    external view returns (BuyExactEthQuote memory q);

struct BuyExactTokensQuote {
    uint256 tokensReceived;  // <= input tokenAmount
    uint256 ethFee;
    uint256 ethForReserves;
    uint256 totalEthNeeded;  // pass as msg.value
    LimitReason reason;
}

function quoteBuyExactTokens(address token, address buyer, uint256 tokenAmount)
    external view returns (BuyExactTokensQuote memory q);

struct SellExactTokensQuote {
    uint256 tokensSold;            // <= input tokenAmount; pass to sellExactTokens
    uint256 ethPulledFromReserves;
    uint256 ethFee;
    uint256 ethForSeller;
    LimitReason reason;
}

function quoteSellExactTokens(address token, uint256 tokenAmount)
    external view returns (SellExactTokensQuote memory q);

struct SellForExactEthQuote {
    uint256 ethReceived;
    uint256 ethFee;
    uint256 ethPulledFromReserves;
    uint256 tokensRequired;        // pass to sellExactTokens
    LimitReason reason;
}

function quoteSellTokensForExactEth(address token, uint256 ethAmount)
    external view returns (SellForExactEthQuote memory q);

function getMaxEthToSpend(address token, address buyer)
    external view returns (uint256 maxEth, LimitReason reason);
```

Sells are not subject to the sniper cap (the cap fires only on launchpad → buyer transfers), so
`quoteSell*` only ever returns `NONE`, `INVALID_TOKEN`, `GRADUATED`, or `INSUFFICIENT_RESERVES`.

### Mapping each quote → launchpad call

| Quoter call                         | Field to use as input                   | Launchpad call to broadcast                                                |
| ----------------------------------- | --------------------------------------- | -------------------------------------------------------------------------- |
| `quoteBuyTokensWithExactEth`        | `q.ethSpent` → `msg.value`              | `buyTokensWithExactEth(token, 0, deadline)`                                |
| `quoteBuyExactTokens`               | `q.totalEthNeeded` → `msg.value`        | `buyTokensWithExactEth(token, 0, deadline)`                                |
| `quoteSellExactTokens`              | `q.tokensSold` → `tokenAmount`          | `sellExactTokens(token, q.tokensSold, 0, deadline)`                        |
| `quoteSellTokensForExactEth`        | `q.tokensRequired` → `tokenAmount`      | `sellExactTokens(token, q.tokensRequired, 0, deadline)`                    |

The `buyer` argument passed to the buy quotes **must** equal the `msg.sender` of the eventual
launchpad call; otherwise the sniper cap is computed against the wrong wallet.

### Recommended UX branching

| `reason`                | Frontend action                                                                                                 |
| ----------------------- | --------------------------------------------------------------------------------------------------------------- |
| `NONE`                  | Render trade as-is, no warning.                                                                                 |
| `INVALID_TOKEN`         | Disable form; surface "token not registered with this launchpad".                                               |
| `GRADUATED`             | Redirect to the post-graduation venue (V2 pair / V4 pool through Universal Router).                             |
| `GRADUATION_EXCESS`     | Show "you're about to top off the curve and trigger graduation"; the returned amount is the exact ceiling.      |
| `SNIPER_CAP`            | Show the buyer the remaining window (`launchTimestamp + protectionWindowSeconds - block.timestamp`) and the cap.|
| `NOT_ENOUGH_SUPPLY`     | "Only X tokens left on the bonding curve"; output is clamped to available supply.                               |
| `INSUFFICIENT_RESERVES` | Sell input has been clamped to what the launchpad can pay out right now.                                        |

---

## 8. Migration checklist

- [ ] Replace direct calls to `RealmLaunchpad.quoteBuy*` with `RealmQuoter.quoteBuy*` and pass the
      eventual `msg.sender` as `buyer`.
- [ ] Branch on `reason` for UX; treat any non-`NONE` value as a clamp (or a hard refuse for
      `INVALID_TOKEN` / `GRADUATED`).
- [ ] Use `q.ethSpent` / `q.totalEthNeeded` / `q.tokensSold` / `q.tokensRequired` exactly as
      returned — do not round up.
- [ ] Drop any client-side reproduction of the sniper-cap math; the quoter is the source of
      truth.
- [ ] On sell flows, remove any per-buyer plumbing — sells are buyer-agnostic.
