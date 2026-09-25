# Whitelisting quote assets

The direct venue lets a creator launch against an ERC20 instead of native, but only against an asset
`RealmAssetsWhitelist` lists, and a listing is a pool: the approver names the Uniswap pool that prices
the asset, and the contract reads the rate out of it. This directory is where that list of pools comes
from.

```
just discover-whitelist-assets    # re-pick every pool from live state
just whitelist-assets-rh          # list them, then read them back off the chain

just discover-whitelist-assets-rh-testnet         # and the same two steps for 46630
just whitelist-assets-rh-testnet
```

The whitelist proxy comes from the chain's manifest (`ASSETS_WHITELIST`), and the signer must already be
an approver on it — the owner cannot list, so `setApprover` comes first. Listing is two forge runs: the
broadcast, then `--sig 'verify()'`, which re-reads the live chain. That second run is what makes the
recipe mean what it says: a script only ever sees the state its own simulation produced, so a broadcast
that went nowhere — a local fork, an RPC alias whose env var is unset, a proxy that has since been
redeployed — reports success from inside itself and lists nothing. `verify()` fails instead.

`discover_whitelist_assets.py` answers, for each asset mainnet may list, which pool should price it. It
writes `listings.robinhood.mainnet.json`, which `WhitelistRobinhoodAssets` reads and broadcasts — the
arrays it parses, plus `readable` and `rejected` sections that exist for whoever reviews the list and are
never read on chain — and prints every xStock, deepest pool first, marked IN or OUT with its liquidity
tier.

## What mainnet lists

Only two kinds of asset, by policy:

- **USDG**, the reference asset.
- **Robinhood's own stock tokens** (~195), from its asset API (`api.robinhood.com/rhj/assets`, the list
  behind docs.robinhood.com/chain/contracts) — every one with a price pool the contract can read,
  however thin.

Nothing else, however large its market cap; anything listed earlier outside that set is delisted on the
next run. Their address comes from Robinhood, so identity needs no vouching.

Thin pools are listed on purpose. Liquidity is not gated here but shown to creators, as a tier of the
pool's quote-side depth in native: **low** under 10, **ok** from 10 to 50, **deep** above 50 (`TIERS` in
the script, which the frontend mirrors). Accepted cost: a launch prices its opening tick from the quote's
pool live (`liveUnitsPerNativeX18`), so a thin pool's price can be pushed cheaply within the launch
transaction.

## The testnet

Robinhood testnet gets the same file and the same forge script, from a much shorter list: the three
dummy xStocks `DeployDummyXStocks.s.sol` seeds native-quoted V4 pools for, which is all that chain has
worth quoting a launch in. Their addresses are named in the `just` recipe, since nothing off chain
ranks a testnet token — update them there if the dummies are ever redeployed.

Two things work differently there, both forced by the chain rather than chosen. Pools are **probed by
key** (a handful of standard fee/tick-spacing shapes against native, WETH and the V2 pair) instead of
discovered from logs, because that RPC caps `eth_getLogs` at 10k blocks and the chain is 122M blocks
long; a pool at an unusual shape, or behind a hook, would have to be added by hand. And the caller naming
the assets is the whole of the vetting.

## What qualifies as a price pool

- **Uniswap V2, V3 or V4, nothing else.** Robinhood Chain has some forty DEXes and a coin's deepest
  market is often on one of them; `RealmAssetsWhitelist` can only read those three, so a coin whose
  liquidity lives anywhere else simply does not make the list.
- **Quoted in native (or WETH), or in USDG.** The contract prices an asset against native, or against
  one reference asset that is itself listed against native — one hop, no chains. USDG is that
  reference here, and is entry 0 of the generated script for that reason.
- **Live, with liquidity** — all the contract itself demands. `--min-depth` (0 by default) can add a floor
  on the quote side's depth in native.

Of the pools that qualify, the deepest wins. Depth for V3 and V4 is the in-range virtual amount, which a
narrow position inflates. Nothing checks a pool's price against the market any more: a pool seeded at a
made-up price is listed at that price, and only its depth — the tiebreak — keeps it from being picked.

## Keeping the list curated

The list of quote assets is not a one-off. It decides what a creator may launch against, and a coin
that qualified last month can have had its pool drained or moved its liquidity to a DEX the contract
cannot read since. So the same two commands are the maintenance
loop, run as often as the list is worth trusting:

```
just discover-whitelist-assets    # re-pick from live state
git diff script/operations/assets-whitelist/listings.robinhood.mainnet.json   # review
just whitelist-assets-rh          # apply
```

Re-running does three things at once. It **refreshes** every rate, because listing an asset again
overwrites it. It **re-picks** every pool, so a coin whose liquidity has moved gets a different one. And
it **delists**: an asset the previous file listed that no longer qualifies, and that the live whitelist
still prices, comes back as a `Venue.NONE` entry, which is how `setWhitelisted` retires an asset. Without
that last step the whitelist would only ever grow.

The script prints what it is retiring and the IN/OUT table of every xStock; the git diff of the file is the
rest of the review. The delisting candidates come from the file being overwritten, so an asset an
approver listed **by hand** — never in a generated file — is invisible to this and has to be retired by
hand too.

The stored rate is a **snapshot**, read when `WhitelistRobinhoodAssets` runs, out of a pool picked when
the generator ran. Both age, which is the reason to re-run before every broadcast and not only when the
list changes.

The script never trusts the file: it simulates every entry against forked state first and skips the ones
the contract would refuse, so a pool drained since the scan costs one skipped coin rather than the whole
broadcast.
