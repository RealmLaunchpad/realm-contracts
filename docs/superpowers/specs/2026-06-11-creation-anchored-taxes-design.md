# Design: creation-anchored taxes for launchpad-v2 taxable tokens

Date: 2026-06-11 · Branch: `feat/launchpad-v2` · Status: approved, pending spec review

## Goal

Make Realm taxable tokens charge tax **from token creation**, not from graduation:

- The tax period is `[launchTimestamp, launchTimestamp + taxDurationSeconds]`, where `launchTimestamp`
  is the token's creation (init) time — the same anchor the sniper-protection window already uses.
- The period spans graduation transparently. Graduation is irrelevant to the tax rate/window;
  only the **collection mechanism** may differ across it (see V2 below).
- The period may end during pre-grad or post-grad.
- `getLaunchpadFees()` (pre-grad) and `getTaxConfig()` (post-grad, via the V4 hook) must reflect the
  **same effective rate** for a given timestamp.

This resolves the deferred OPEN item from the launchpad-v2 pre-grad fee refactor (taxable variants
previously sourced taxes only post-grad).

## Decisions (locked with user)

1. **Single source of truth** for the tax rate = `RealmTaxableToken.buyTaxBps` / `sellTaxBps`, used
   pre- and post-graduation interchangeably.
2. **Remove the redundant base storage** `RealmToken.taxBuyBps` / `taxSellBps`, the
   `InitializeParams.taxBuyBps` / `taxSellBps` fields, and the two tax args of the
   `LaunchpadFeesInitialized` event (full cleanup / "C1"). The indexer sources pre-grad tax config from
   `RealmTaxableTokenInitialized(buyTaxBps, sellTaxBps, taxDurationSeconds)`; the window start is that
   event's block timestamp.
3. **Do not touch `LivoSwapHook`.** It anchors on `graduationTimestamp + taxDurationSeconds`; we make
   `getTaxConfig()` return a dynamically-zeroed tax so the hook's stale math lands correctly.
4. **Remove `setLaunchpadFees()`.** The LP fee is immutable post-launch (the owner must not be able to
   change LP fees). The only tax control is the existing decrease-only `setTaxBps()` on
   `RealmTaxableToken`. `LaunchpadFeesUpdated` and `LaunchpadFeesCanOnlyDecrease` go with it.
5. **Reuse one creation timestamp.** Hoist `launchTimestamp` from `SniperProtection` to base
   `RealmToken`; the tax window and the sniper window share it. No separate `taxStartTimestamp`.

### Pre-existing-event safety (verified against `main`)

