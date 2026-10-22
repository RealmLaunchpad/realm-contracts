# ETF hook: JIT liquidity math

`RealmEtfHook` fills every ETF/USDG swap from the vault (deposit / mint / redeem). With JIT, it also places the vault's output as a one-tick position, lets the pool's own curve fill almost the whole trade against it, and removes the position in `afterSwap`. The pool manager then emits a real `Swap` and `slot0` ends at the trade price.

This document derives the position from the trade with closed-form integer math, and proves the three properties the design needs:

- **P1, funded:** the position costs at most the vault's output.
- **P2, contained:** the curve fills exactly the predicted amounts within the one funded step, so it never needs liquidity beyond the range, whatever the trade and whatever the prior pool state.
- **P3, near exhaustion:** what the position keeps is a few raw units of the output token plus output worth about one raw unit of the input token; the hook's own share of the trade is the gap between the trade price and the range (at most 1.5 ticks) plus rounding.

No parameter is tuned. Fuzzing only checks that the implementation matches the derivation.

## Notation

- `Q = 2^96`. Sqrt prices are the core's `uint160` X96 values, and `s(t) = TickMath.getSqrtPriceAtTick(t)`.
- A pool price is token1 per token0 in raw units.
- `X`: what the swapper pays in total (input token); `Y`: what the swapper receives in total (output token). Both come from the vault: an exact-input buy has `X` given and `Y = deposit(X)`; an exact-output buy has `Y` given and `X = mint(Y)`; an exact-input sell has `X` given and `Y = redeemOnCredit(X)`.
- The position holds only the output token, one tick wide: `[tA, tB]` with `tB = tA + 1`.
- The pool is created with `fee = 0` and `tickSpacing = 1` (enforced in `beforeInitialize`). JIT runs only when the protocol fee for the swap's direction is 0; otherwise the hook falls back to the non-JIT fill (the whole trade through its own delta, curve untouched). With every fee at 0, `SwapMath.computeSwapStep` charges nothing.
- All `getAmount*Delta`, `getNextSqrtPriceFrom*` and `getLiquidityForAmount*` are the core / periphery library functions, called with the exact arguments the core uses.

## Invariant Z: the pool holds no liquidity outside a hook call

