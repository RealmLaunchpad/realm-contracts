# /// script
# requires-python = ">=3.11"
# dependencies = ["requests", "eth-abi", "eth-utils", "eth-hash[pycryptodome]"]
# ///
"""Pick the assets ETFs may hold, each with its USDG route, and write the file `WhitelistEtfAssets` lists
them from in `RealmEtfAssets`.

NOT the pairs list (`../assets-whitelist`): that one decides what a launch may be QUOTED in, and prices
through native or USDG. An ETF swaps every deposit and redemption through its asset's route, so a route
here is one hookless Uniswap V2/V3/V4 pool against USDG directly, and only deep ones qualify.

The universe is hand-picked: `MAINNET_ETF_ASSETS` on mainnet, `--assets` on the testnet (the recipe passes
the dummies). Per asset, the deepest hookless USDG pool wins, by the pool scan of
`discover_whitelist_assets.py`, reused: depth is the reserve for V2, the in-range virtual amount for V3/V4.
An asset with no such pool is left out, under `rejected`.

The file is a REGISTRY: an asset a previous run listed and this one does not (removed from the table, or
its pool gone) stays, switched off, so `WhitelistEtfAssets` delists it (ETFs stop buying into it; its
route stays, holders still trade out). Removing a ticker from `MAINNET_ETF_ASSETS` is how one is delisted.

Usage:  uv run script/operations/etf-assets/discover_etf_assets.py [--chain testnet --assets 0x…,0x…]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "assets-whitelist"))
import discover_whitelist_assets as w  # noqa: E402

# The mainnet universe: Robinhood rStocks whose deepest USDG pool held >= 1M USDG on its USDG side (in-range
# virtual depth) on 2026-10-23. Address -> ticker; the address comes from Robinhood's asset API.
MAINNET_ETF_ASSETS = {
    "0xaf3d76f1834a1d425780943c99ea8a608f8a93f9": "AAPL",
    "0x05a3d1cd21d0c88145e82600e62e7e496e0f222b": "AMC",
    "0x86923f96303d656e4aa86d9d42d1e57ad2023fdc": "AMD",
    "0x12f190a9f9d7d37a250758b26824b97ce941bf54": "AMZN",
    "0x156e175dd063a8ce274c50654ef40e0032b3fbcf": "AVGO",
    "0xad25ac6c84d497db898fa1e8387bf6af3532a1c4": "BABA",
    "0x6330d8c3178a418788df01a47479c0ce7ccf450b": "COIN",
    "0x4ea005168d7f09a7a0ba9d1def21a479950e44c2": "COST",
    "0xdf0992e440dd0be65bd8439b609d6d4366bf1cb5": "CRCL",
    "0x941ae714ec6d8130c7b75d67160ca08f1e7d11dd": "DELL",
    "0x25c288e6d899b9bc30160965ad9644c67e73be0c": "F",
    "0xc9a981fee1f9dec688bb123ccdecc63d0debfc4e": "GLD",
    "0x1b0e319c6a659f002271b69db8a7df2f911c153e": "GME",
    "0x2e0847e8910a9732eb3fb1bb4b70a580adad4fe3": "GOOGL",
    "0xccee82fe024c36fa15e1005ede3e9e4787e23d09": "HIMS",
    "0xc72b96e0e48ecd4dc75e1e45396e26300bc39681": "INTC",
    "0xc0d6457c16cc70d6790dd43521c899c87ce02f35": "META",
    "0xe93237c50d904957cf27e7b1133b510c669c2e74": "MSFT",
    "0xec262a75e413fafd0df80480274532c79d42da09": "MSTR",
    "0xff080c8ce2e5feadaca0da81314ae59d232d4afd": "MU",
    "0xe0444ef8bf4ed74f74fd73686e2ddf4c1c5591e8": "NFLX",
    "0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec": "NVDA",
    "0x894e1ec2d74ffe5aef8dc8a9e84686accb964f2a": "PLTR",
    "0xd5f3879160bc7c32ebb4dc785f8a4f505888de68": "QQQ",
    "0x05b37fb53a299a1b874a619e1c4c404d52c36f4c": "RDDT",
    "0x92fd66527192e3e61d4ddd13322aa222de86f9b5": "SGOV",
    "0xb90a19ff0af67f7779aff50a882a9cff42446400": "SNDK",
    "0x4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea": "SPCX",
    "0x117cc2133c37b721f49de2a7a74833232b3b4c0c": "SPY",
    "0x322f0929c4625ed5bad873c95208d54e1c003b2d": "TSLA",
    "0x58ffe4a942d3885baa22d7520691f611ef09e7aa": "TSM",
    "0x5e81213613b6b86eab4c6c50d718d34359459786": "TTWO",
    "0xa30fa36db767ad9ed3f7a60fc79526fb4d56d344": "USO",
    "0x0594134df3f171a354d9c85ebd65b7a6148f6d09": "VTI",
}

# `RealmEtfAssets.Venue` (NONE, V3, V4, V2), by Uniswap version.
ETF_VENUE = {2: 3, 3: 1, 4: 2}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--chain", choices=sorted(w.CHAINS), default="mainnet")
    parser.add_argument("--assets", default="", help="comma-separated addresses to list INSTEAD of MAINNET_ETF_ASSETS")
    args = parser.parse_args()
    out = Path(__file__).with_name(f"etf-assets.robinhood.{args.chain}.json")
    w._use_chain(args.chain)
    usdg = w.REFERENCE

    named = [a.strip().lower() for a in args.assets.split(",") if a.strip()]
    if not named and w.CHAIN_ID != 4663:
        parser.error("the testnet has no built-in list: pass --assets")
    coins = w._named_coins(named) if named else [{"asset": a, "symbol": s} for a, s in MAINNET_ETF_ASSETS.items()]
    coins = [c for c in coins if c["asset"] != usdg]
    addresses = [c["asset"] for c in coins]
    print(f"scanning pools for {len(addresses)} assets…", file=sys.stderr)
    pools = w.scan_pools(addresses) if w.SCAN_LOGS else w.probe_pools(addresses)
    decimals = w.read_state(pools)

    rows, rejected = [], []
    for coin in coins:
        # reference_rate 1: depth comes back in whole USDG.
        found = [c for c in w.candidates(coin["asset"], pools, decimals, 1.0)
                 if c["quote"] == usdg and c["pool"].get("hooks", w.NATIVE) == w.NATIVE]
        # ponytail: hookless only; a hook may tax or refuse the ETF's swaps. Vet one by hand to allow it.
        if found:
            rows.append(_row(coin, found[0]))
        else:
            rejected.append({"symbol": coin["symbol"], "asset": coin["asset"], "reason": "no hookless USDG pool"})

    old = json.loads(out.read_text()) if out.exists() else {"assets": []}
    listed = {r["asset"] for r in rows}
    dropped = [_old_row(old, i) for i, a in enumerate(old["assets"]) if a not in listed]
    rows.sort(key=lambda r: -r["readable"]["usdgDepth"])
    out.write_text(_render(rows + dropped, rejected) + "\n")

    print(f"\n{len(rows)} IN, {len(dropped)} switched off, wrote {out}", file=sys.stderr)
    for r in rows:
        print(f"  IN  {r['symbol']:<8} {r['readable']['venue']} {r['readable']['usdgDepth']:>14,.0f} USDG", file=sys.stderr)
    for r in rejected:
        print(f"  OUT {r['symbol']:<8} ({r['reason']})", file=sys.stderr)
    for r in dropped:
        print(f"  OFF {r['symbol']:<8} (in the file, no longer qualifies)", file=sys.stderr)
    return 0


def _row(coin: dict, pick: dict) -> dict:
    p = pick["pool"]
    v4 = p["v"] == 4
    return {
        "asset": coin["asset"], "symbol": coin["symbol"], "enabled": True,
        "source": {
            "venue": ETF_VENUE[p["v"]],
            "pool": w.NATIVE if v4 else p["pool"],
            "c0": p["t0"] if v4 else w.NATIVE,
            "c1": p["t1"] if v4 else w.NATIVE,
            "fee": p["fee"] if v4 else 0,
            "ts": p["ts"] if v4 else 0,
            "hooks": w.NATIVE,
        },
        "readable": {"symbol": coin["symbol"], "asset": coin["asset"], "venue": f"v{p['v']}",
                     "usdgDepth": round(pick["depth"]), "priceUsdg": round(1 / pick["rate"], 8)},
    }


def _old_row(old: dict, i: int) -> dict:
    """An entry of the previous file, switched off, its route kept."""
    keys = ("venues", "pools", "currency0", "currency1", "fees", "tickSpacings", "hooks")
    return {"asset": old["assets"][i], "symbol": old["symbols"][i], "enabled": False,
            "source": dict(zip(("venue", "pool", "c0", "c1", "fee", "ts", "hooks"), (old[k][i] for k in keys))),
            "readable": {**old["readable"][i], "usdgDepth": 0}}


def _render(rows: list[dict], rejected: list[dict]) -> str:
    """Parallel arrays: `vm.parseJson` decodes one JSON value per call. `readable`/`rejected` are for review only."""
    s = [r["source"] for r in rows]
    return json.dumps({
        "chainId": w.CHAIN_ID,
        "assets": [r["asset"] for r in rows],
        "symbols": [r["symbol"] for r in rows],
        # true: route + list. false: delist if listed (the route stays).
        "enabled": [r["enabled"] for r in rows],
        "venues": [x["venue"] for x in s],
        "pools": [x["pool"] for x in s],
        "currency0": [x["c0"] for x in s],
        "currency1": [x["c1"] for x in s],
        "fees": [x["fee"] for x in s],
        "tickSpacings": [x["ts"] for x in s],
        "hooks": [x["hooks"] for x in s],
        "readable": [r["readable"] for r in rows],
        "rejected": rejected,
    }, indent=1)


if __name__ == "__main__":
    raise SystemExit(main())
