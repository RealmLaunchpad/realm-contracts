# Deploying a token: the recommended `createToken` overload (V2 & V4)

This documents the **struct-based `createToken` overload with `referral`** — the current
recommended entry point on both unified factories:

- `RealmFactoryUniV2Unified` (graduates to Uniswap V2)
- `RealmFactoryUniV4Unified` (graduates to Uniswap V4)

> **Which overload is "the third one"?** ABI order ≠ source order. In
> `src/factories/RealmFactoryUniV2Unified.sol` this `referral` overload is literally the 3rd
> `createToken`. In `abis/RealmFactoryUniV4Unified.json` the same overload is listed **first**;
> the ABI's 3rd entry is this signature **minus** the trailing `referral`. Documenting the
> `referral` variant covers both — `referral` is just an optional trailing arg (pass
> `address(0)` for "none", which behaves exactly like the non-referral overload).

## Signatures

```solidity
// V2 — RealmFactoryUniV2Unified
function createToken(
    TokenSetupTiered   tokenSetup,
    TaxConfigs         taxConfigs,
    SupplyShare[]      buyOnDeployShares,
    AntiSniperConfigs  antiSniperConfigs,
    CreatorVault[]     creatorVaults,
    address            referral
) external payable returns (address token);

// V4 — RealmFactoryUniV4Unified  (identical, plus `univ4Configs` in position 3)
function createToken(
    TokenSetupTiered   tokenSetup,
    TaxConfigs         taxConfigs,
    UniV4Configs       univ4Configs,   // V4 only
    SupplyShare[]      buyOnDeployShares,
    AntiSniperConfigs  antiSniperConfigs,
    CreatorVault[]     creatorVaults,
    address            referral
) external payable returns (address token);
```

`TOTAL_SUPPLY` is always `1_000_000_000e18`. All bps values are basis points (`10_000` = 100%).

---

## Arguments

### `tokenSetup` — `TokenSetupTiered`

