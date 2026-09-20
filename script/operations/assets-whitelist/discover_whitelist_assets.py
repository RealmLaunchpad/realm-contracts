# /// script
# requires-python = ">=3.11"
# dependencies = ["requests", "eth-abi", "eth-utils", "eth-hash[pycryptodome]"]
# ///
"""Pick the Uniswap pool that prices each of Robinhood Chain's biggest coins, and write the file
`WhitelistRobinhoodAssets` lists them from.

The whitelist stores a SNAPSHOT of each asset's rate, read from one pool the approver names, so the
only question this script answers is: for every coin worth listing, which pool should that be? A pool
qualifies when it is Uniswap V2, V3 or V4 (nothing else -- the contract refuses every other venue),
when its other side is native/WETH or the chain's reference asset (itself listed against native), when
it holds real depth, and when its price agrees with the coin's market price. Of those, the deepest
wins.

How it works:
  1. CoinGecko for the universe: every coin it lists with a Robinhood Chain deployment, ranked by
     market cap, with its USD price. On-chain there is no such thing as "the top 300" -- anyone can
     deploy a token, so the ranking has to come from off chain. `--assets` replaces this with a list
     given by the caller, which is how the testnet is done: nothing there is ranked or priced anywhere,
     so the price check is skipped and naming the assets IS the vetting.
  2. The chain for the pools: `PairCreated`, `PoolCreated` and `Initialize` logs, filtered to those
     coins, then Uniswap's own state (reserves / slot0 + liquidity) read through Multicall3. Where the
     RPC will not serve a log scan (the testnet caps `eth_getLogs` at 10k blocks), pools are instead
     probed by key at a handful of standard shapes.
  3. Depth as the tiebreak, measured as the quote-side amount at the current price, converted to
     native so a reference-quoted pool and an ETH-quoted one compare. For V3 and V4 that is the
     in-range virtual amount, which overstates a narrow position -- hence the price check, which is
     what actually catches a pool seeded at a made-up price.

Output: `listings.robinhood.<chain>.json`, which `WhitelistRobinhoodAssets` reads and broadcasts.
Review it, and re-run before listing: the stored rate is a snapshot, and a coin whose liquidity has
moved gets a different pool, or drops off the list.

Usage:  uv run script/operations/assets-whitelist/discover_whitelist_assets.py [--chain testnet …]
        The chain's RPC env var (`ROBINHOOD_RPC_URL` / `ROBINHOOD_TESTNET_RPC_URL`) must point at an
        archive-capable node: the mainnet log scan walks the whole chain.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import requests
from eth_abi import decode as abi_decode
from eth_abi import encode as abi_encode
from eth_utils import keccak

NATIVE = "0x" + "00" * 20
MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11"

# Per chain: the Uniswap deployments to read, and the one REFERENCE asset — a coin whose main liquidity
# is against it is listed against it, and it is itself listed against native, which is the single hop
# the contract allows. `None` where the venue or the reference does not exist on that chain.
CHAINS = {
    "mainnet": {
        "chain_id": 4663,
        "rpc_env": "ROBINHOOD_RPC_URL",
        "rpc_default": "https://rpc.mainnet.chain.robinhood.com",
        "weth": "0x0bd7d308f8e1639fab988df18a8011f41eacad73",
        "reference": "0x5fc5360d0400a0fd4f2af552add042d716f1d168",  # USDG
        "univ2_factory": "0x8bceaa40b9acdfaedf85adf4ff01f5ad6517937f",
        "univ3_factory": "0x1f7d7550b1b028f7571e69a784071f0205fd2efa",
        "pool_manager": "0x8366a39cc670b4001a1121b8f6a443a643e40951",
        "scan_logs": True,
    },
    # The testnet has no CoinGecko universe to rank and no reference asset worth the name, so it is only
    # ever run with `--assets`: the dummy dividend xStocks, each in its own native-quoted V4 pool.
    # Its RPC also caps `eth_getLogs` at 10k blocks, which is 12,000 queries per filter over a chain this
    # long, so pools are probed by key instead of discovered from logs.
    "testnet": {
        "chain_id": 46630,
        "rpc_env": "ROBINHOOD_TESTNET_RPC_URL",
        "rpc_default": "https://rpc.testnet.chain.robinhood.com",
        "weth": "0x7943e237c7f95da44e0301572d358911207852fa",
        "reference": None,
        "univ2_factory": "0x7766e3a6a8c98a76308cfb4040e330c3308f7c73",
        "univ3_factory": None,
        "pool_manager": "0x552815ef68e6eb418a3d65d0aa1043d93204f612",
        "scan_logs": False,
    },
}

# Set from `CHAINS` by `main`, before anything reads the chain.
CHAIN_ID = RPC = WETH = REFERENCE = UNIV2_FACTORY = UNIV3_FACTORY = POOL_MANAGER = SCAN_LOGS = None
NATIVE_SIDE: set[str] = set()

TOPIC_V2 = "0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9"  # PairCreated
TOPIC_V3 = "0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118"  # PoolCreated
TOPIC_V4 = "0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438"  # Initialize

# v4-core `PoolManager.pools` is slot 6; a pool's `liquidity` sits 3 words into its state, `slot0` at 0.
POOLS_SLOT, LIQUIDITY_OFFSET = 6, 3
# v4 encodes a hook's permissions in its address. This one lets the hook replace the swap curve, which
# would leave `slot0` describing a price nothing actually trades at.
BEFORE_SWAP_RETURNS_DELTA = 1 << 3
Q96 = 1 << 96

CG = "https://api.coingecko.com/api/v3"
CG_PAUSE = 8  # the free tier rejects anything faster
HTTP_TIMEOUT = 180
SESSION = requests.Session()
SESSION.headers["user-agent"] = "realm-assets-whitelist"

OUT_JSON = Path(__file__).with_name("listings.robinhood.mainnet.json")


def selector(signature: str) -> str:
    return "0x" + keccak(text=signature)[:4].hex()


def coingecko(path: str, params: dict) -> list:
    for attempt in range(10):
        try:
            r = SESSION.get(f"{CG}/{path}", params=params, timeout=HTTP_TIMEOUT)
            if r.status_code == 200:
                return r.json()
        except requests.RequestException:
            pass
        time.sleep(CG_PAUSE * (attempt + 1))
    raise SystemExit(f"CoinGecko gave up on {path}")


def universe(cache: Path, max_age: float = 3600) -> list[dict]:
    """Every CoinGecko coin deployed on Robinhood Chain, market-cap first, with its USD price.

    Cached for an hour, no longer: the prices in it are what every pool's price is checked against, so a
    day-old copy quietly rejects any coin the market has moved since. The hour is there for the retry
    after a failed run — the free tier takes ~6 minutes to serve this."""
    if cache.exists() and time.time() - cache.stat().st_mtime < max_age:
        print(f"universe from {cache.name} (delete it to refetch)", file=sys.stderr)
        return json.loads(cache.read_text())

    coins = coingecko("coins/list", {"include_platform": "true"})
    address_of = {c["id"]: c["platforms"]["robinhood"].lower() for c in coins if c["platforms"].get("robinhood")}
    print(f"{len(address_of)} coins with a Robinhood Chain deployment", file=sys.stderr)

    ids = sorted(address_of)
    markets = []
    for i in range(0, len(ids), 150):
        markets += coingecko("coins/markets", {"vs_currency": "usd", "ids": ",".join(ids[i : i + 150]), "per_page": 250})
        print(f"  market caps {min(i + 150, len(ids))}/{len(ids)}", file=sys.stderr)
        time.sleep(CG_PAUSE)

    # No market cap means CoinGecko cannot vouch for the supply, so the coin cannot be ranked at all.
    ranked = sorted((m for m in markets if m.get("market_cap") and m.get("current_price")), key=lambda m: -m["market_cap"])
    coins = [
        {"asset": address_of[m["id"]], "symbol": m["symbol"].upper(), "mcap": m["market_cap"], "price": m["current_price"]}
        for m in ranked
        if address_of[m["id"]] != WETH  # the direct venue refuses wrapped native as a quote
    ]
    cache.write_text(json.dumps(coins))
    return coins


def rpc(method: str, params: list) -> dict:
    for attempt in range(8):
        try:
            body = SESSION.post(RPC, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, timeout=HTTP_TIMEOUT).json()
            if "result" in body or "error" in body:
                return body
        except (requests.RequestException, ValueError):
            pass
        time.sleep(2 * (attempt + 1))
    raise SystemExit(f"RPC gave up on {method}")


def logs(address: str, topics: list, lo: int, hi: int) -> list[dict]:
    """Every matching log, halving the range whenever the node refuses to serve it in one answer."""
    answer = rpc("eth_getLogs", [{"address": address, "topics": topics, "fromBlock": hex(lo), "toBlock": hex(hi)}])
    if "error" not in answer:
        return answer["result"]
    if hi <= lo:
        raise SystemExit(f"RPC will not serve block {lo}: {answer['error']}")
    mid = (lo + hi) // 2
    return logs(address, topics, lo, mid) + logs(address, topics, mid + 1, hi)


def as_address(word: str) -> str:
    return "0x" + word[-40:]


def as_int24(word: str) -> int:
    v = int(word[-6:], 16)
    return v - (1 << 24) if v >= (1 << 23) else v


def scan_pools(assets: list[str]) -> list[dict]:
    """Every Uniswap V2/V3/V4 pool pairing one of `assets` with native, WETH or the reference asset.

    The topic filter carries the assets, never WETH or the reference: filtering on those would match
    every pool on the chain (they are one side of almost all of them) and download hundreds of megabytes
    of logs to throw away. The reference's own native pools are the one exception, and get a query of
    their own with BOTH currency positions pinned."""
    latest = int(rpc("eth_blockNumber", [])["result"], 16)
    # Never in the chunked filter, or the scan pulls in every reference pair on the chain (~170k of them
    # on mainnet) only to keep the handful that pair with a coin it is already asking about.
    assets = [a for a in assets if a not in quotable()]
    words = lambda log, n: [log["data"][2:][i * 64 : (i + 1) * 64] for i in range(n)]
    pools, seen = [], set()

    def keep(pool: dict) -> None:
        key = pool.get("id") or pool["pool"]
        if key in seen:
            return
        seen.add(key)
        pools.append(pool)

    def collect(venue: int, batch: list[dict]) -> None:
        for log in batch:
            if venue == 4:
                t0, t1, w = as_address(log["topics"][2]), as_address(log["topics"][3]), words(log, 5)
                keep({"v": 4, "t0": t0, "t1": t1, "fee": int(w[0], 16), "ts": as_int24(w[1]),
                      "hooks": as_address(w[2]), "id": log["topics"][1]})
            else:
                t0, t1, w = as_address(log["topics"][1]), as_address(log["topics"][2]), words(log, 2)
                pool = {"v": venue, "t0": t0, "t1": t1, "pool": as_address(w[venue - 2])}
                if venue == 3:
                    pool["fee"] = int(log["topics"][3], 16)
                keep(pool)

    topic = lambda a: "0x" + a[2:].rjust(64, "0")
    for i in range(0, len(assets), 100):
        chunk = [topic(a) for a in assets[i : i + 100]]
        for position in (1, 2):  # the asset as token0, then as token1
            collect(2, logs(UNIV2_FACTORY, [TOPIC_V2] + [chunk if p == position else None for p in (1, 2)], 0, latest))
            if UNIV3_FACTORY:
                collect(3, logs(UNIV3_FACTORY, [TOPIC_V3] + [chunk if p == position else None for p in (1, 2)], 0, latest))
            collect(4, logs(POOL_MANAGER, [TOPIC_V4, None] + [chunk if p == position else None for p in (1, 2)], 0, latest))
        print(f"  scanned {min(i + 100, len(assets))}/{len(assets)} assets ({len(pools)} pools)", file=sys.stderr)

    if REFERENCE:
        quotes, reference = [topic(a) for a in (NATIVE, WETH)], [topic(REFERENCE)]
        collect(2, logs(UNIV2_FACTORY, [TOPIC_V2, quotes, reference], 0, latest))
        if UNIV3_FACTORY:
            collect(3, logs(UNIV3_FACTORY, [TOPIC_V3, quotes, reference], 0, latest))
        collect(4, logs(POOL_MANAGER, [TOPIC_V4, None, quotes, reference], 0, latest))
    return [p for p in pools if p["t0"] in quotable() or p["t1"] in quotable()]


# What a probed V4 pool can look like: the fee/tick-spacing pairs Uniswap's own interface offers, plus
# the two shapes `DeployDummyXStocks` mirrors off Robinhood's live xStock pools. Probing only finds
# hookless pools, which is all a chain without a log scan is expected to hold.
PROBE_SHAPES = ((100, 1), (500, 10), (3000, 60), (10000, 200), (50000, 1000))


def probe_pools(assets: list[str]) -> list[dict]:
    """The pools of `assets` found by asking for them by key, one guess at a time.

    For chains whose RPC will not serve a log scan. It can only find what it guesses: a hookless V4 pool
    at one of `PROBE_SHAPES`, or the single V2 pair the factory records. Anything else has to be listed
    by hand."""
    probes, calls = [], []
    for asset in assets:
        for quote in sorted(quotable()):
            if quote == asset:
                continue
            t0, t1 = sorted((asset, quote))  # a PoolKey's currencies are address-ordered; native sorts first
            for fee, ts in PROBE_SHAPES:
                pool_id = "0x" + keccak(
                    abi_encode(["(address,address,uint24,int24,address)"], [(t0, t1, fee, ts, NATIVE)])
                ).hex()
                probes.append({"v": 4, "t0": t0, "t1": t1, "fee": fee, "ts": ts, "hooks": NATIVE, "id": pool_id})
                calls.append((POOL_MANAGER, selector("extsload(bytes32)") + _v4_slots(pool_id)[0]))

    pairs = [
        (UNIV2_FACTORY, selector("getPair(address,address)") + abi_encode(["address", "address"], [a, WETH]).hex())
        for a in assets
    ]
    results = multicall(calls + pairs)

    pools = []
    for key, (ok, ret) in zip(probes, results[: len(calls)]):
        if ok and len(ret) >= 32 and int.from_bytes(ret[:32], "big") % (1 << 160) != 0:  # initialized
            pools.append(key)
    for asset, (ok, ret) in zip(assets, results[len(calls) :]):
        pair = as_address(ret.hex()) if ok and len(ret) == 32 else NATIVE
        if pair != NATIVE:
            t0, t1 = sorted((asset, WETH))
            pools.append({"v": 2, "t0": t0, "t1": t1, "pool": pair})
    return pools


def _v4_slots(pool_id: str) -> tuple[str, str]:
    base = int.from_bytes(keccak(bytes.fromhex(pool_id[2:]) + POOLS_SLOT.to_bytes(32, "big")), "big")
    return f"{base:064x}", f"{(base + LIQUIDITY_OFFSET) % (1 << 256):064x}"


def multicall(calls: list[tuple[str, str]], chunk: int = 400) -> list[tuple[bool, bytes]]:
    out = []
    for i in range(0, len(calls), chunk):
        part = calls[i : i + chunk]
        data = selector("aggregate3((address,bool,bytes)[])") + abi_encode(
            ["(address,bool,bytes)[]"], [[(to, True, bytes.fromhex(d[2:])) for to, d in part]]
        ).hex()
        answer = rpc("eth_call", [{"to": MULTICALL3, "data": data}, "latest"])
        if "error" in answer:
            raise SystemExit(f"multicall failed: {answer['error']}")
        out += abi_decode(["(bool,bytes)[]"], bytes.fromhex(answer["result"][2:]))[0]
        print(f"  read {i + len(part)}/{len(calls)}", file=sys.stderr)
    return out


def read_state(pools: list[dict]) -> dict[str, int]:
    """Annotate every pool with its live price and size, and return each token's decimals."""
    tokens = sorted(({p["t0"] for p in pools} | {p["t1"] for p in pools}) - {NATIVE})
    decimals = {NATIVE: 18}  # the native coin has no contract to ask
    for token, (ok, ret) in zip(tokens, multicall([(t, selector("decimals()")) for t in tokens])):
        decimals[token] = int.from_bytes(ret, "big") if ok and len(ret) == 32 else None

    calls = []
    for p in pools:
        if p["v"] == 2:
            calls.append((p["pool"], selector("getReserves()")))
        elif p["v"] == 3:
            calls += [(p["pool"], selector("slot0()")), (p["pool"], selector("liquidity()"))]
        else:
            slot0, liquidity = _v4_slots(p["id"])
            calls += [(POOL_MANAGER, selector("extsload(bytes32)") + slot0), (POOL_MANAGER, selector("extsload(bytes32)") + liquidity)]

    results, i = multicall(calls), 0
    for p in pools:
        if p["v"] == 2:
            ok, ret = results[i]
            i += 1
            if ok and len(ret) >= 64:
                p["r0"] = int.from_bytes(ret[:32], "big") & ((1 << 112) - 1)
                p["r1"] = int.from_bytes(ret[32:64], "big") & ((1 << 112) - 1)
        else:
            (ok_price, price), (ok_liquidity, liquidity) = results[i], results[i + 1]
            i += 2
            if ok_price and len(price) >= 32:
                p["sqrtP"] = int.from_bytes(price[:32], "big") & ((1 << 160) - 1)  # slot0 packs it in the low bits
            if ok_liquidity and len(liquidity) >= 32:
                p["L"] = int.from_bytes(liquidity[:32], "big") & ((1 << 128) - 1)
    return decimals


