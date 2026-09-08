# Unified Factory `createToken` — Integrator Guide

How to deploy a Realm token by calling `RealmFactoryUniV2Unified` or `RealmFactoryUniV4Unified`. This doc is the contract surface only — for the off-chain CREATE2 mining step see [`salt-mining-guide.md`](../salt-mining-guide.md), and for the full per-tx event trace see [`events-per-entry-point.md`](../events-per-entry-point.md).

---

## 1. Which factory to call

Two factories are whitelisted on the launchpad. Pick by graduation venue:

| Factory | Venue | Tax cap (`MAX_TAX_BPS`) | Ownership |
|---|---|---|---|
| `RealmFactoryUniV2Unified` | Uniswap V2 | 5% (500 bps) | Always renounced by default (`tokenOwner = address(0)`) |
| `RealmFactoryUniV4Unified` | Uniswap V4 | 4% (400 bps) | Caller chooses via `renounceOwnership_` |

Each factory dispatches between four token implementations at create time, based on whether you populate `taxCfg` and/or `antiSniperCfg`:

- base, anti-sniper, tax, tax + anti-sniper.

The dispatched implementation determines the CREATE2 initcode, so you **must** mine the salt against the implementation `previewTokenImplementation(...)` returns for your exact inputs (see §3).

---

## 2. Function signatures

### V2

```solidity
function createToken(
    string calldata  name,
    string calldata  symbol,
    bytes32          salt,
    FeeShare[]       feeReceivers,
    SupplyShare[]    supplyShares,
    TaxConfigInit    taxCfg,
    AntiSniperConfigs antiSniperCfg
) external payable returns (address token);
```

### V4

```solidity
function createToken(
    string calldata  name,
    string calldata  symbol,
    bytes32          salt,
    FeeShare[]       feeReceivers,
    SupplyShare[]    supplyShares,
    bool             renounceOwnership_,
    TaxConfigInit    taxCfg,
    AntiSniperConfigs antiSniperCfg
) external payable returns (address token);
```

The V4 form adds `renounceOwnership_`. Everything else is identical.

### Shared structs

```solidity
struct FeeShare {
    address account;
    uint256 shares;            // basis points; sum across array must == 10_000
    bool    directFeesEnabled; // at most ONE entry across the array may set this
}

struct SupplyShare {
    address account;
    uint256 shares;            // basis points; sum across array must == 10_000
}

struct TaxConfigInit {
    uint16 buyTaxBps;          // 0..MAX_TAX_BPS
    uint16 sellTaxBps;         // 0..MAX_TAX_BPS
    uint32 taxDurationSeconds; // 0 disables tax; >0 enables; >365 days requires charity mode
}

struct AntiSniperConfigs {
    uint16    maxBuyPerTxBps;        // 10..300 (0.1%..3% of TOTAL_SUPPLY)
    uint16    maxWalletBps;          // 10..300, must be >= maxBuyPerTxBps
    uint40    protectionWindowSeconds; // 0 disables; otherwise 60..86400
    address[] whitelist;             // up to 20 addresses that bypass the caps
}
```

`TOTAL_SUPPLY` is `1_000_000_000e18` for every Realm token.

---

## 3. Pre-flight workflow

1. Build the exact `(feeReceivers, supplyShares, taxCfg, antiSniperCfg)` you intend to submit. For V4 also decide `renounceOwnership_`.
2. Call `factory.previewTokenImplementation(feeReceivers, supplyShares, taxCfg, antiSniperCfg)` (view). This runs the same validation as `createToken` for the tax and anti-sniper sentinels, and returns the implementation that will be cloned. The V4 `renounceOwnership_` flag is **not** an input — preview always assumes the renounced path. If you intend to keep ownership, the charity-mode owner check in `createToken` will fire only at submit time.
3. (Optional) If `msg.value > 0`, call `factory.quoteBuyOnDeploy(tokenAmount)` to get the ETH amount that yields exactly `tokenAmount` tokens after the launchpad buy fee. The deploy buy is uncapped except by graduation — call `factory.maxBuyOnDeploy(liquidityTier, totalLockedInVaultsBps)` for the max token amount that reaches graduation without reverting `MaxEthReservesExceeded`.
4. Mine `salt` so that `Clones.predictDeterministicAddress(implementation, salt, factory)` ends in `0x1110` (see [`salt-mining-guide.md`](../salt-mining-guide.md)). Statistically ~65k iterations.
5. Submit `factory.createToken(name, symbol, salt, … same args …)` with `value: ethToSpend`.

If the dispatch-relevant inputs differ between preview and submit, the cloned address will not match what you mined and the call reverts with `InvalidTokenAddress`.

---

## 4. What happens on call (high-level)

In order, every successful call performs:

