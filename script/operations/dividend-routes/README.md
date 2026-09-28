# Dividend swap routes

A dividend payout asset is bought, not held: the token accrues native currency and converts it into the
asset on every distribution. Which pools that conversion crosses is the **route**. Routes live on
`RealmDividendSwapRegistry`, **one per asset**, set and repointed by the registry's admins
(`setRoute(asset, route)`); tokens name only their payout assets.

**Any ERC20 can be a payout asset.** One without a route simply does not convert: its buffer waits,
whole, until an admin sets a route. The bar a listed route must meet is that it converts a FULL
conversion (`MAX_EARNINGS_PER_PROCESS`), proven on a fork before listing. If a listed pool drains or
migrates, repoint the route: every token paying that asset, existing ones included, follows. Clearing
a route (`setRoute(asset, "")`) is the veto.

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
`catalogue.robinhood.mainnet.json`, maps asset address to route bytes: list each with `setRoute`, and ship
the same set in the frontend's payout catalogue.

Re-run it as the routes' health check, together with the opt-in fork sweep
(`CHECK_DIVIDEND_CATALOGUE=true`, `test_catalogue_everyRouteConvertsAtMaxSize`), which logs each listed
route's price impact at a full conversion. An asset whose pools have moved reports a different winner, or
none: repoint or clear it on the registry.

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

`setRoute` checks shape only (right asset at the end, hop counts, a V3 path from WETH). Depth is the
fork probe's job. Only a V4 route can be walked backwards, which an ERC20 QUOTE's route must be for a
dividends leg to be bought out of that quote.