def quotable() -> set[str]:
    """What a listing's other side may be: native, WETH, and the reference asset where there is one."""
    return NATIVE_SIDE | ({REFERENCE} if REFERENCE else set())


def candidates(asset: str, pools: list[dict], decimals: dict, reference_rate: float) -> list[dict]:
    """Every pool that could price `asset`, deepest first.

    Depth is the quote side's whole-unit amount at the current price, in native. For V2 that is the
    reserve; for V3 and V4 it is the in-range virtual amount, which is what a swap crossing no tick
    boundary trades against."""
    out = []
    for p in pools:
        if asset not in (p["t0"], p["t1"]):
            continue
        quote = p["t1"] if p["t0"] == asset else p["t0"]
        quote = NATIVE if quote in NATIVE_SIDE else quote
        if quote not in ({NATIVE, REFERENCE} if REFERENCE else {NATIVE}) or asset == quote:
            continue
        d0, d1 = decimals.get(p["t0"]), decimals.get(p["t1"])
        if d0 is None or d1 is None:
            continue
        if p["v"] == 4 and int(p["hooks"], 16) & BEFORE_SWAP_RETURNS_DELTA:
            continue  # a custom-curve hook trades at a price of its own, so slot0 is not one
        if p["v"] == 2:
            if not (p.get("r0") and p.get("r1")):
                continue
            a0, a1 = p["r0"], p["r1"]
        else:
            if not (p.get("L") and p.get("sqrtP")):
                continue
            a0, a1 = p["L"] * Q96 // p["sqrtP"], p["L"] * p["sqrtP"] // Q96
        a0, a1 = a0 / 10**d0, a1 / 10**d1
        if a0 <= 0 or a1 <= 0:
            continue
        # Whole assets per whole quote, and the quote side's size.
        per_quote, size = (a0 / a1, a1) if p["t0"] == asset else (a1 / a0, a0)
        rate, depth = (per_quote, size) if quote == NATIVE else (per_quote * reference_rate, size / reference_rate)
        if rate <= 0:
            continue
        out.append({"pool": p, "quote": quote, "rate": rate, "depth": depth})
    return sorted(out, key=lambda c: -c["depth"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--chain", choices=sorted(CHAINS), default="mainnet")
    parser.add_argument("--assets", default="", help="comma-separated addresses to list INSTEAD of "
                        "CoinGecko's ranking. The only mode the testnet has: nothing there has a market "
                        "price, so the price check is skipped and the caller vouches for the assets.")
    parser.add_argument("--limit", type=int, default=300, help="how many coins to list, market cap first")
    parser.add_argument("--min-depth", type=float, default=10.0, help="quote-side depth a pool needs, in native")
    parser.add_argument("--tolerance", type=float, default=0.15, help="how far a pool's price may sit from CoinGecko's")
    parser.add_argument("--universe-cache", type=Path, default=Path(__file__).with_name(".universe.cache.json"),
                        help="where the CoinGecko ranking is kept; delete it to refetch")
    parser.add_argument("--json", type=Path, default=None)
    args = parser.parse_args()
    out = args.json or Path(__file__).with_name(f"listings.robinhood.{args.chain}.json")
    _use_chain(args.chain)

    named = [a.strip().lower() for a in args.assets.split(",") if a.strip()]
    coins = _named_coins(named) if named else universe(args.universe_cache)
    print(f"scanning pools for {len(coins)} {'assets' if named else 'coins'}…", file=sys.stderr)
    addresses = [c["asset"] for c in coins]
    pools = scan_pools(addresses) if SCAN_LOGS else probe_pools(addresses)
    print(f"{len(pools)} pools; reading state…", file=sys.stderr)
    decimals = read_state(pools)

    by_token: dict[str, list[dict]] = {}
    for p in pools:
        for side in (p["t0"], p["t1"]):
            by_token.setdefault(side, []).append(p)

    listings, reference_rate = [], 1.0
    if REFERENCE:
        # The reference first: every pool quoted in it is priced through its rate, and on chain it must
        # be listed before the coins that name it. It takes its deepest native pool and skips the depth
        # and price filters — with nothing listed yet there is nothing to price it against.
        priced = [c for c in candidates(REFERENCE, by_token.get(REFERENCE, []), decimals, 1.0) if c["quote"] == NATIVE]
        if not priced:
            raise SystemExit("the reference asset has no native pool — nothing can be listed against it")
        reference_rate = priced[0]["rate"]
        known = {c["asset"]: c for c in coins}
        listings = [{**known.get(REFERENCE, {"asset": REFERENCE, "symbol": "REF", "mcap": 0, "price": None}), **priced[0]}]
        print(f"reference: {reference_rate:,.2f} per native, {priced[0]['depth']:,.0f} native deep, "
              f"v{priced[0]['pool']['v']}", file=sys.stderr)

    skipped = []
    for coin in coins:
        if len(listings) >= args.limit:
            break
        if coin["asset"] == REFERENCE:
            continue
        priced = [
            c
            for c in candidates(coin["asset"], by_token.get(coin["asset"], []), decimals, reference_rate)
            if c["depth"] >= args.min_depth and _priced_right(c, coin, reference_rate, args.tolerance)
        ]
        if priced:
            listings.append({**coin, **priced[0]})
        else:
            skipped.append(coin["symbol"])

    out.write_text(render(listings, reference_rate) + "\n")
    print(f"wrote {len(listings)} listings to {out}", file=sys.stderr)
    if skipped:
        print(f"{len(skipped)} had no qualifying Uniswap pool: {', '.join(skipped[:10])}"
              f"{'…' if len(skipped) > 10 else ''}", file=sys.stderr)
    return 0


def _use_chain(name: str) -> None:
    """Point the module at one chain's Uniswap deployment. Called once, before anything reads it."""
    global CHAIN_ID, RPC, WETH, REFERENCE, UNIV2_FACTORY, UNIV3_FACTORY, POOL_MANAGER, SCAN_LOGS, NATIVE_SIDE
    c = CHAINS[name]
    CHAIN_ID, WETH, REFERENCE, SCAN_LOGS = c["chain_id"], c["weth"], c["reference"], c["scan_logs"]
    UNIV2_FACTORY, UNIV3_FACTORY, POOL_MANAGER = c["univ2_factory"], c["univ3_factory"], c["pool_manager"]
    RPC = os.environ.get(c["rpc_env"]) or c["rpc_default"]
    NATIVE_SIDE = {NATIVE, WETH}


def _named_coins(assets: list[str]) -> list[dict]:
    """The `--assets` stand-in for a CoinGecko ranking: symbols off the chain, no market cap, no price."""
    symbols = multicall([(a, selector("symbol()")) for a in assets])
    out = []
    for asset, (ok, ret) in zip(assets, symbols):
        try:
            symbol = abi_decode(["string"], bytes(ret))[0] if ok and len(ret) > 32 else asset[:8]
        except Exception:
            symbol = asset[:8]
        out.append({"asset": asset, "symbol": symbol, "mcap": 0, "price": None})
    return out


def _priced_right(candidate: dict, coin: dict, reference_rate: float, tolerance: float) -> bool:
    """Does the pool quote the coin near its market price? Vacuously true for a coin that has none."""
    if not coin.get("price"):
        return True
    return 1 / (1 + tolerance) <= (reference_rate / candidate["rate"]) / coin["price"] <= 1 + tolerance


def render(listings: list[dict], reference_rate: float) -> str:
    """The file `WhitelistRobinhoodAssets` reads.

    Two halves: the arrays the forge script parses (one entry per listing, same order), and `readable`,
    which is there for the human reviewing the list and is never read on chain. Parallel arrays rather
    than an array of structs because `vm.parseJson` can only decode one JSON value at a time."""
    keys = [l["pool"] for l in listings]
    reference = listings[0]["symbol"] if REFERENCE else None
    return json.dumps(
        {
            "chainId": CHAIN_ID,
            # Whole reference units per native, the rate every reference-quoted listing prices through.
            "reference": reference,
            "referencePerNative": round(reference_rate, 6) if REFERENCE else None,
            "assets": [l["asset"] for l in listings],
            "symbols": [l["symbol"] for l in listings],  # labels for the script's log, nothing more
            # The contract's `Venue` enum, not the Uniswap version: NONE, V2, V3, V4.
            "venues": [k["v"] - 1 for k in keys],
            "pools": [k.get("pool") or NATIVE for k in keys],  # the V2 pair or V3 pool; zero for V4
            "currency0": [k["t0"] if k["v"] == 4 else NATIVE for k in keys],
            "currency1": [k["t1"] if k["v"] == 4 else NATIVE for k in keys],
            "fees": [k["fee"] if k["v"] == 4 else 0 for k in keys],
            "tickSpacings": [k["ts"] if k["v"] == 4 else 0 for k in keys],
            "hooks": [k["hooks"] if k["v"] == 4 else NATIVE for k in keys],
            "readable": [
                {
                    "symbol": l["symbol"],
                    "asset": l["asset"],
                    "marketCapUsd": round(l["mcap"]),
                    "venue": f'v{l["pool"]["v"]}',
                    "quote": "native" if l["quote"] == NATIVE else reference,
                    "depthNative": round(l["depth"], 4),
                    # Priced in the reference asset, which on a chain that has one is a dollar stablecoin.
                    "priceUsd": round(reference_rate / l["rate"], 8) if REFERENCE else None,
                    "perNative": round(l["rate"], 8),
                    "coingeckoUsd": l["price"],
                }
                for l in listings
            ],
        },
        indent=1,
    )


if __name__ == "__main__":
    raise SystemExit(main())
