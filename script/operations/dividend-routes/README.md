# Dividend swap routes

A dividend payout asset is bought, not held: the token accrues native currency and converts it into the
asset on every distribution. Which pools that conversion crosses is the **route**, and the token's
creator picks it at creation. `LivoDividendSwapRegistry` records it against that token and never lets it
change.

**Livo does not review payout assets.** There is no whitelist and no admin approval — a creator names
the pools and the registry checks only that they are real: initialized, holding liquidity, and ending at
the asset. What nothing on-chain can check is whether those pools quote the asset's real market price, so
a creator can point their own token at a pool they control. The blacklist is the one lever left for an
asset that turns out to be hostile, and it can only refuse.

An asset with a deep enough Uniswap V2 pair needs no route at all — the empty route selects that pair,
which is the permissionless path the registry has always had. Routes exist for the assets that pair
cannot reach: Robinhood Chain's ~190 xStocks have no V2 pair, and their liquidity is Uniswap V4, most of
it against native ETH and the rest against USDG.

## The suggested-asset catalogue

The frontend ships a shortlist of payout assets so a creator picks a ticker instead of pasting an address
and hunting for pools. Each entry carries its route, and this directory is where those routes come from.

```
just discover-dividend-routes    # scan the pool manager for candidates
just pick-dividend-routes        # probe them and keep the winners
```

`discover_xstock_routes.py` pulls the stock-token list from Robinhood's public asset API, replays every
`Initialize` log on the V4 pool manager that pairs one of those tokens (or USDG) with a currency we care
about, reads each pool's live in-range liquidity out of the singleton, and shortlists the deepest few per
pair. It does NOT pick a winner: `liquidity` is denominated in each pool's own currencies, so an
ETH-quoted pool and a USDG-quoted one are not comparable, and a fat 5% pool loses to a thin 0.05% one.

`PickDividendRoutes.s.sol` settles it by buying a little of every asset through every candidate against
forked state and keeping whichever delivers most. It **broadcasts nothing** and needs no signer — there
is no on-chain route table to write to any more. Its output is
`catalogue.robinhood.mainnet.json`: asset address to route bytes, in the exact wire format
`initializeEarningsAllocation` takes. Paste it into the frontend's payout catalogue.

Re-running is also the catalogue's health check. An asset whose pools have moved reports a different
winner, or none at all — and a shipped entry that can no longer buy its asset is worse than no entry,
because it hands a creator a permanent, unfixable configuration.

## Adding one asset

Narrow the scan and point the picker at the result:

```
uv run script/operations/dividend-routes/discover_xstock_routes.py --only NVDA -o /tmp/nvda.json
DIVIDEND_SWAP_REGISTRY=0x… ROUTES_JSON=/tmp/nvda.json ROUTES_OUT=/tmp/nvda-catalogue.json just pick-dividend-routes
```

`--only` takes ticker symbols or token addresses, comma-separated, and today resolves them against
Robinhood's asset list — an address outside it is refused. The probe is the validation: do not try to
reimplement it in Python, because an approximation of the swap can disagree with the contract it is meant
to be validating.

## The wire format

One `bytes` per asset, decoded by `DividendRouteLib`:

| Route | Meaning |
| --- | --- |
| empty | the asset's permissionless Uniswap V2 pair, subject to the registry's depth threshold |
| `0x04` + `abi.encode(Hop[])` | a Uniswap V4 path from the native coin; each hop is `{currency, fee, tickSpacing, hooks}` and the last `currency` is the asset |
| `0x03` + `token \| fee \| token…` | a Uniswap V3 path from the quote token to the asset, one or two hops |

V4 hops are checked against the pool manager — initialized, non-zero liquidity — which is what catches a
typo in a fee tier or tick spacing before it becomes permanent. A V3 route is checked for shape only:
deriving a V3 pool address needs a factory this contract does not hold, and no chain the feature ships on
has a V3 deployment worth wiring one in for.