| field | type | meaning / expected value |
|---|---|---|
| `name` | `string` | Token name. Non-empty. |
| `symbol` | `string` | Token symbol. Non-empty, **≤ 96 bytes**. |
| `salt` | `bytes32` | Mined so the token address ends in `0x1110` — see [Salt mining](#salt-mining). |
| `feeShares` | `FeeShare[]` | Fee recipients (see below). |
| `liquidityTier` | `uint8` enum | `LiquidityTier`: `0 = THIN`, `1 = DEFAULT`, `2 = THICK`. **Set it explicitly** — a zero-initialised field resolves to `THIN`, not `DEFAULT`. Controls post-graduation pool depth / graduation mcap (THIN 1.75 ETH / DEFAULT 3.5 ETH / THICK 7.0 ETH). |

`FeeShare`:

| field | type | expected value |
|---|---|---|
| `account` | `address` | Non-zero, unique across the array. |
| `shares` | `uint256` | bps, `> 0`; the array must sum to exactly `10_000`. |
| `directFeesEnabled` | `bool` | At most **one** entry may be `true`. |

### `taxConfigs` — `TaxConfigs`

Static tax and the optional linear launch-tax decay are configured **independently**: set
either, both, or neither. A "decay-only" token (static fields zero, decay fields set) is valid.

| field | type | meaning / expected value |
|---|---|---|
| `buyTaxBps` | `uint16` | Long-term buy tax. `0` disables static tax. Capped by the total-fee rule below. |
| `sellTaxBps` | `uint16` | Long-term sell tax. `0` disables static tax. Capped by the total-fee rule below. |
| `taxDurationSeconds` | `uint32` | Static-tax window length. `0` disables (then `buyTaxBps`/`sellTaxBps` must be `0`). Max `120 * 365 days`. |
| `startTaxFromLaunch` | `bool` | Window anchor for **both** static and decay. `true`: `[launch, launch+duration]` (taxed pre-graduation too). `false`: `[graduation, graduation+duration]` (no tax before graduation). |
| `buyTaxDecayStartBps` | `uint16` | Buy decay rate at the anchor, decaying linearly to 0. `0` = no buy decay. If set, must be `> buyTaxBps`. |
| `sellTaxDecayStartBps` | `uint16` | Sell decay rate at the anchor. `0` = no sell decay. If set, must be `> sellTaxBps`. |
| `taxDecayDuration` | `uint32` | Decay window length. `0` disables decay (then both decay-start fields must be `0`). Max `20 minutes`. `buy+sell` decay starts combined ≤ `2_000` bps (20%). |

Effective rate a trade pays per direction is `max(decay, static)`.

**Total-fee cap** (static bps only): `lpFeeBps + buyTaxBps ≤ 500` and `lpFeeBps + sellTaxBps ≤ 500`.
- V2: post-graduation LP fee is `0`, so **each direction's static tax ≤ 500 bps (5%)**.
- V4: `lpFeeBps` is `univ4Configs.lpFeeBps`, so **static tax ≤ `500 − lpFeeBps`** → **400 bps** with the 100-bps hook, **450 bps** with the 50-bps hook.

### `univ4Configs` — `UniV4Configs` *(V4 only)*

| field | type | expected value |
|---|---|---|
| `renounceOwnership` | `bool` | `true` → token deployed ownerless (`tokenOwner = address(0)`). `false` → `tokenOwner = msg.sender`. |
| `lpFeeBps` | `uint16` | Post-graduation hook fee selector. **Must be `100` or `50`** — anything else reverts. Picks the graduator/hook pair (1% or 0.5% pool fee). |

> V2 has no equivalent: V2 tokens are **always** ownerless and carry **no** post-graduation LP fee.

### `buyOnDeployShares` — `SupplyShare[]`

Optional buy-on-deploy: if `msg.value > 0`, the factory buys from the curve and splits the tokens
across these recipients.

| field | type | expected value |
|---|---|---|
| `account` | `address` | Non-zero, unique across the array. |
| `shares` | `uint256` | bps, `> 0`; the array must sum to exactly `10_000`. |

Rules:
- `msg.value == 0` ⇔ `buyOnDeployShares.length == 0` (pass one without the other → revert).
- There is **no** buy-on-deploy cap: the deploy buy is bounded only by graduation. A buy whose ETH would
  push the curve past `graduationThreshold + maxExcessOverThreshold` reverts `MaxEthReservesExceeded`; a buy
  that reaches the threshold **graduates the token in the same tx**.
- Use `maxBuyOnDeploy(liquidityTier, totalLockedInVaultsBps)` for the max token amount that reaches
  graduation without tripping that revert, then
  `quoteBuyOnDeploy(liquidityTier, tokenAmount, totalLockedInVaultsBps, taxCfg[, univ4Configs])`
  to compute the `msg.value` for a target token amount.

### `antiSniperConfigs` — `AntiSniperConfigs`

Opt-in via a non-zero `protectionWindowSeconds`. To **disable**, pass all zeros / empty array.

| field | type | expected value (when enabled) |
|---|---|---|
| `maxBuyPerTxBps` | `uint16` | `10..300` (0.1%..3% of supply). |
| `maxWalletBps` | `uint16` | `10..300`, and `≥ maxBuyPerTxBps`. |
| `protectionWindowSeconds` | `uint40` | `0` disables. Otherwise `60 .. 86_400` (1 min .. 24 h). |
| `whitelist` | `address[]` | Addresses that bypass caps during the window. **≤ 20** entries. |

Sentinel: if `protectionWindowSeconds == 0`, then `maxBuyPerTxBps`, `maxWalletBps` and
`whitelist.length` must all be `0`.

### `creatorVaults` — `CreatorVault[]`

Optional vesting vaults that lock part of the supply at deploy. Empty array = none.

| field | type | expected value |
|---|---|---|
| `owner` | `address` | Non-zero. |
| `supplyBps` | `uint256` | Non-zero **multiple of `500` (5%)**. Sum across all vaults ≤ `3_000` (30%). |
| `cliffSeconds` | `uint256` | Unconstrained. |
| `vestingSeconds` | `uint256` | Unconstrained. |

At most **5** vaults. Locked supply selects an allocation-specific bonding curve for the chosen tier
(so the same `liquidityTier` graduation invariants hold with a relaxed starting mcap).

### `referral` — `address`

Off-chain signal for relayers. If non-zero, emits `TokenReferral(token, referral)`. **No** on-chain
storage or payout is wired to it (yet). Pass `address(0)` for none.

---

## Revert conditions

All errors are 4-byte custom errors.

| revert | when |
|---|---|
| `InvalidNameOrSymbol` | empty `name`; empty `symbol`; or `symbol` > 96 bytes. |
| `InvalidTokenAddress` | cloned address doesn't end in `0x1110` (salt not mined against the dispatched impl / wrong deployer). |
| `InvalidFeeReceiver` | `feeShares` empty, contains `address(0)`, or has duplicate accounts. |
| `InvalidShares` | any `shares == 0`, or `feeShares` / `buyOnDeployShares` sum ≠ `10_000`. |
| `MultipleDirectFeeReceivers` | more than one `feeShares` entry with `directFeesEnabled == true`. |
| `InvalidSupplyShares` | `msg.value` and `buyOnDeployShares.length` disagree (one zero, one not); or zero/duplicate accounts. |
| `MaxEthReservesExceeded` | deploy buy exceeds graduation (`graduationThreshold + maxExcessOverThreshold`); size it with `maxBuyOnDeploy`. |
| `InvalidTaxConfig` | tax sentinel mismatch: `taxDurationSeconds == 0` with non-zero bps (or vice-versa); or `taxDecayDuration == 0` with non-zero decay-start bps (or vice-versa). |
| `InvalidTaxBps` | `lpFeeBps + buyTaxBps` or `lpFeeBps + sellTaxBps` > `500`; combined decay start > `2_000`; or a decay start ≤ its direction's static rate. |
| `InvalidTaxDuration` | `taxDurationSeconds` > 120 years; `taxDecayDuration` > 20 min; or (both set) `taxDurationSeconds < taxDecayDuration`. |
| `InvalidAntiSniperConfig` | `protectionWindowSeconds == 0` but another anti-sniper field is non-zero/non-empty. |
| `MaxBuyPerTxBpsTooLow` / `…TooHigh` | (window enabled) `maxBuyPerTxBps` outside `10..300`. |
| `MaxWalletBpsTooLow` / `…TooHigh` | (window enabled) `maxWalletBps` outside `10..300`. |
| `MaxBuyPerTxBpsExceedsMaxWalletBps` | (window enabled) `maxBuyPerTxBps > maxWalletBps`. |
| `ProtectionWindowTooShort` / `…TooLong` | (window enabled) `protectionWindowSeconds` outside `60..86_400`. |
| `WhitelistTooLong` | `whitelist.length > 50`. |
| `InvalidCreatorVault` | a vault `owner == address(0)`, or `supplyBps` is zero / not a multiple of 500. |
| `CreatorVaultAllocationTooHigh` | sum of `supplyBps` > `3_000` (30%). |
| `TooManyCreatorVaults` | more than 5 vaults. |
| `InvalidLpFeeBps` | *(V4)* `univ4Configs.lpFeeBps` not `100` or `50`. |

> Note: unlike the older frontend skill, this version has **no charity mode** — long tax durations
> impose no fee-receiver or ownership constraints (only the 120-year overflow cap applies).

---

## Salt mining

The token is a `Clones.cloneDeterministic` proxy; its address is a function of
`(factory, impl, msg.sender, salt)`. The address **must end in `0x1110`** (else `InvalidTokenAddress`).

Two things to get right:

1. **Impl** — dispatch clones one of two impls: `TOKEN_IMPL_TAX` if the token is taxable
   (`taxDurationSeconds != 0` **or** `taxDecayDuration != 0`), else `TOKEN_IMPL_BASE`. Anti-sniper
   does **not** change the impl. Get the exact impl from
   `previewTokenImplementation(feeShares, buyOnDeployShares, taxConfigs, antiSniperConfigs)` (view;
   it runs the same tax/anti-sniper validation and returns the impl to mine against).
2. **Deployer namespacing** — the effective CREATE2 salt is `keccak256(abi.encodePacked(msg.sender, salt))`.
   Mine with the exact account that will send `createToken`. A salt mined for one sender yields a
   different address for another (this is the front-run defense — a salt lifted from a pending tx is
   useless to anyone else).

Reference (viem):

```javascript
import { getCreate2Address, keccak256, concat, encodePacked, toHex, pad } from "viem";

const PROXY_PREFIX = "0x3d602d80600a3d3981f3363d3d373d3d3d363d73";
const PROXY_SUFFIX = "0x5af43d82803e903d91602b57fd5bf3";

// impl = previewTokenImplementation(...); deployer = the createToken sender
function findValidSalt(factory, impl, deployer) {
  const initcodeHash = keccak256(concat([PROXY_PREFIX, impl, PROXY_SUFFIX]));
  for (let i = 0n; ; i++) {
    const salt = pad(toHex(i), { size: 32 });
    const effectiveSalt = keccak256(encodePacked(["address", "bytes32"], [deployer, salt]));
    const addr = getCreate2Address({ from: factory, salt: effectiveSalt, bytecodeHash: initcodeHash });
    if (addr.toLowerCase().endsWith("1110")) return { salt, tokenAddress: addr };
  }
}
```

~65k iterations on average (sub-100ms). Recompute the initcode hash whenever the dispatch path
(tax vs base) changes. If dispatch-relevant inputs differ between preview and submit, the mined
address won't match and the call reverts with `InvalidTokenAddress`.

---

## Minimal call flow

1. Build `(tokenSetup, taxConfigs[, univ4Configs], buyOnDeployShares, antiSniperConfigs, creatorVaults, referral)`.
2. `impl = previewTokenImplementation(feeShares, buyOnDeployShares, taxConfigs, antiSniperConfigs)`.
3. Mine `salt` against `(factory, impl, deployer)` → address ending in `0x1110`.
4. *(optional)* `value = quoteBuyOnDeploy(liquidityTier, tokenAmount, totalLockedInVaultsBps, taxCfg[, univ4Configs])`.
5. `createToken(...)` with `value` (`0` if not buying on deploy).