`LaunchpadFeesInitialized`, `LaunchpadFeesUpdated`, `setLaunchpadFees`, base `taxBuyBps`,
`getLaunchpadFees` are all **branch-new** (0 hits on `main`) — safe to reshape/remove. Events present
on `main` keep identical signatures and emit behavior: `RealmTaxableTokenInitialized`, `TaxBpsUpdated`,
`CreatorTaxesAccrued`, `LpFeesAccrued`, `Graduated`, `CreatorTaxSwapback`, `SniperProtectionInitialized`
(no `launchTimestamp` arg, so the hoist doesn't touch it). The only conceptual change is that, for a v2
token, the indexer anchors the tax window at the `RealmTaxableTokenInitialized` block timestamp instead
of `Graduated`; it distinguishes v2 tokens by version/address anyway.

## Mechanism by phase

| Phase | Who charges tax | Source of rate | Window check |
|-------|-----------------|----------------|--------------|
| Pre-grad (V2 & V4) | `RealmLaunchpad` via `getLaunchpadFees()` | `buyTaxBps`/`sellTaxBps` | `launchTimestamp + taxDurationSeconds` (in the token override) |
| Post-grad V4 | `LivoSwapHook` via `getTaxConfig()` | `buyTaxBps`/`sellTaxBps` | hook uses `graduationTimestamp + taxDurationSeconds`; token feeds it a zeroed config once the real (creation-anchored) window closes |
| Post-grad V2 | token `_update` (intrinsic) + swapbacks | `buyTaxBps`/`sellTaxBps` | `launchTimestamp + taxDurationSeconds` |

## File-by-file changes

### `src/interfaces/IRealmToken.sol`
- `InitializeParams`: remove `taxBuyBps`, `taxSellBps`.
- `LaunchpadFeesInitialized` → `(uint16 lpFeeBps, uint16 treasuryShareBps)`.
- Remove `event LaunchpadFeesUpdated` and `function setLaunchpadFees(...)`.

### `src/tokens/RealmToken.sol`
- Remove storage `taxBuyBps`, `taxSellBps`; remove error `LaunchpadFeesCanOnlyDecrease`.
- **Add `uint40 public launchTimestamp`** (packs into the slot freed by removing the two tax uint16s,
  alongside `feeHandler`/`lpFeeBps`/`treasuryShareBps`).
- `_initializeRealmToken`: drop the two tax stores; emit `LaunchpadFeesInitialized(lpFeeBps, treasuryShareBps)`;
  set `launchTimestamp = uint40(block.timestamp)` **at the end of the function (after the initial mint)**, so the
  mint still observes `launchTimestamp == 0` exactly as today.
- Remove `setLaunchpadFees()`.
- `getLaunchpadFees()`: return `{lpFeeBps, treasuryShareBps, taxBps: 0}` (non-taxable tokens have no tax).
- Update `lpFeeBps`/`treasuryShareBps` docstrings (now fixed at launch, no setter).
- Update the mint-bypass security comments (lines ~63-87, ~131-135): the initial mint is still uncapped
  because, during it, `launchTimestamp == 0` (set afterward in this same initializer) **and**
  `protectionWindowSeconds == 0` (set later by `_initializeSniperProtection`).

### `src/tokens/SniperProtection.sol`
- Remove the `launchTimestamp` storage var and its assignment in `_initializeSniperProtection`
  (now owned by `RealmToken`). The `SniperProtectionInitialized` event is unaffected (never carried it).
- Add a `uint40 launchTimestamp` **parameter** to `_checkSniperProtection(...)` and
  `_maxTokenPurchase(...)`; use the param in the two `block.timestamp >= launchTimestamp + protectionWindowSeconds`
  checks. Update the "Mints happen when `launchTimestamp == 0`" comment to reflect the param source.

### `src/tokens/RealmTokenSniperProtected.sol`, `RealmTaxableTokenUniV2SniperProtected.sol`, `RealmTaxableTokenUniV4SniperProtected.sol`
- At each `_checkSniperProtection(...)` and `_maxTokenPurchase(...)` call site (one of each per file),
  pass the inherited base `launchTimestamp`.

### `src/tokens/RealmTaxableToken.sol`
- Add internal helper `_taxWindowActive()`:
  `block.timestamp <= uint256(launchTimestamp) + taxDurationSeconds` (reads base `launchTimestamp`).
- `_initializeTaxConfig`: unchanged re: timestamps (no `taxStartTimestamp` to set).
- **Override `getLaunchpadFees()`**: return base `lpFeeBps`/`treasuryShareBps` and
  `taxBps = _taxWindowActive() ? (trade.isBuy ? buyTaxBps : sellTaxBps) : 0`.
- **Make `getTaxConfig()` dynamic**: when `_taxWindowActive()` is false, return the tax fully zeroed
  (`buyTaxBps = sellTaxBps = 0` **and** `taxDurationSeconds = 0`); `graduationTimestamp` unchanged. When
  active, return the stored rates + duration.
  - Zeroing the rates (not just the duration) closes a real edge: if the window expires *before*
    graduation and a pool swap lands in the exact graduation block, the hook's
    `block.timestamp > graduationTimestamp + 0` is false, so duration-only zeroing would wrongly tax
    that block. With rates zeroed, the hook's `taxBps == 0` guard catches it.
  - Active case is correct because `graduationTimestamp >= launchTimestamp`, so the hook's
    `block.timestamp <= graduationTimestamp + taxDurationSeconds` holds whenever the real window is open.
- `markGraduated()` keeps stamping `graduationTimestamp` (now only the hook's "has graduated?" guard).

### `src/tokens/RealmTaxableTokenUniV2.sol`
- `_update`: re-anchor both window checks from `graduationTimestamp` to `launchTimestamp`
  (the intrinsic-tax gate and the post-window residual-drain branch). **Keep the `_graduated` gate** —
  pre-grad tax is charged by the launchpad, not intrinsically — and swapbacks stay post-grad-only
  (pre-grad `to == pair` already reverts).

### `src/tokens/RealmTaxableTokenUniV4.sol` / `src/hooks/LivoSwapHook.sol`
- No change (V4 post-grad tax is driven entirely by the dynamic `getTaxConfig()`).

### `src/factories/RealmFactoryAbstract.sol`
- `_cloneAndCreateToken`: drop `taxBuyBps`/`taxSellBps` from the `InitializeParams` literal (lines ~483-484).
- No signature changes to any `createToken` / `previewTokenImplementation` / `quoteBuyOnDeploy` overload.

### Docs & indexer
- `docs/events-per-entry-point.md`: drop `LaunchpadFeesUpdated`, update `LaunchpadFeesInitialized` to 2 args.
- Envio: mirror the event change to `../envio-indexer/config.yaml`, `config.dev.yaml`, `config.prod.yaml`.

## Edge cases

- **Deploy-buy** happens at creation → window active → deploy-buy is taxed (unchanged, consistent).
- **Window expires pre-grad**: post-expiry pre-grad trades pay no tax (`getLaunchpadFees` returns 0); if
  the token graduates later, no post-grad tax either; V2 collected no intrinsic tax, so swapbacks are a
  no-op (residual-drain branch handles any dust).
- **Same-block graduation + first swap with pre-expired window** (V4): handled by zeroing rates in
  `getTaxConfig()`.
- **Quote staleness across the window boundary**: a quote taken just before expiry but executed after
  charges the lower (expired) fee; rounds in the user's favor, benign.
- **Initial mint not capped** for sniper variants: preserved — the mint runs while
  `launchTimestamp == 0`/`protectionWindowSeconds == 0`.

## Invariant

For any timestamp `t`, the effective buy/sell tax bps is identical whether the trade is routed pre-grad
(launchpad) or post-grad (hook / V2 `_update`): nonzero iff `t <= launchTimestamp + taxDurationSeconds`.

## Testing

- Tax active **across** the graduation boundary: pre-grad buy/sell taxed via the launchpad
  (`CreatorTaxesAccrued`), post-grad via hook (V4) / `_update` (V2), same bps both sides.
- Tax window ending **pre-grad**: trades after expiry untaxed; later graduation stays untaxed.
- Tax window ending **post-grad**: standard.
- `getTaxConfig()` returns zeroed tax after the window, real values within.
- `setTaxBps()` still decrease-only and now drives both pre- and post-grad (single source).
- `setLaunchpadFees()` removed (compile + test removal); LP fee proven immutable.
- V2: intrinsic tax and swapbacks only post-grad; window anchored at creation.
- Sniper protection unchanged in behavior after the `launchTimestamp` hoist: window timing identical,
  initial mint still uncapped, `launchTimestamp()` getter still readable (now on every token).

Existing suites to update: `test/tokens/launchpadFees.t.sol`, `test/tokens/RealmTaxableTokenUniV2.t.sol`,
`test/tokens/sniperProtection.t.sol`, `test/launchpad/launchpadFeeSplit.t.sol`, `test/launchpad/base.t.sol`,
`test/graduators/taxToken.base.t.sol`, `test/graduators/graduationUniv4.taxToken.t.sol`,
`test/factories/RealmFactoryUniV2UnifiedTax.t.sol`, `test/factories/RealmFactoryUniV4Unified.t.sol`,
`test/quoter/RealmQuoter.t.sol`, `test/e2e/suites/E2ESniperWindow.t.sol`, and the e2e/integration bases.
Verify with `just fast-test`.
