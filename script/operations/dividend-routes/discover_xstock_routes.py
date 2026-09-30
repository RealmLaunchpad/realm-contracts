# /// script
# requires-python = ">=3.11"
# dependencies = ["requests", "eth-abi", "eth-utils", "eth-hash[pycryptodome]"]
# ///
"""Discover the Uniswap V4 and V3 routes from native ETH to every Robinhood Chain stock token, plus
the fixed route to each Arcus pToken.

Robinhood Chain's ~190 xStocks have no Uniswap V2 pair at all: their liquidity lives in V4, most
of it in a pool against native ETH and the rest against USDG. `RealmDividendSwapRegistry` cannot
measure a V4 asset the way it measures a long-tail ERC20 -- a V4 pool is identified by a
(fee, tickSpacing, hooks) tuple that is not derivable from its two currencies, and one pair can
have hundreds of pools, most of them somebody's dust. This script finds the real ones, on chain,
and emits the candidates `PickDividendRoutes.s.sol` probes.

How it picks: it replays the pool manager's `Initialize` log for every pool that pairs a stock
token with native ETH or with USDG, reads each pool's live in-range liquidity, and shortlists the
deepest few of each. It does NOT pick a winner between them -- `liquidity` is denominated in the
pool's own currencies, so the number for an ETH-quoted pool and the number for a USDG-quoted one
are not the same kind of thing, and a fat pool charging 5% still loses to a thin one charging
0.05%. Choosing between shortlisted candidates is `PickDividendRoutes.s.sol`'s job: it buys the
asset through each of them against forked state and keeps whichever actually delivers most.

V3 is shortlisted too: some xStocks' only live ETH market is a Uniswap V3 WETH pool (SPCX, whose V4
pools are drained). Those candidates are single-hop WETH -> stock, one per fee tier holding in-range
liquidity, already in wire format under `v3Candidates`. The router executes V3 against the factory
below, and the registry checks a V3 route for shape only, so the probe is what proves the pool is live.

Arcus's leveraged pTokens (`ARCUS`) are not discovered: each trades in exactly one V4 pool against
USDG behind an Arcus hook, so its one candidate is fixed -- native -> USDG over `USDG_HOP`, then USDG ->
pToken over its Arcus pool. No liquidity read gates it (Arcus pools can read 0 in range while swaps
fill); the probe is what says whether it takes a full conversion.

Output is a JSON file that forge script reads. Review it before broadcasting -- this is the one
place a wrong answer silently sends a token's dividends through somebody else's pool.

Usage:  uv run script/operations/dividend-routes/discover_xstock_routes.py [-o out.json]
        … --only arcus -o /tmp/arcus.json      the Arcus pTokens alone, no chain scan
        ROBINHOOD_RPC_URL overrides the public RPC.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import requests
from eth_abi import encode as abi_encode
from eth_utils import keccak

RPC = os.environ.get("ROBINHOOD_RPC_URL") or "https://rpc.mainnet.chain.robinhood.com"
ASSETS_API = "https://api.robinhood.com/rhj/assets"
CHAIN_ID = 4663

POOL_MANAGER = "0x8366a39CC670B4001A1121B8F6A443A643e40951"
# The Uniswap V3 factory the Universal Router swaps against on this chain.
V3_FACTORY = "0x1f7d7550B1b028f7571E69A784071F0205FD2EfA"
V3_FEES = (100, 500, 3000, 10000)
GET_POOL_SELECTOR = "0x1698ee82"  # getPool(address,address,uint24)
LIQUIDITY_SELECTOR = "0x1a686502"  # liquidity()
USDG = "0x5fc5360d0400a0fd4f2af552add042d716f1d168"
WETH = "0x0bd7d308f8e1639fab988df18a8011f41eacad73"
NATIVE = "0x" + "00" * 20

# The native/USDG leg every Arcus candidate starts with: the USDG/native V4 pool the xStock two-hop
# candidates are built on (dynamic fee flag, 0x800000), pinned rather than re-ranked per run.
USDG_HOP = {"currency": USDG, "fee": 0x800000, "tickSpacing": 10, "hooks": "0x06a889870c8f83640d6816319f72e2aa579b6080"}

# Arcus's leveraged pTokens: address -> (ticker, hook, lpFee), each in one USDG pool at tick spacing 10.
# These are the rows enabled by default in `assets-whitelist/discover_whitelist_assets.py`, whose table
# holds all 11 (flagged) and cross-checks them against Arcus's API
# (api.arcus.xyz/v1/api-meta/spot/overview); keep the two in step.
ARCUS_TICK_SPACING = 10
_ARCUS_HOOK_A = "0xfa3da20ec661aa26f9f93e4421fab6989c4b4800"
_ARCUS_HOOK_B = "0xf28a89af20fabdb89af9d033bb0a98d17212c880"
# Only the DEEP ones are listed (a 1 ETH buy through native -> USDG -> pToken moves the price < 2%).
# Left out, measured 2026-09-30: pBTC, sBTC, sBTC3x (5-9% at 1 ETH, ~70% at 3 ETH) and sSPCX3x, sGME5x,
# sGLD5x (about one token for sale: any buy over ~$100 reverts). Re-measure before adding one back.
ARCUS = {
    "0xe24cabdf76dd1c2576049167eb1755c84b985c36": ("pHOOD3x", _ARCUS_HOOK_A, 8500),
    "0x8b9d2eb675e33e541cb7de25a55724d2e70e8dab": ("pSPCX3x", _ARCUS_HOOK_B, 4250),
    "0x4472c69d299382f8847ebce4fc6ed8e295510e3e": ("pBTC3x", _ARCUS_HOOK_A, 8500),
    "0x5c3b9a9b021e86b54202abcb4580f1f5c271875b": ("pGME5x", _ARCUS_HOOK_B, 4250),
    "0x37a2afaa98648f2e13658623885f821ac8365609": ("pGLD5x", _ARCUS_HOOK_B, 4250),
}

# keccak("Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)").
# topics = [sig, poolId, currency0, currency1]; data = fee, tickSpacing, hooks, sqrtPriceX96, tick.
INITIALIZE_TOPIC = "0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438"
# v4-core `PoolManager.pools` lives at slot 6; a pool's `liquidity` is 3 words into its state.
POOLS_SLOT = 6
LIQUIDITY_OFFSET = 3
EXTSLOAD_SELECTOR = "0x1e2eaeaf"

# The public RPC times a log query out well before it hits its 10k-result cap, so the scan walks
# the chain in windows and halves any window that times out rather than giving up on it.
INITIAL_WINDOW = 500_000
MIN_WINDOW = 25_000
# The public RPC starts 429ing above ~50 calls in one batch, and the scan is long enough already
# that a rejected batch costs more than a smaller one does.
LIQUIDITY_BATCH = 25
BATCH_PAUSE = 0.1

# How many pools to shortlist per pair. The probe in the forge script costs one simulated swap per
# candidate, so this trades a slower dry run for a better chance the real venue is among them.
CANDIDATES_PER_PAIR = 2
HTTP_TIMEOUT = 180
SESSION = requests.Session()
SESSION.headers["user-agent"] = "realm-dividend-routes"


def rpc(method: str, params: list, retries: int = 8) -> dict:
    """One JSON-RPC call. Retries anything that is not a well-formed answer -- the public RPC hands
    out 429s and 5xx under a scan, and a body with neither `result` nor `error` reads as a hiccup
    rather than an answer."""
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    last = ""
    for attempt in range(retries):
        try:
            r = SESSION.post(RPC, json=payload, timeout=HTTP_TIMEOUT)
            if r.status_code == 200:
                body = r.json()
                if "result" in body or "error" in body:
                    return body
            last = f"HTTP {r.status_code}: {r.text[:200]}"
        except (requests.RequestException, ValueError) as exc:
            last = repr(exc)
        time.sleep(2 * (attempt + 1))
    raise SystemExit(f"RPC gave up on {method} -- {last}")


def rpc_batch(calls: list[dict], retries: int = 8) -> list[dict]:
    """A JSON-RPC batch, same retry posture as `rpc`. Falls back to one call at a time if the node
    refuses batches outright."""
    last = ""
    for attempt in range(retries):
        try:
            r = SESSION.post(RPC, json=calls, timeout=HTTP_TIMEOUT)
            if r.status_code == 200:
                body = r.json()
                if isinstance(body, list) and len(body) == len(calls):
                    return body
                if isinstance(body, dict):
                    return [dict(rpc(c["method"], c["params"]), id=c["id"]) for c in calls]
            last = f"HTTP {r.status_code}: {r.text[:200]}"
        except (requests.RequestException, ValueError) as exc:
            last = repr(exc)
        time.sleep(2 * (attempt + 1))
    raise SystemExit(f"RPC gave up on a batch of {len(calls)} -- {last}")


def topic(address: str) -> str:
    return "0x" + address.lower().removeprefix("0x").rjust(64, "0")


def stock_tokens() -> list[tuple[str, str]]:
    """(symbol, address) for every Robinhood stock token deployed on this chain."""
    data = SESSION.get(ASSETS_API, timeout=HTTP_TIMEOUT).json()
    out = []
    for asset in data["assets"]:
        for dep in asset.get("deployments", []):
            if dep.get("chainId") == CHAIN_ID:
                out.append((asset["tokenSymbol"], dep["contractAddress"].lower()))
    return sorted(set(out))


def decode_initialize(log: dict) -> dict:
    words = [log["data"][2:][i * 64 : (i + 1) * 64] for i in range(3)]

    def as_int24(word: str) -> int:
        v = int(word[-6:], 16)
        return v - (1 << 24) if v >= (1 << 23) else v

    return {
        "id": log["topics"][1],
        "currency0": "0x" + log["topics"][2][-40:],
        "currency1": "0x" + log["topics"][3][-40:],
        "fee": int(words[0], 16),
        "tickSpacing": as_int24(words[1]),
        "hooks": "0x" + words[2][-40:],
    }


def scan_pools(wanted: set[str], routable: set[str]) -> list[dict]:
    """Every V4 pool whose BOTH currencies are routable, over the whole chain.

    The log filter can only match one topic position at a time, so the second side is filtered here.
    Matching only one would keep every USDG/anything pool on the chain -- tens of thousands of them,
    since anyone can initialize a pool -- and reading liquidity for those would dominate the run
    without answering anything."""
    latest = int(rpc("eth_blockNumber", [])["result"], 16)
    wanted_topics = [topic(a) for a in sorted(wanted)]
    pools, start, window = {}, 0, INITIAL_WINDOW
    while start <= latest:
        end = min(start + window - 1, latest)
        failed = False
        for position in (2, 3):  # currency0, then currency1
            topics = [INITIALIZE_TOPIC, None, None, None]
            topics[position] = wanted_topics
            res = rpc(
                "eth_getLogs",
                [{"address": POOL_MANAGER, "topics": topics, "fromBlock": hex(start), "toBlock": hex(end)}],
            )
            if "error" in res:
                failed = True
                break
            for log in res["result"]:
                pool = decode_initialize(log)
                if {pool["currency0"], pool["currency1"]} <= routable:
                    pools[pool["id"]] = pool
        if failed:
            if window <= MIN_WINDOW:
                print(f"  ! skipping blocks {start}-{end}: RPC will not serve them", file=sys.stderr)
                start = end + 1
            else:
                window //= 2
            continue
        print(f"  scanned to {end} ({len(pools)} pools)", file=sys.stderr)
        start = end + 1
        window = min(window * 2, INITIAL_WINDOW)
    return list(pools.values())


def read_liquidity(pools: list[dict]) -> None:
    """Annotate each pool with its live in-range liquidity, read straight out of the singleton."""
    for start in range(0, len(pools), LIQUIDITY_BATCH):
        batch = pools[start : start + LIQUIDITY_BATCH]
        calls = []
        for i, pool in enumerate(batch):
            state = keccak(bytes.fromhex(pool["id"][2:]) + POOLS_SLOT.to_bytes(32, "big"))
            slot = (int.from_bytes(state, "big") + LIQUIDITY_OFFSET) % (1 << 256)
            calls.append(
                {
                    "jsonrpc": "2.0",
                    "id": i,
                    "method": "eth_call",
                    "params": [{"to": POOL_MANAGER, "data": EXTSLOAD_SELECTOR + f"{slot:064x}"}, "latest"],
                }
            )
        for answer in rpc_batch(calls):
            batch[answer["id"]]["liquidity"] = int(answer.get("result") or "0x0", 16)
        time.sleep(BATCH_PAUSE)
        if start % (LIQUIDITY_BATCH * 20) == 0:
            print(f"  liquidity {start}/{len(pools)}", file=sys.stderr)


def deepest(pools: list[dict], a: str, b: str, limit: int = 1) -> list[dict]:
    """The `limit` deepest live pools for the `a`/`b` pair, deepest first.

    Ranking by `liquidity` is only meaningful WITHIN one pair, where every pool measures depth in the
    same two currencies. Across pairs it is meaningless, which is why this never compares an
    ETH-quoted pool with a USDG-quoted one -- the probe in the forge script does that."""
    matching = [p for p in pools if {p["currency0"], p["currency1"]} == {a, b} and p["liquidity"] > 0]
    return sorted(matching, key=lambda p: p["liquidity"], reverse=True)[:limit]


def as_hop(pool: dict, currency: str) -> dict:
    return {
        "currency": currency,
        "fee": pool["fee"],
        "tickSpacing": pool["tickSpacing"],
        "hooks": pool["hooks"],
    }


def eth_calls(calls: list[tuple[str, str]]) -> list[str]:
    """`eth_call` results for (to, data) pairs, batched like the V4 liquidity reads."""
    out = []
    for start in range(0, len(calls), LIQUIDITY_BATCH):
        batch = [
            {"jsonrpc": "2.0", "id": i, "method": "eth_call", "params": [{"to": to, "data": data}, "latest"]}
            for i, (to, data) in enumerate(calls[start : start + LIQUIDITY_BATCH])
        ]
        answers = sorted(rpc_batch(batch), key=lambda a: a["id"])
        out += [a.get("result") or "0x" for a in answers]
        time.sleep(BATCH_PAUSE)
    return out


def v3_routes(tokens: list[str]) -> dict[str, list[dict]]:
    """Per stock, its WETH V3 pools holding in-range liquidity, deepest first, capped like V4.

    Liquidity is comparable here: every pool of one pair measures it in the same two tokens."""
    pairs = [(t, fee) for t in tokens for fee in V3_FEES]
    pools = eth_calls(
        [(V3_FACTORY, GET_POOL_SELECTOR + abi_encode(["address", "address", "uint24"], [WETH, t, f]).hex()) for t, f in pairs]
    )
    live = [(t, f, "0x" + p[-40:]) for (t, f), p in zip(pairs, pools) if len(p) >= 66 and int(p, 16)]
    liquidity = eth_calls([(pool, LIQUIDITY_SELECTOR) for _, _, pool in live])
    found: dict[str, list[dict]] = {}
    for (t, f, pool), liq in zip(live, liquidity):
        if len(liq) > 2 and int(liq, 16) > 0:
            found.setdefault(t, []).append({"fee": f, "pool": pool, "liquidity": int(liq, 16)})
    return {t: sorted(v, key=lambda p: p["liquidity"], reverse=True)[:CANDIDATES_PER_PAIR] for t, v in found.items()}


def v3_wire(token: str, fee: int) -> str:
    """`DividendRouteLib` V3 route: 0x03, then the packed WETH | fee | token path."""
    return "0x03" + WETH[2:] + f"{fee:06x}" + token[2:]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-o",
        "--out",
        type=Path,
        default=Path(__file__).with_name("routes.robinhood.mainnet.json"),
    )
    parser.add_argument(
        "--cache",
        type=Path,
        default=Path(__file__).with_name(".pools.cache.json"),
        help="where the raw pool scan is kept; delete it (or pass --rescan) to walk the chain again",
    )
    parser.add_argument("--rescan", action="store_true")
    parser.add_argument(
        "--only",
        default="",
        help="comma-separated ticker symbols or token addresses to route (xStocks or Arcus pTokens; "
        "`arcus` names every Arcus pToken); everything else is left out of the output. Use it to add "
        "ONE new asset without regenerating the whole file -- write it somewhere of its own with -o "
        "and point ROUTES_JSON at that.",
    )
    args = parser.parse_args()

    tokens = stock_tokens()
    arcus = [(symbol, a) for a, (symbol, _, _) in ARCUS.items()]
    print(f"{len(tokens)} stock tokens and {len(arcus)} Arcus pTokens on chain {CHAIN_ID}", file=sys.stderr)

    if args.only:
        picked = {w.strip().lower() for w in args.only.split(",") if w.strip()}
        chosen = lambda t: t[0].lower() in picked or t[1] in picked
        tokens = [t for t in tokens if chosen(t)]
        arcus = [t for t in arcus if chosen(t) or "arcus" in picked]
        named = tokens + arcus
        missing = picked - {"arcus"} - {t[0].lower() for t in named} - {t[1] for t in named}
        if missing:
            print(f"not a stock token or Arcus pToken on this chain: {', '.join(sorted(missing))}", file=sys.stderr)
            return 1
        print(f"--only: {', '.join(t[0] for t in named)}", file=sys.stderr)

    assets, candidates, v3_candidates, readable, skipped = [], [], [], [], []

    def emit(symbol: str, token: str, routes: list[list[dict]], v3_pools: list[dict], **extra) -> None:
        assets.append(token)
        candidates.append(
            "0x"
            + abi_encode(
                ["(address,uint24,int24,address)[][]"],
                [[[(h["currency"], h["fee"], h["tickSpacing"], h["hooks"]) for h in r] for r in routes]],
            ).hex()
        )
        v3_candidates.append(
            "0x" + abi_encode(["bytes[]"], [[bytes.fromhex(v3_wire(token, p["fee"])[2:]) for p in v3_pools]]).hex()
        )
        readable.append({"symbol": symbol, "asset": token, **extra, "candidates": routes, "v3": v3_pools})

    # An `--only` naming nothing but Arcus pTokens has nothing to scan for.
    if tokens:
        _stock_routes(args, tokens, emit, skipped)
    for symbol, token in arcus:
        _, hooks, fee = ARCUS[token]
        hop = {"currency": token, "fee": fee, "tickSpacing": ARCUS_TICK_SPACING, "hooks": hooks}
        emit(symbol, token, [[USDG_HOP, hop]], [], arcus=True)

    args.out.write_text(
        json.dumps(
            {
                "chainId": CHAIN_ID,
                "assets": assets,
                # Flat, for forge: `parseJson` refuses a `[*]` path that yields more than one value.
                "symbols": [r["symbol"] for r in readable],
                "candidates": candidates,
                "v3Candidates": v3_candidates,
                "readable": readable,
            },
            indent=2,
        )
        + "\n"
    )
    total = sum(len(r["candidates"]) + len(r["v3"]) for r in readable)
    print(f"wrote {len(assets)} assets / {total} candidate routes to {args.out}", file=sys.stderr)
    if skipped:
        print(f"no pool found for {len(skipped)}: {', '.join(skipped)}", file=sys.stderr)
    return 0


def _stock_routes(args, tokens: list[tuple[str, str]], emit, skipped: list[str]) -> None:
    """The xStocks' candidates, discovered on chain, handed to `emit` one asset at a time."""
    print("collecting V4 pools…", file=sys.stderr)
    stocks = {a for _, a in tokens}
    # The scan's topic filter narrows with `--only`, so adding one asset does not replay the pools of
    # the other 190. The cache is keyed to the whole chain, though, so a narrowed scan must not
    # overwrite it -- an `--only` run always walks the chain fresh and keeps its findings to itself.
    # The scan is several minutes of public-RPC time and its answer only grows, so it is cached. The
    # LIQUIDITY read below is never cached — that is the number that moves.
    if args.cache.exists() and not args.rescan and not args.only:
        pools = json.loads(args.cache.read_text())
        print(f"{len(pools)} pools from {args.cache} (--rescan to walk the chain again)", file=sys.stderr)
    else:
        pools = scan_pools(stocks | {USDG}, stocks | {NATIVE, WETH, USDG})
        if not args.only:
            args.cache.write_text(json.dumps(pools))
    print(f"{len(pools)} candidate pools; reading liquidity…", file=sys.stderr)
    read_liquidity(pools)

    print("collecting V3 pools…", file=sys.stderr)
    v3 = v3_routes(sorted(stocks))

    # Every two-hop candidate shares this leg, so it is shortlisted once.
    usdg_legs = deepest(pools, NATIVE, USDG, CANDIDATES_PER_PAIR)
    if not usdg_legs:
        print("no native/USDG pool with liquidity — cannot build two-hop candidates", file=sys.stderr)

    for symbol, token in tokens:
        routes = [[as_hop(p, token)] for p in deepest(pools, NATIVE, token, CANDIDATES_PER_PAIR)]
        for hop in deepest(pools, USDG, token, CANDIDATES_PER_PAIR):
            if usdg_legs:
                routes.append([as_hop(usdg_legs[0], USDG), as_hop(hop, token)])
        v3_pools = v3.get(token, [])
        if not routes and not v3_pools:
            skipped.append(symbol)
            continue
        emit(symbol, token, routes, v3_pools)


if __name__ == "__main__":
    raise SystemExit(main())