Only the hook can add liquidity (`beforeAddLiquidity` reverts; the hook's own calls skip its hooks). The hook adds one position in `beforeSwap` and removes it in full in `afterSwap` of the same swap; removing its only position clears both ticks. Between those two calls no outside code runs: the vault fill happens before the position is added, and the core swap is the only thing in between.

## Step 1: move the price to the start of the range

The hook swaps on its own pool for 1 unit of input, with the price limit at the range's starting edge. Under Z there is no liquidity, so nothing is exchanged (delta 0) and the core walks the price to exactly the limit. Prior `slot0` therefore plays no part, and a stale or pushed pool price cannot be exploited. The factory initialises the pool at the seed price atomically with ETF creation (no one can initialise it earlier: `beforeInitialize` requires `factory.isEtf`), so this walk crosses only the ticks the NAV moved since the last trade.

The walk is capped at `MAX_WALK_TICKS` (4,096 ticks, ~50%) per swap. The core crosses one 256-tick bitmap word per loop, so a price parked far from NAV (a trade filled at a pushed NAV) would otherwise bill the next swapper for the whole walk. Farther than the cap, the hook moves the price `MAX_WALK_TICKS` towards the range and fills that swap without JIT; JIT resumes once the range is in reach.

## Case U: price moves up (`zeroForOne = false`; input token1, output and position token0)

Range BELOW the trade price `p = X/Y`:

```
σ  = floor(sqrt(floor(X · 2^192 / Y)))     so σ² ≤ X·Q²/Y
tB = getTickAtSqrtPrice(σ)                 so s_b = s(tB) ≤ σ
tA = tB − 1;  start at s_a
L  = getLiquidityForAmount0(s_a, s_b, Y) = floor(Y · floor(s_a·s_b/Q) / (s_b − s_a))
```

So `L ≤ Y·s_a·s_b / (Q·(s_b − s_a))` (real division), call it (★).

**P1.** The position's cost is `c = getAmount0Delta(s_a, s_b, L, up) = ⌈⌈L·Q·(s_b−s_a)/s_b⌉ / s_a⌉`. By (★), `L·Q·(s_b−s_a)/s_b ≤ Y·s_a`, an integer, so the inner ceiling is `≤ Y·s_a` and the outer is `≤ Y`. ∎

**Lemma B.** The input that takes the curve from `s_a` to `s_b` is `B = getAmount1Delta(s_a, s_b, L, up) = ⌈L·(s_b−s_a)/Q⌉`. By (★), `L·(s_b−s_a)/Q ≤ Y·s_a·s_b/Q² < Y·s_b²/Q² ≤ X` (strict because `s_a < s_b`; last step from `s_b ≤ σ`). `X` is an integer, so `B ≤ X`. ∎

**Exact input.** The curve gets `C = B − 1`, and the hook takes `ε = X − C ≥ 1` of the input through its own delta.

- **P2.** The core's step from `s_a` toward `s_b` computes `amountIn = getAmount1Delta(s_a, s_b, L, true) = B`, the identical call. Since `C < B` it takes the "does not reach target" branch: it consumes all of `C`, sets `s_n = getNextSqrtPriceFromInput(s_a, L, C, false)` and `out = getAmount0Delta(s_a, s_n, L, false)`, and the swap ends with nothing left to fill. The hook computes the same calls, so it knows the curve's exact output before the swap. `s_n` is at most `s_b`; it can equal `s_b` only where one raw sqrt-price step is worth more than one raw token unit, and then the core crosses the far tick with nothing left to fill, which changes no amount. ∎
- The hook gives the swapper `Y − out` through its own delta, so the swapper gets exactly `Y`.
- **P3.** `s_n = s_a + ⌊C·Q/L⌋ ≥ s_b − Q/L − 1`. The output left in the position is at most `L·Q·(s_b − s_n)/(s_n·s_b) + 3 ≤ (Q² + L·Q)/(s_a·s_b) + 3` raw units: 3 raw units of output plus output worth (at price ≤ `p`) about `1 + L/Q` raw units of input. `L/Q < 1` unless `L > 2^96`. ∎
- **Price.** `ε` is the gap between `p` and the range's price: `ε/X ≤ 1 − s_a·s_b/(Q²·p) < 1 − 1.0001^(−1.5) ≈ 1.5 bp`. The `Swap` event's price `C/out` lies in `[s_a², s_b²]/Q²`, at most 2 ticks below `p`.

**Exact output** (buys only). The curve delivers `outC = Bo − 1` with `Bo = getAmount0Delta(s_a, s_b, L, false)`, and the hook delivers `δ = Y − outC` through its own delta.

- **P2.** The core computes `amountOut = getAmount0Delta(s_a, s_b, L, false) = Bo`; since `outC < Bo` it does not reach the target, and `s_n = getNextSqrtPriceFromOutput(s_a, L, outC, false)`. The curve's input is `inC = getAmount1Delta(s_a, s_n, L, true)`. ∎
- `inC ≤ B ≤ X` (monotone in `s_n ≤ s_b`, then Lemma B), so the hook charges the swapper `X − inC ≥ 0` through its own delta and the swapper pays exactly `X`.
- **P3.** `δ = (Y − c) + (c − Bo) + 1`: both terms are rounding, at most `Y/Q + Y·Q/(s_a·s_b) + Q·(s_b−s_a)/(s_a·s_b) + (s_b−s_a)/Q + 5` raw units of output (each floor in `L` is worth one unit of `L` or of its intermediate).

## Case D: price moves down (`zeroForOne = true`; input token0, output and position token1)

Range ABOVE `P = Y/X` (token1 per token0):

```
σ  = ceil(sqrt(ceil(Y · 2^192 / X)))       so σ² ≥ Y·Q²/X
tA = smallest tick with s(tA) ≥ σ;  tB = tA + 1;  start at s_b
L  = getLiquidityForAmount1(s_a, s_b, Y) = floor(Y·Q / (s_b − s_a))
```

**P1.** `c = getAmount1Delta(s_a, s_b, L, up) = ⌈L·(s_b−s_a)/Q⌉ ≤ Y`, since `L·(s_b−s_a)/Q ≤ Y`. ∎

**Lemma B.** `B = getAmount0Delta(s_a, s_b, L, up) = ⌈⌈z⌉/s_a⌉` with `z = L·Q·(s_b−s_a)/s_b ≤ Y·Q²/s_b`. Then `B < Y·Q²/(s_a·s_b) + 1/s_a + 1`. From `s_a² ≥ σ² ≥ Y·Q²/X`: `Y·Q²/(s_a·s_b) ≤ X·s_a/s_b`. So `B < X − (X·s_a·(s_b−s_a)/s_b − 1)/s_a + 1`. For one tick, `s_b − s_a ≥ s_a·4.99e-5` and `s_a ≥ MIN_SQRT_PRICE ≈ 4.3e9`, so `s_a·(s_b−s_a)/s_b > 2e5 > 1`, and with `X ≥ 1` the bracket is positive. Hence `B < X + 1`, and since both are integers, `B ≤ X`. ∎

Exact input and exact output then follow Case U line by line, with `getAmount0Delta` ↔ `getAmount1Delta` swapped, `zeroForOne = true` in `getNextSqrtPriceFrom*`, the step running from `s_b` down toward `s_a`, and P2's "does not reach target" argument unchanged. For P3 the input is token0, priced by rounding the sqrt price UP, so one raw sqrt-price step can hold `L·Q/s²` input: the position keeps at most `P + L/Q + 2` raw output units (`P = Y/X`), i.e. 2 raw units of output plus output worth 1 raw unit of input, plus `L/Q`. The `Swap` price sits at most 2 ticks above `P`, that is, in the swapper's favour by at most 2 ticks on the curve portion, offset exactly by the hook's delta.

## Core-step equivalence

P2 relies on the core running exactly one funded step, from the start edge with liquidity `L`, toward the far edge. That holds:

- Only `tA` and `tB` are initialised (Z), so the next initialised tick from the start edge in the swap's direction is the far edge (one tick away, so no bitmap-word boundary can split the step).
- If the start edge's tick is not yet active when the swap begins (`slot0.tick` sits just outside the position after Step 1), the core first takes a zero-length step to the same price (zero liquidity, zero amounts), crosses the edge (activating `L`), then runs the funded step. The amounts are unchanged.
- The swapper's price limit must lie beyond the far edge. If it does not, the core would stop early, so the hook skips JIT for that swap and fills it whole.

**Defence in depth.** `afterSwap` checks that the pool's actual `swapDelta` equals the predicted `(inC, outC)` and reverts otherwise (`JitMismatch`). Safety therefore never rests on this equivalence argument alone: a mismatch (a future core change) reverts the trade instead of mispaying.

**Verification.** `test/etf/RealmEtfJitMath.t.sol` runs the core's own `SwapMath.computeSwapStep` on every fuzzed plan (both directions, exact input and output, raw amounts up to 2^100 and realistic USDG/share sizes) and asserts P1, P2, P3 and the removal prediction. `test/etf/RealmEtf.t.sol` swaps through the real pool on a Robinhood fork and checks the events, the final price and the empty pool.

## Settlement and rounding dust

Removing the position, the core pays out at the final price `s_n`, rounding DOWN: `removedOut = getAmount{0,1}Delta` of the output side and `removedIn` of the input side (the same formula whether `s_n` is inside the range or on its far edge). The hook therefore gets back up to a few raw units less than the curve took (`inC − removedIn` input, `c − outC − removedOut` output). The plan predicts both exactly, and someone must absorb them:

- **The side the hook does not specify is charged to the swapper.** Exact input: the swapper receives `outC + (Y − c + removedOut)`, i.e. `Y` minus the output dust. Exact output: the swapper pays `inC + (X − removedIn)`, i.e. `X` plus the input dust.
- **The specified side is covered by a buffer held back from the ETF fill.** An exact-input buy deposits `X − USDG_BUFFER` (3 raw USDG); an exact-output buy mints `N + SHARES_BUFFER + N/2^40` shares. If the plan's dust on that side exceeds the buffer, the hook skips JIT for the trade. At real prices it never does: the USDG dust is at most 2 raw units, and the share dust is bounded by one sqrt-price step's worth.
- **Sells need no buffer.** Their input is shares, which the hook only locks as claims: it locks `X − (inC − removedIn)` instead of `X`. The few raw shares the core keeps stay in the pool manager unowned, counted in `totalSupply` like burned-but-not-burned dust.
- **The hook clears what it is still owed in `afterSwap`.** The pool manager books the hook's `beforeSwap` delta only after `afterSwap` returns, so the hook adds its own part to its `currencyDelta`. Positive USDG goes to the ETF (stray USDG for `reinvest`); positive shares become claims.

## When the hook does not use JIT

The hook skips JIT and fills the whole trade through its delta, as before JIT, when:

- the protocol fee for the direction is non-zero;
- the price is out of tick range, or `X/Y ≥ 2^64` (guards the `X·2^192` product);
- `L` is 0 or exceeds `maxLiquidityPerTick`;
- `B ≤ 1` (or `Bo ≤ 1`), meaning there is nothing for the curve to fill;
- the rounding dust on the specified side exceeds the buffer (never at real prices).

In these cases the trade still executes; only its `Swap` event reads zero.

## Events

The pool manager's `Swap` reports the curve portion `(inC, outC)`. The hook emits Uniswap's aggregator-hook `HookSwap(poolId, sender, amount0, amount1, 0)` for its own portion, signed from the hook's side (positive: paid by the swapper), the opposite of `Swap`. `Swap` minus `HookSwap` is exactly what the swapper paid and received.

## Gas

Measured on the Robinhood fork, 3-asset ETF, against the same trades without JIT:

| Trade | Without JIT | With JIT | Extra |
|---|---|---|---|
| Exact-input buy | 721k | 965k | +244k (+34%) |
| Exact-output buy | 739k | 950k | +211k (+29%) |
| Exact-input sell | 586k | 757k | +172k (+29%) |

The extra is roughly constant, so it shrinks in relative terms as ETFs hold more assets.