1. **Validation** of `name`/`symbol`, `feeReceivers`, `supplyShares` vs `msg.value`, `antiSniperCfg` sentinel consistency, `taxCfg` (caps + charity-mode rules).
2. **Clone** the dispatched implementation via `Clones.cloneDeterministic` and assert the `0x1110` suffix.
3. **Emit `TokenCreated`** *before* `initialize()` — the indexer creates the entity off this event, so events emitted during initialization depend on it.
4. **Initialize** the cloned token (mints `TOTAL_SUPPLY` to the launchpad, sets graduator/launchpad/feeHandler immutables, applies tax/anti-sniper configs).
5. **`LAUNCHPAD.launchToken(token, BONDING_CURVE)`** — registers the token in the launchpad and emits `TokenLaunched`. The factory **must be whitelisted** on the launchpad or this reverts with `UnauthorizedFactory`.
6. **`IRealmToken.registerFees(feeReceivers)`** — the token self-registers its fee config with `RealmMasterFeeHandler`. Emits one `DirectReceiverRegistered` per direct entry, then `SharesUpdated`.
7. **If `msg.value > 0`**, the factory routes the ETH through `LAUNCHPAD.buyTokensWithExactEth` to buy supply (bounded only by graduation; a buy reaching the threshold graduates the token in the same tx) and distributes the bought tokens proportionally across `supplyShares` (rounding dust goes to the last recipient). Emits `RealmTokenBuy` (launchpad) then `BuyOnDeploy` (factory).

Returns the deployed token address.

---

## 5. Validation rules and revert reasons

All errors are `error Foo()` (4-byte selectors).

### Identity

| Condition | Revert |
|---|---|
| `bytes(name).length == 0` or `bytes(symbol).length == 0` | `InvalidNameOrSymbol` |
| `bytes(symbol).length > 96` | `InvalidNameOrSymbol` |
| Cloned address does not end in `0x1110` (wrong salt for dispatched impl) | `InvalidTokenAddress` |

### Fee receivers (`feeReceivers`)

| Condition | Revert |
|---|---|
| Array empty | `InvalidFeeReceiver` |
| Any `account == address(0)` | `InvalidFeeReceiver` |
| Any duplicate `account` | `InvalidFeeReceiver` |
| Any `shares == 0` | `InvalidShares` |
| `sum(shares) != 10_000` | `InvalidShares` |
| More than 1 entry with `directFeesEnabled == true` | `MultipleDirectFeeReceivers` |

There is no upper bound on the array length at the factory layer. The master fee handler may impose its own caps (`TooManyFeeReceivers`, `TooManyDirectReceivers`) during `registerToken`.

### Supply shares (`supplyShares`) — only when `msg.value > 0`

| Condition | Revert |
|---|---|
| `msg.value == 0` and `supplyShares.length != 0` | `InvalidSupplyShares` |
| `msg.value > 0` and `supplyShares.length == 0` | `InvalidSupplyShares` |
| Any `account == address(0)` | `InvalidSupplyShares` |
| Any duplicate `account` | `InvalidSupplyShares` |
| Any `shares == 0` | `InvalidShares` |
| `sum(shares) != 10_000` | `InvalidShares` |
| Deploy buy exceeds graduation (`graduationThreshold + maxExcessOverThreshold`) | `MaxEthReservesExceeded` |

There is no buy-on-deploy cap: the deploy buy is bounded only by graduation. Use `maxBuyOnDeploy(liquidityTier, totalLockedInVaultsBps)` to size a buy up to the instant-graduation point.

### Anti-sniper config (`antiSniperCfg`)

The factory enforces sentinel consistency only:

| Condition | Revert |
|---|---|
| `protectionWindowSeconds == 0` and any of `maxBuyPerTxBps`, `maxWalletBps`, `whitelist.length` is non-zero | `InvalidAntiSniperConfig` |

Once `protectionWindowSeconds > 0`, the **token's** initializer enforces the substantive caps (see `SniperProtection.sol`):

| Condition | Revert |
|---|---|
| `maxBuyPerTxBps < 10` | `MaxBuyPerTxBpsTooLow` |
| `maxBuyPerTxBps > 300` | `MaxBuyPerTxBpsTooHigh` |
| `maxWalletBps < 10` | `MaxWalletBpsTooLow` |
| `maxWalletBps > 300` | `MaxWalletBpsTooHigh` |
| `maxBuyPerTxBps > maxWalletBps` | `MaxBuyPerTxBpsExceedsMaxWalletBps` |
| `protectionWindowSeconds < 60` | `ProtectionWindowTooShort` |
| `protectionWindowSeconds > 86_400` | `ProtectionWindowTooLong` |
| `whitelist.length > 50` | `WhitelistTooLong` |

### Tax config (`taxCfg`)

| Condition | Revert |
|---|---|
| `taxDurationSeconds == 0` and (`buyTaxBps != 0` or `sellTaxBps != 0`) | `InvalidTaxConfig` |
| `taxDurationSeconds != 0` and `buyTaxBps == 0` and `sellTaxBps == 0` | `InvalidTaxConfig` |
| `buyTaxBps > MAX_TAX_BPS` or `sellTaxBps > MAX_TAX_BPS` | `InvalidTaxBps` |
| `taxDurationSeconds > 120 * 365 days` | `InvalidTaxDuration` |

