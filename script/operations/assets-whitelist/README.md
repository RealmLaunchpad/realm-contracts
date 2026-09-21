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

`discover_whitelist_assets.py` takes the universe from CoinGecko — every coin it knows to be deployed
on chain 4663, ranked by market cap, since on chain there is no such thing as "the top 300" — and then
answers, for each one, which pool should price it. It writes `listings.robinhood.mainnet.json`, which
`WhitelistRobinhoodAssets` reads and broadcasts — the arrays it parses, plus `readable` and `rejected`
sections that exist for whoever reviews the list and are never read on chain.

## Robinhood's own xStocks

The ~195 stock tokens Robinhood issues on this chain come from its own asset API
(`api.robinhood.com/rhj/assets`) and are considered **on top of** the market-cap ranking, exempt from
`--limit`. They have to be: a stock token with a $15k on-chain float ranks below several hundred
memecoins, and market cap is not what should decide whether the chain's flagship assets can quote a
launch. A handful of them are not on CoinGecko at all, so there is no market price to check their pool
against — their address comes from Robinhood rather than from a ranking, so identity needs no vouching,
and `--min-depth` is the only filter they face.

Thin ones are still refused, which is the point: an xStock whose deepest Uniswap pool holds less than
`--min-depth` of native does not get listed, and the `rejected` section of the output says so with the
depth it measured. That section is the list to review when retuning the threshold.

## The testnet

Robinhood testnet gets the same file and the same forge script, from a much shorter list: the three
dummy xStocks `DeployDummyXStocks.s.sol` seeds native-quoted V4 pools for, which is all that chain has
worth quoting a launch in. Their addresses are named in the `just` recipe, since nothing off chain
ranks a testnet token — update them there if the dummies are ever redeployed.

Two things work differently there, both forced by the chain rather than chosen. Pools are **probed by
key** (a handful of standard fee/tick-spacing shapes against native, WETH and the V2 pair) instead of
discovered from logs, because that RPC caps `eth_getLogs` at 10k blocks and the chain is 122M blocks
long; a pool at an unusual shape, or behind a hook, would have to be added by hand. And the **price
check does not apply** — a dummy has no market price to compare against — so the caller naming the
assets is the whole of the vetting.

## What qualifies as a price pool

- **Uniswap V2, V3 or V4, nothing else.** Robinhood Chain has some forty DEXes and a coin's deepest
  market is often on one of them; `RealmAssetsWhitelist` can only read those three, so a coin whose
  liquidity lives anywhere else simply does not make the list. That is most of the difference between
  CoinGecko's top 300 and this file.
- **Quoted in native (or WETH), or in USDG.** The contract prices an asset against native, or against
  one reference asset that is itself listed against native — one hop, no chains. USDG is that
  reference here, and is entry 0 of the generated script for that reason.
- **Deep enough, and priced right.** A pool must hold at least `--min-depth` (10 by default) of native
  on the quote side at the current price, and must price the coin within `--tolerance` (15%) of its
  market price. The price check is the one that matters: depth for V3 and V4 is measured as the
  in-range virtual amount, which a narrow position inflates, while a pool seeded at a made-up price
  fails the comparison outright no matter how it was funded.

Of the pools that qualify, the deepest wins.

## Keeping the list curated

The list of quote assets is not a one-off. It decides what a creator may launch against, and a coin
that qualified last month can have had its pool drained, moved its liquidity to a DEX the contract
cannot read, or drifted away from its market price since. So the same two commands are the maintenance
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

The script prints what it is retiring and which xStocks did not make it; the git diff of the file is the
rest of the review. The delisting candidates come from the file being overwritten, so an asset an
approver listed **by hand** — never in a generated file — is invisible to this and has to be retired by
hand too.

The stored rate is a **snapshot**, read when `WhitelistRobinhoodAssets` runs, out of a pool picked when
the generator ran. Both age, which is the reason to re-run before every broadcast and not only when the
list changes.

The script never trusts the file: it simulates every entry against forked state first and skips the ones
the contract would refuse, so a pool drained since the scan costs one skipped coin rather than the whole
broadcast.
