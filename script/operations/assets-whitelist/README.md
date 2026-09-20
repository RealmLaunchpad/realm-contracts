# Whitelisting quote assets

The direct venue lets a creator launch against an ERC20 instead of native, but only against an asset
`RealmAssetsWhitelist` lists, and a listing is a pool: the approver names the Uniswap pool that prices
the asset, and the contract reads the rate out of it. This directory is where that list of pools comes
from.

```
just discover-whitelist-assets    # re-pick every pool from live state
ASSETS_WHITELIST=0x… just whitelist-assets-rh     # list them

just discover-whitelist-assets-rh-testnet         # and the same two steps for 46630
ASSETS_WHITELIST=0x… just whitelist-assets-rh-testnet
```

`discover_whitelist_assets.py` takes the universe from CoinGecko — every coin it knows to be deployed
on chain 4663, ranked by market cap, since on chain there is no such thing as "the top 300" — and then
answers, for each one, which pool should price it. It writes `listings.robinhood.mainnet.json`, which
`WhitelistRobinhoodAssets` reads and broadcasts — the arrays it parses, plus a `readable` section that
exists for whoever reviews the list and is never read on chain.

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

## Re-run it before every broadcast

The stored rate is a **snapshot**, read when `WhitelistRobinhoodAssets` runs, out of a pool picked when
the generator ran. Both age. Re-running is also how a rate is refreshed later — listing an
asset again overwrites its rate — and how the list self-corrects: a coin whose liquidity has moved gets
a different pool, or drops out.

The script never trusts the file: it simulates every listing against forked state first and skips the
ones the contract would refuse, so a pool drained since the scan costs one skipped coin rather than the
whole broadcast.