#### Charity mode (`taxDurationSeconds > 365 days`)

Extending tax beyond the standard one-year cap unlocks durations up to 120 years, but requires:

| Condition | Revert |
|---|---|
| `feeReceivers.length != 1` | `CharityModeFeeReceiverInvalid` |
| `feeReceivers[0].account == msg.sender` (the deployer) | `CharityModeFeeReceiverInvalid` |
| `tokenOwner != address(0)` (V4 only, when `renounceOwnership_ == false`) | `CharityModeOwnerNotRenounced` |

V2 tokens always deploy with `owner == address(0)`, so the renounced-ownership rule is satisfied for free. On V4 you must pass `renounceOwnership_ == true`.

**On-chain enforcement stops at the structural rules** — the contract cannot tell whether the single fee receiver is a real charity. UI and curation own the social trust layer.

---

## 6. Events emitted

In order, for a successful call (Realm-owned events only — ERC20 `Transfer`, OZ `Initialized`, and Uniswap V2/V4 events also appear):

1. `RealmFactory.TokenCreated(token, name, symbol, tokenOwner, launchpad, graduator, feeHandler)`
2. Graduator init events (`PairInitialized`, plus `PoolIdRegistered` on V4)
3. `RealmTaxableTokenInitialized(buyTaxBps, sellTaxBps, taxDurationSeconds, startTaxFromLaunch, buyTaxDecayStartBps, sellTaxDecayStartBps, taxDecayDuration)` — only if `taxCfg` is configured. The three `*Decay*` fields are reserved for a future linear tax-decay feature and are always 0 today.
4. `SniperProtectionInitialized(maxBuyPerTxBps, maxWalletBps, protectionWindowSeconds, whitelist)` — only if `antiSniperCfg` is configured
5. `RealmLaunchpad.TokenLaunched(token, graduationThreshold, maxExcessOverThreshold)`
6. `RealmMasterFeeHandler.DirectReceiverRegistered(token, receiver)` — zero or one (max one direct receiver)
7. `RealmMasterFeeHandler.SharesUpdated(token, recipients, sharesBps)`

If `msg.value > 0`, then additionally at the end:

8. `RealmLaunchpad.RealmTokenBuy(token, buyer=factory, ethAmount=msg.value, tokenAmount, ethFee)`
9. `RealmFactory.BuyOnDeploy(token, buyer=msg.sender, ethSpent, tokensBought, recipients, amounts)`

The order is load-bearing for the subgraph: `TokenCreated` must precede everything else; `SharesUpdated` must come after `TokenLaunched`; `BuyOnDeploy` is always last. Don't reorder.

---

## 7. Disabling features (sentinels)

To deploy a plain token:

```solidity
TaxConfigInit    taxCfg          = TaxConfigInit(0, 0, 0);
AntiSniperConfigs antiSniperCfg = AntiSniperConfigs({
    maxBuyPerTxBps: 0, maxWalletBps: 0, protectionWindowSeconds: 0, whitelist: new address[](0)
});
```

The "off" sentinel is **the duration/window field being zero**. Any other field being non-zero with the duration at zero is rejected (`InvalidTaxConfig` / `InvalidAntiSniperConfig`).

To deploy without buying any supply: pass `value: 0` and an empty `supplyShares` array. Passing one but not the other reverts.

---

## 8. Minimal TypeScript example (viem)

```typescript
import { encodeFunctionData, parseEther } from "viem";

const taxCfg = { buyTaxBps: 0, sellTaxBps: 400, taxDurationSeconds: 14 * 24 * 60 * 60 };
const antiSniperCfg = {
  maxBuyPerTxBps: 0, maxWalletBps: 0, protectionWindowSeconds: 0, whitelist: [],
};
const feeReceivers = [{ account: creator, shares: 10_000n, directFeesEnabled: false }];
const supplyShares = [{ account: creator, shares: 10_000n }];

// 1. Preview the implementation that will be cloned.
const impl = await factoryV4.read.previewTokenImplementation(
  [feeReceivers, supplyShares, taxCfg, antiSniperCfg],
);

// 2. Mine a 0x1110-suffixed salt against (factory, impl). See salt-mining-guide.md.
const salt = findValidSalt(factoryAddress, impl);

// 3. Quote ETH for the deployer buy (optional).
const ethValue = await factoryV4.read.quoteBuyOnDeploy([50_000_000n * 10n ** 18n]);

// 4. Submit. Use the SAME taxCfg/antiSniperCfg you previewed against.
const hash = await factoryV4.write.createToken(
  ["My Token", "MTK", salt, feeReceivers, supplyShares, /*renounce*/ false, taxCfg, antiSniperCfg],
  { value: ethValue },
);
```

The returned token address is also recoverable off-chain as `Clones.predictDeterministicAddress(impl, salt, factory)` once you have the impl + salt, which is what the metadata-insert step uses before broadcasting.
