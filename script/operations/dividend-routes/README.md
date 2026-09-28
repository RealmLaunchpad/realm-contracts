# Dividend swap routes

A dividend payout asset is bought, not held: the token accrues native currency and converts it into the
asset on every distribution. Which pools that conversion crosses is the **route**. The **creator**
picks it: the token passes one route per payout asset at creation (`dividendRoutes`, plus `quoteRoutes`
on the direct venue) and registers it on `RealmDividendSwapRegistry` against itself, so no creator
can affect another token's routes. The frontend fills these from its payout catalogue.

**Any ERC20 can be a payout asset.** The registry checks a route's shape only, not its liquidity, and
an empty route is allowed. An asset without a working route simply does not convert: its buffer waits,
whole, until it gets one. Admins can always repoint:

- `setRoute(token, asset, route)`: one token's route.
- `setRoute(ALL_TOKENS, asset, route)` (`ALL_TOKENS == address(0)`): an override for every token paying
  `asset`, existing ones included, in one transaction. The fix for a drained or migrated pool. Clearing
  it (`route = ""`) hands each token its own route back.
- `setQuoteRoute(token | ALL_TOKENS, quote, route)`: the same for the V4 route an ERC20 **quote** is
  sold through (see below).

The bar an override must meet is that it converts a FULL conversion (`MAX_EARNINGS_PER_PROCESS`),
proven on a fork first.

## Picking routes

```
just discover-dividend-routes    # scan the pool manager (and V3) for candidates
just pick-dividend-routes        # probe them at a full conversion and keep the winners
```

`discover_xstock_routes.py` pulls the stock-token list from Robinhood's public asset API, replays every
`Initialize` log on the V4 pool manager that pairs one of those tokens (or USDG) with a currency we care
about, reads each pool's live in-range liquidity, and shortlists the deepest few per pair, plus the V3
WETH pools. It does NOT pick a winner: `liquidity` is denominated in each pool's own currencies, so an
ETH-quoted pool and a USDG-quoted one are not comparable, and a fat 5% pool loses to a thin 0.05% one.

`PickDividendRoutes.s.sol` settles it by buying `MAX_EARNINGS_PER_PROCESS` of every asset through every
candidate (V4, V3, and the asset's V2 pair) against forked state and keeping whichever delivers most. An
asset no candidate can buy at that size is left out. It **broadcasts nothing**. Its output,
`catalogue.robinhood.mainnet.json`, maps asset address to route bytes: ship it in the frontend's payout
catalogue, which creators' routes come from. The probe needs a registry built from this tree at
`DIVIDEND_SWAP_REGISTRY` (it calls the per-token `setRoute`); against an older one every probe scores 0.

Re-run it as the routes' health check, together with the opt-in fork sweep
(`CHECK_DIVIDEND_CATALOGUE=true`, `test_catalogue_everyRouteConvertsAtMaxSize`), which logs each listed
route's price impact at a full conversion. An asset whose pools have moved reports a different winner, or
none: set an `ALL_TOKENS` override on the registry, and update the frontend catalogue.

## Adding one asset

```
uv run script/operations/dividend-routes/discover_xstock_routes.py --only NVDA -o /tmp/nvda.json
DIVIDEND_SWAP_REGISTRY=0x… ROUTES_JSON=/tmp/nvda.json ROUTES_OUT=/tmp/nvda-catalogue.json just pick-dividend-routes
```

`--only` takes ticker symbols or token addresses, comma-separated. The probe is the validation: do not
reimplement it in Python, because an approximation of the swap can disagree with the contract.

## The wire format

One `bytes` per asset, decoded by `DividendRouteLib`:

| Route | Meaning |
| --- | --- |
| empty | no route: the asset does not convert |
| `0x02` | the asset's Uniswap V2 pair with WETH |
| `0x04` + `abi.encode(Hop[])` | a Uniswap V4 path from the native coin; each hop is `{currency, fee, tickSpacing, hooks}` and the last `currency` is the asset |
| `0x03` + `token \| fee \| token…` | a Uniswap V3 path from WETH to the asset, one or two hops |

Registration and `setRoute` check shape only (right asset at the end, hop counts, a V3 path from WETH).
Depth is the fork probe's job.

**Quote (sell) routes.** A dividends leg bought out of an ERC20 quote first sells the quote into native
by walking a V4 route backwards; only V4 names its pools outright, so a quote route must be V4. It is
kept apart from the buy route, so a quote that is also a payout asset can be bought on V2/V3 and still
be sold on V4. Resolution: the quote override, else the token's quote route, else the quote's buy route
(which must then be V4, or that leg does not convert).
