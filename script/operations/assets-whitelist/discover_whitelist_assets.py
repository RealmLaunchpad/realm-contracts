# /// script
# requires-python = ">=3.11"
# dependencies = ["requests", "eth-abi", "eth-utils", "eth-hash[pycryptodome]"]
# ///
"""Pick the Uniswap pool that prices USDG, each of Robinhood's own rStocks and each Arcus pToken, and
write the file `WhitelistRobinhoodAssets` lists them from.

The whitelist stores a SNAPSHOT of each asset's rate, read from one pool the approver names, so the
only question this script answers is: for every asset worth listing, which pool should that be? A pool
qualifies when it is Uniswap V2, V3 or V4 (nothing else -- the contract refuses every other venue) and
its other side is native/WETH or the chain's reference asset (itself listed against native). Of those,
the deepest wins.

How it works:
  1. The universe is policy: USDG (the reference) plus Robinhood's own ~195 rStocks, from its asset
     API -- the list behind docs.robinhood.com/chain/contracts. Every one with a pool is listed, however
     thin: liquidity is shown to creators as a low/ok/deep tier rather than gated here. Plus Arcus's
     leveraged pTokens (`ARCUS`), whose pool is fixed, so they skip steps 2-3 (see `ARCUS`). Plus a
     hand-picked list of memecoins (`MEMECOINS`), discovered and ranked like the rStocks.
     `--assets` replaces the universe with a list given by the caller, which is how the testnet is done.
  2. The chain for the pools: `PairCreated`, `PoolCreated` and `Initialize` logs, filtered to those
     assets, then Uniswap's own state (reserves / slot0 + liquidity) read through Multicall3. Where the
     RPC will not serve a log scan (the testnet caps `eth_getLogs` at 10k blocks), pools are instead
     probed by key at a handful of standard shapes.
  3. Depth as the tiebreak, measured as the quote-side amount at the current price, converted to
     native so a reference-quoted pool and an ETH-quoted one compare. For V3 and V4 that is the
     in-range virtual amount, which overstates a narrow position.
  4. Curation, in both directions. The file is a REGISTRY: it keeps every asset any run ever found a
     pool for, each with an `enabled` flag, and never forgets one. `WhitelistRobinhoodAssets` lists the
     enabled entries and retires the disabled ones the chain still prices, so the same file brings a
     fresh whitelist to the full list and empties a live one of what fell off it. A full run switches
     OFF what no longer qualifies; it never switches anything back ON -- that is `--enable`'s job, so a
     hand-made choice survives every later run.

Subset runs (`--only`, `--assets`) re-pick only the assets they name. Every other entry of the existing
file is carried over unchanged, flag included: only a FULL run knows what fell out of the policy, so
only a full run switches an entry off. A named asset that no longer qualifies keeps its previous entry
too. `--enable` / `--disable` flip flags in the existing file and touch nothing else, chain included.

Output: `listings.robinhood.<chain>.json`, which `WhitelistRobinhoodAssets` reads and broadcasts.
Review it, and re-run before listing: the stored rate is a snapshot, and a coin whose liquidity has
moved gets a different pool. Its `rejected` section says why every asset that did not make it was left
out.

Usage:  uv run script/operations/assets-whitelist/discover_whitelist_assets.py [--chain testnet …]
        … --only arcus            re-pick the Arcus pTokens only (also takes tickers / addresses)
        … --disable pBTC3x --enable CBBTC     flip `enabled` by ticker or address, no chain access
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
    # The testnet has no Robinhood rStocks, so it is only ever run with `--assets`: the dummy dividend
    # rStocks, each in its own native-quoted V4 pool, plus the dummies `DeployDummyUsdgPair` pairs with
    # the dummy USDG only — hence that USDG as the reference.
    # Its RPC also caps `eth_getLogs` at 10k blocks, which is 12,000 queries per filter over a chain this
    # long, so pools are probed by key instead of discovered from logs.
    "testnet": {
        "chain_id": 46630,
        "rpc_env": "ROBINHOOD_TESTNET_RPC_URL",
        "rpc_default": "https://rpc.testnet.chain.robinhood.com",
        "weth": "0x7943e237c7f95da44e0301572d358911207852fa",
        "reference": "0xd2397fd59c825e6f34037ff2f2f541b0b727eb24",  # dummy USDG (18 decimals)
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
# Realm's own `RealmHookAnyPair` (mainnet, testnet): it sets that bit only to take its fee in the swap
# delta, never to replace the curve, so `slot0` is still the traded price.
FEE_ONLY_HOOKS = {"0x24d9308561c322a603370a0c3bead39e05da00cc", "0x87f077ebbe1d9d35d5e4522bf0a4e30adaaf40cc"}
Q96 = 1 << 96

# Robinhood's public list of its own stock tokens, and where their addresses come from.
RSTOCKS_API = "https://api.robinhood.com/rhj/assets"
HTTP_TIMEOUT = 180
SESSION = requests.Session()
SESSION.headers["user-agent"] = "realm-assets-whitelist"

OUT_JSON = Path(__file__).with_name("listings.robinhood.mainnet.json")

# Arcus's leveraged pTokens (mainnet only): address -> (ticker, hook, lpFee, enabled by default). Their only market is one
# Uniswap V4 pool against USDG behind an Arcus hook, at tick spacing 10, so the pool is policy rather
# than discovered and no depth ranking applies. Their in-range liquidity can read 0 while swaps fill
# (the price parks between Arcus's bid and ask ranges), which is why nothing here gates on it. The
# API below is Arcus's own list (entries named "Arcus …"): it decides which of these are still offered,
# but carries no pool, so a pToken it adds has to be added here by hand. The table in
# `dividend-routes/discover_rstock_routes.py` holds the ones enabled here.
ARCUS_API = "https://api.arcus.xyz/v1/api-meta/spot/overview"
ARCUS_TICK_SPACING = 10
_ARCUS_HOOK_A = "0xfa3da20ec661aa26f9f93e4421fab6989c4b4800"
_ARCUS_HOOK_B = "0xf28a89af20fabdb89af9d033bb0a98d17212c880"
# The default flag is only the FIRST run's answer: once an entry is in the file, its flag there wins.
# On by default are the DEEP ones (a 1 ETH buy through native -> USDG -> pToken moves the price < 2%).
# Off, measured 2026-09-30: pBTC, sBTC, sBTC3x (5-9% at 1 ETH, ~70% at 3 ETH) and sSPCX3x, sGME5x,
# sGLD5x (about one token for sale: any buy over ~$100 reverts). Re-measure before enabling one.
ARCUS = {
    "0xe24cabdf76dd1c2576049167eb1755c84b985c36": ("pHOOD3x", _ARCUS_HOOK_A, 8500, True),
    "0x8b9d2eb675e33e541cb7de25a55724d2e70e8dab": ("pSPCX3x", _ARCUS_HOOK_B, 4250, True),
    "0x17271bd2a1eaa350a002d25236bcc4dc07ceb6a9": ("sSPCX3x", _ARCUS_HOOK_B, 4250, False),
    "0x4472c69d299382f8847ebce4fc6ed8e295510e3e": ("pBTC3x", _ARCUS_HOOK_A, 8500, True),
    "0x1a596466cb593bee293be8366d9ce493582189c2": ("sGME5x", _ARCUS_HOOK_B, 4250, False),
    "0x5c3b9a9b021e86b54202abcb4580f1f5c271875b": ("pGME5x", _ARCUS_HOOK_B, 4250, True),
    "0xb2cb7371bc45a460f856712a3088c23acd385df8": ("sGLD5x", _ARCUS_HOOK_B, 4250, False),
    "0x37a2afaa98648f2e13658623885f821ac8365609": ("pGLD5x", _ARCUS_HOOK_B, 4250, True),
    "0x925f92f055edb79c42b5d45e64a1b74143b90ea0": ("pBTC", _ARCUS_HOOK_A, 8500, False),
    "0xadcceee8e422050f890522fa798f8a93a4857083": ("sBTC3x", _ARCUS_HOOK_A, 8500, False),
    "0xc25c966168a8e933b0aba0dc8a25cac4a2b2b91d": ("sBTC", _ARCUS_HOOK_A, 8500, False),
}

# Hand-picked Robinhood-chain memecoins (mainnet only): address -> ticker. Picked 2026-09-30 from the coins
# the frontend has a logo for (`frontend-next/public/imgs/memecoins/`), deepest Uniswap pools first. Unlike
# the Arcus pTokens their pool is discovered and ranked like an rStock's. Identity is vouched for HERE:
# re-check an address before adding it, a copycat token can share any ticker. Checked 2026-09-30: each is
# its ticker's top-24h-volume token on DexScreener (lookalikes had ~$0), and a 1 ETH buy through its listed
# pool moves the price < 2% (`MeasureQuoteImpact.s.sol`). Rejected then: DOGO, HOOD (46% / 9% impact at
# 0.1 ETH, dead volume), SQUEEZE (hooked pool, every buy reverts).
MEMECOINS = {
    "0x39dbed3a2bd333467115de45665cc57f813c4571": "PONS",
    "0x2e8c31162b855a2ffa90f6f8634643ad6f111e18": "AI",
    "0x020bfc650a365f8bb26819deaabf3e21291018b4": "CASHCAT",
    "0x5cb6f181081301b44905f3ae15419112ecabd8a6": "PIPEDOG",
    "0x812486eaea648819853f8e372dc9f1516c7868bd": "UBIK",
    "0x56910d4409f3a0c78c64dd8d0545ff0705389870": "INDEX",
    "0xe8ffd7e24187f72afb08d75b1bb13088a989a791": "DELTA",
    "0xe934e36a439c94017b64a3fece66af12099abf50": "STONKBROKER",
    "0xaa07a0e9209e16ac99708c3ec70159c6ef3128a3": "ORBIO",
    "0xd9db30bb0d2b8d2eae3826a1372117e058791e18": "MOO",
    "0x45242320dbb855eea8fd36804c6487e10e97fcf9": "TENDIES",
    "0x7dbf38976f6d3b9c529e7d9484a71898b409ee6a": "ZZZ",
    "0xab093def657f15df31b33922a95e047add645b29": "SHROOM",
    "0x91a2dae9699f0b82540b5886b0d8759c22820ba3": "MUSEBOOK",
    "0x07ebb29a38fbcb41563817e5e19f2cec619c90d2": "BUN",
    "0x98096d17e191b3da1d5f99a6d7b3584351b11e18": "BONER",
    "0x18e674231a58c239dc7daedcffe15ec3a24cff5c": "HOOKR",
    "0x7fe995a80075df3dc8ae11a9b82c7fe4202cd87f": "HMM",
    "0x83a49b808f8d5e02cb2931cd2352988f498e5ba3": "AGRIPPA",
    "0xb9972ca7188e511174947e3936a5315ac7073277": "PROLOGUE",
    "0x451b42a15100c340ca12f7c66de06fac5ea2d751": "BOW",
    "0x20024e485c0b22b42855589700721b28320a7777": "PRISM",
    "0xd7321801caae694090694ff55a9323139f043b88": "JUGGERNAUT",
    "0x57c0e45cb534413d1c20a4240955d6bb250bb4f1": "UP",
}

# Bridge-stocks shares (mainnet only): address -> ticker. Their USDG pools sit behind `RealmHookAnyPair`,
# seeded by the `bridge-stocks` presales. Discovered and ranked like an rStock.
BRIDGE_STOCKS = {
    "0x56ae4a01bc41c4054662cd467e1b8c144d19b1bf": "HOOD1X",
    "0xc73b24a207c4eae3686edf6a3fcf21843bdbe7c0": "OPENAI",
    "0xf33507de3aa3c1386cee1ecfa2882b0b2930b305": "ANTHROPIC",
}


def selector(signature: str) -> str:
    return "0x" + keccak(text=signature)[:4].hex()


def rstocks() -> dict[str, str]:
    """Robinhood's own stock tokens on this chain, address to ticker, from its public asset list.

    With USDG, the only assets mainnet lists. Their identity needs no vouching: the address comes from
    Robinhood."""
    data = SESSION.get(RSTOCKS_API, timeout=HTTP_TIMEOUT).json()
    return {
        deployment["contractAddress"].lower(): asset["tokenSymbol"]
        for asset in data["assets"]
        for deployment in asset.get("deployments", [])
        if deployment.get("chainId") == CHAIN_ID
    }


def arcus() -> dict[str, dict]:
    """The Arcus pTokens, address to `{symbol, pool, enabled}`, each with its fixed USDG pool.

    `ARCUS` intersected with what Arcus's API still offers; the whole table when the API cannot be read
    or names none of them, so an outage never reads as "switch everything off". Empty off mainnet."""
    if CHAIN_ID != 4663:
        return {}
    try:
        offered = {e["contractAddress"].lower(): e["ticker"] for e in SESSION.get(ARCUS_API, timeout=30).json()
                   if str(e.get("name", "")).startswith("Arcus ")}
    except (requests.RequestException, ValueError, KeyError, TypeError, AttributeError) as exc:
        print(f"Arcus API unreadable ({exc!r}); using the built-in list", file=sys.stderr)
        offered = {}
    if unknown := sorted(set(offered) - set(ARCUS)):
        print(f"! Arcus offers {', '.join(offered[a] for a in unknown)} with no known pool: add to `ARCUS` to list",
              file=sys.stderr)
    kept = [a for a in ARCUS if a in offered] if set(offered) & set(ARCUS) else list(ARCUS)
    if gone := [ARCUS[a][0] for a in ARCUS if a not in kept]:
        print(f"! no longer offered by Arcus, left out: {', '.join(gone)}", file=sys.stderr)
    out = {}
    for asset in kept:
        symbol, hooks, fee, enabled = ARCUS[asset]
        t0, t1 = sorted((asset, REFERENCE))  # a PoolKey's currencies are address-ordered
        pool_id = "0x" + keccak(abi_encode(["(address,address,uint24,int24,address)"],
                                           [(t0, t1, fee, ARCUS_TICK_SPACING, hooks)])).hex()
        out[asset] = {"symbol": symbol, "enabled": enabled, "pool": {"v": 4, "t0": t0, "t1": t1, "fee": fee,
                                                 "ts": ARCUS_TICK_SPACING, "hooks": hooks, "id": pool_id}}
    return out


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
# the two shapes `DeployDummyRStocks` mirrors off Robinhood's live rStock pools. Probing only finds
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
        if p["v"] == 4 and int(p["hooks"], 16) & BEFORE_SWAP_RETURNS_DELTA and p["hooks"] not in FEE_ONLY_HOOKS:
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


def arcus_listing(asset: str, pool: dict, decimals: dict, reference_rate: float) -> dict | None:
    """An Arcus pToken's listing out of its fixed pool, or None if that pool is not initialized.

    The rate comes from the price alone, not from `candidates`' virtual amounts, because in-range
    liquidity can be 0 on a pool that trades. Depth is still reported where there is any, else None
    ("n/a" in the tier column)."""
    sqrt_p, d0, d1 = pool.get("sqrtP"), decimals.get(pool["t0"]), decimals.get(pool["t1"])
    if not sqrt_p or d0 is None or d1 is None:
        return None
    price = (sqrt_p / Q96) ** 2 * 10 ** (d0 - d1)  # whole t1 per whole t0
    per_reference = 1 / price if pool["t0"] == asset else price
    depth = None
    if pool.get("L"):
        a0, a1 = pool["L"] * Q96 // sqrt_p / 10**d0, pool["L"] * sqrt_p // Q96 / 10**d1
        depth = (a1 if pool["t0"] == asset else a0) / reference_rate
    return {"pool": pool, "quote": REFERENCE, "rate": per_reference * reference_rate, "depth": depth}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--chain", choices=sorted(CHAINS), default="mainnet")
    parser.add_argument("--assets", default="", help="comma-separated addresses to list INSTEAD of "
                        "USDG + the rStocks. The only mode the testnet has; the caller vouches for them.")
    parser.add_argument("--only", default="", help="comma-separated tickers or addresses out of the policy "
                        "(USDG, the rStocks, the Arcus pTokens, the memecoins; `arcus` / `memecoins` name all "
                        "of those) to re-pick. Every "
                        "other entry of the existing file is carried over unchanged, its flag included.")
    parser.add_argument("--enable", default="", help="comma-separated tickers or addresses already in the file "
                        "to switch ON. With --disable: flips the flags, writes the file, reads no chain.")
    parser.add_argument("--disable", default="", help="the same, to switch OFF (retired on the next broadcast)")
    parser.add_argument("--min-depth", type=float, default=0.0, help="quote-side depth a pool needs, in native")
    parser.add_argument("--json", type=Path, default=None)
    args = parser.parse_args()
    if args.assets and args.only:
        parser.error("--assets and --only are two ways of naming a subset: pass one")
    out = args.json or Path(__file__).with_name(f"listings.robinhood.{args.chain}.json")
    _use_chain(args.chain)
    if args.enable or args.disable:
        return toggle(out, args.enable, args.disable)

    fixed = arcus()
    named = [a.strip().lower() for a in args.assets.split(",") if a.strip()]
    if named:
        coins = _named_coins(named)
    else:
        coins = [{"asset": a, "symbol": s, "rstock": True} for a, s in sorted(rstocks().items())]
        print(f"{len(coins)} Robinhood rStocks, {len(fixed)} Arcus pTokens", file=sys.stderr)
        coins += [{"asset": a, "symbol": f["symbol"]} for a, f in fixed.items()]
        memes = MEMECOINS if CHAIN_ID == 4663 else {}
        coins += [{"asset": a, "symbol": s, "memecoin": True} for a, s in memes.items()]
        coins += [{"asset": a, "symbol": s} for a, s in (BRIDGE_STOCKS if CHAIN_ID == 4663 else {}).items()]
        if args.only:
            coins = _only(coins, args.only)
            if coins is None:
                return 1
    for coin in coins:
        if coin["asset"] in fixed:
            coin.update(symbol=fixed[coin["asset"]]["symbol"], arcus=True, enabled=fixed[coin["asset"]]["enabled"])
    subset = bool(named or args.only)
    # Arcus pools are fixed, so they are read rather than scanned for.
    addresses = [c["asset"] for c in coins if not c.get("arcus")]
    print(f"scanning pools for {len(addresses)} {'assets' if subset else 'coins'}…", file=sys.stderr)
    # A probe only finds what it is asked for, and the reference's native pool prices everything else.
    pools = scan_pools(addresses) if SCAN_LOGS else probe_pools(sorted({*addresses, *([REFERENCE] if REFERENCE else [])}))
    print(f"{len(pools)} pools; reading state…", file=sys.stderr)
    decimals = read_state(pools + [fixed[c["asset"]]["pool"] for c in coins if c.get("arcus")])

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
        listings = [{**_named_coins([REFERENCE])[0], **priced[0]}]
        print(f"reference: {reference_rate:,.2f} per native, {priced[0]['depth']:,.0f} native deep, "
              f"v{priced[0]['pool']['v']}", file=sys.stderr)

    rejected = []
    for coin in coins:
        if coin["asset"] == REFERENCE:
            continue
        if coin.get("arcus"):
            listing = arcus_listing(coin["asset"], fixed[coin["asset"]]["pool"], decimals, reference_rate)
            if listing:
                listings.append({**coin, **listing})
            else:
                rejected.append({"symbol": coin["symbol"], "asset": coin["asset"], "rstock": False, "arcus": True,
                                 "reason": "its Arcus pool is not initialized", "venue": "v4", "depthNative": 0.0})
            continue
        found = candidates(coin["asset"], by_token.get(coin["asset"], []), decimals, reference_rate)
        priced = [c for c in found if c["depth"] >= args.min_depth]
        if priced:
            listings.append({**coin, **priced[0]})
        else:
            rejected.append(_rejection(coin, found, args))

    reference = listings[0]["symbol"] if REFERENCE else None
    rows = [_row(l, reference_rate, reference) for l in listings]
    old = _previous(out)
    # A flag already in the file outlives the run: the default only answers for an asset's first entry.
    was_enabled = {r["asset"]: r["enabled"] for r in old["rows"]}
    for row in rows:
        row["enabled"] = was_enabled.get(row["asset"], row["enabled"])
    if subset:
        rows, kept_rejected, carried = carry_over(old, rows, rejected, {c["asset"] for c in coins})
        switched_off = []
        out.write_text(render(rows, reference_rate, kept_rejected, old) + "\n")
        print(f"subset run: re-picked {len(rows) - carried}, carried {carried} existing entries over "
              f"unchanged, switched nothing off; wrote {len(rows)} entries to {out}", file=sys.stderr)
    else:
        # The registry half: what this run did not find a pool for stays in the file, switched off.
        found = {r["asset"] for r in rows}
        dropped = [{**r, "enabled": False} for r in old["rows"] if r["asset"] not in found]
        switched_off = [r for r in dropped if was_enabled[r["asset"]]]
        rows += dropped
        out.write_text(render(rows, reference_rate, rejected, old) + "\n")
        print(f"wrote {len(rows)} entries to {out}: {sum(r['enabled'] for r in rows)} enabled, "
              f"{len(switched_off)} switched off by this run", file=sys.stderr)
    # This run's verdicts only: a subset run's carried-over rejections are in the file, not re-reported.
    _report(rejected, switched_off, [r for r in rows if not r["enabled"] and r["asset"] in {l["asset"] for l in listings}])
    enabled = {r["asset"] for r in rows if r["enabled"]}
    _rstock_table(listings, rejected, enabled)
    _rstock_table(listings, rejected, enabled, kind="memecoin", label="memecoins")
    _arcus_table(listings, rejected, enabled)
    return 0


def toggle(path: Path, enable: str, disable: str) -> int:
    """Flip `enabled` on entries already in the file, by ticker or address. Reads no chain: the pool an
    entry carries is as old as the run that wrote it, so re-pick it (`--only`) before broadcasting."""
    old = _previous(path)
    words = lambda csv: {w.strip().lower() for w in csv.split(",") if w.strip()}
    on, off = words(enable), words(disable)
    if both := on & off:
        print(f"both enabled and disabled: {', '.join(sorted(both))}", file=sys.stderr)
        return 1
    seen = set()
    for row in old["rows"]:
        for name in {row["asset"], row["symbol"].lower()} & (on | off):
            seen.add(name)
            row["enabled"] = name in on
    if missing := (on | off) - seen:
        print(f"not in {path.name}: {', '.join(sorted(missing))} (list it first, with --only or --assets)", file=sys.stderr)
        return 1
    path.write_text(render(old["rows"], old["referencePerNative"], old["rejected"], old) + "\n")
    print(f"{sum(r['enabled'] for r in old['rows'])}/{len(old['rows'])} entries enabled in {path}", file=sys.stderr)
    return 0


def _only(universe: list[dict], only: str) -> list[dict] | None:
    """The policy assets `--only` names, by ticker or address; `arcus` is every Arcus pToken, `memecoins`
    every entry of `MEMECOINS`. None, after
    saying which, if a name is not in the policy — a subset run never widens it."""
    universe = [{"asset": REFERENCE, "symbol": "USDG"}] * bool(REFERENCE) + universe
    words = {w.strip().lower() for w in only.split(",") if w.strip()}
    picked = [c for c in universe if c["asset"] in words or c["symbol"].lower() in words
              or ("arcus" in words and c["asset"] in ARCUS) or ("memecoins" in words and c.get("memecoin"))]
    if missing := words - {"arcus", "memecoins"} - {c["asset"] for c in picked} - {c["symbol"].lower() for c in picked}:
        print(f"not in the listing policy on this chain: {', '.join(sorted(missing))}", file=sys.stderr)
        return None
    print(f"--only: {', '.join(c['symbol'] for c in picked)}", file=sys.stderr)
    return picked


def carry_over(old: dict, fresh: list[dict], rejected: list[dict], named: set[str]):
    """A subset run's file: the existing one, with only the re-picked assets' rows replaced in place and
    any new ones appended. Rows outside the subset — flags included — are copied verbatim, and a
    named asset that failed to qualify keeps its old row. Returns (rows, rejected, carried count).

    The reference is always priced fresh (every reference-quoted rate goes through it) but, like any
    other entry, replaces the existing one only when named, or when the file has none to keep."""
    if REFERENCE and REFERENCE not in named and any(r["asset"] == REFERENCE for r in old["rows"]):
        fresh = [r for r in fresh if r["asset"] != REFERENCE]
    by_asset = {r["asset"]: r for r in fresh}
    rows = [by_asset.pop(r["asset"], r) for r in old["rows"]] + list(by_asset.values())
    rows.sort(key=lambda r: r["asset"] != REFERENCE)  # stable: only moves the reference to the front
    fresh_assets = {r["asset"] for r in fresh}
    rejected = [r for r in old["rejected"] if r["asset"] not in named] + rejected
    for r in rejected:
        if r["asset"] in named and any(o["asset"] == r["asset"] for o in old["rows"]):
            print(f"  ! {r['symbol']} no longer qualifies; its existing entry is kept", file=sys.stderr)
    return rows, rejected, sum(r["asset"] not in fresh_assets for r in rows)


def _previous(path: Path) -> dict:
    """The existing file's entries, in the row shape `render` writes back, its rejections, and the
    reference rate it was written at (what `toggle` writes back, having read no chain)."""
    if not path.exists():
        return {"rows": [], "rejected": [], "referencePerNative": 1.0, "reference": None}
    was = json.loads(path.read_text())
    columns = zip(was["assets"], was["symbols"], was["enabled"], was["venues"], was["pools"], was["currency0"],
                  was["currency1"], was["fees"], was["tickSpacings"], was["hooks"], was["readable"])
    rows = [
        {"asset": a.lower(), "symbol": sym, "enabled": enabled, "readable": readable,
         "source": {"venue": v, "pool": pool, "c0": c0, "c1": c1, "fee": fee, "ts": ts, "hooks": hooks}}
        for a, sym, enabled, v, pool, c0, c1, fee, ts, hooks, readable in columns
    ]
    return {"rows": rows, "rejected": was.get("rejected", []), "reference": was.get("reference"),
            "referencePerNative": was.get("referencePerNative") or 1.0}


def _report(rejected: list[dict], switched_off: list[dict], held_off: list[dict]) -> None:
    """What this run switched off, and what it found a pool for but left off because the file says so.
    The rStocks' fate is `_rstock_table`; everything else that was rejected is one line of counts."""
    if switched_off:
        print(f"\nSWITCHED OFF — enabled before, no longer qualifying ({len(switched_off)}):", file=sys.stderr)
        for r in switched_off:
            print(f"  {r['symbol']:<12} {r['asset']}", file=sys.stderr)
    if held_off:
        print(f"\n{len(held_off)} qualify but stay disabled (`--enable` to list): "
              f"{', '.join(r['symbol'] for r in held_off)}", file=sys.stderr)
    rest = len([r for r in rejected if not r["rstock"]])
    if rest:
        print(f"\n{rest} other coins rejected; see `rejected` in the output file.", file=sys.stderr)


# The liquidity tiers the frontend shows creators, in native of quote-side depth.
TIERS = ((50, "deep"), (10, "ok"), (0, "low"))


def tier(depth: float) -> str:
    return next(name for floor, name in TIERS if depth >= floor)


def _rstock_table(listings: list[dict], rejected: list[dict], enabled: set[str], kind: str = "rstock",
                  label: str = "rStocks") -> None:
    """Every rStock (or every coin of another `kind`), deepest pool first, IN or OUT of the list — a
    markdown table on stdout."""
    rows = [(l["symbol"], l["asset"], l["depth"], f'v{l["pool"]["v"]}', "IN" if l["asset"] in enabled else "OFF", tier(l["depth"]))
            for l in listings if l.get(kind)]
    rows += [(r["symbol"], r["asset"], r["depthNative"], r["venue"] or "-", "OUT", r["reason"]) for r in rejected if r.get(kind)]
    if not rows:
        return
    print(f"\n{sum(r[4] == 'IN' for r in rows)}/{len(rows)} {label} listed\n")
    print("| # | symbol | address | depth (native) | venue | status | liquidity / reason |\n|---|---|---|---:|---|---|---|")
    for i, (symbol, asset, depth, venue, status, reason) in enumerate(sorted(rows, key=lambda r: -r[2]), 1):
        print(f"| {i} | {symbol} | `{asset}` | {depth:,.2f} | {venue} | **{status}** | {reason} |")


def _arcus_table(listings: list[dict], rejected: list[dict], enabled: set[str]) -> None:
    """The Arcus pTokens, same columns. Depth "n/a" where the pool reads no in-range liquidity."""
    rows = [(l["symbol"], l["asset"], l["depth"], "IN" if l["asset"] in enabled else "OFF",
             tier(l["depth"]) if l["depth"] is not None else "n/a")
            for l in listings if l.get("arcus")]
    rows += [(r["symbol"], r["asset"], None, "OUT", r["reason"]) for r in rejected if r.get("arcus")]
    if not rows:
        return
    print(f"\n{sum(r[3] == 'IN' for r in rows)}/{len(rows)} Arcus pTokens listed (fixed pool, quoted in USDG)\n")
    print("| # | symbol | address | depth (native) | status | liquidity / reason |\n|---|---|---|---:|---|---|")
    for i, (symbol, asset, depth, status, reason) in enumerate(rows, 1):
        print(f"| {i} | {symbol} | `{asset}` | {'n/a' if depth is None else f'{depth:,.2f}'} | **{status}** | {reason} |")


def _use_chain(name: str) -> None:
    """Point the module at one chain's Uniswap deployment. Called once, before anything reads it."""
    global CHAIN_ID, RPC, WETH, REFERENCE, UNIV2_FACTORY, UNIV3_FACTORY, POOL_MANAGER, SCAN_LOGS, NATIVE_SIDE
    c = CHAINS[name]
    CHAIN_ID, WETH, REFERENCE, SCAN_LOGS = c["chain_id"], c["weth"], c["reference"], c["scan_logs"]
    UNIV2_FACTORY, UNIV3_FACTORY, POOL_MANAGER = c["univ2_factory"], c["univ3_factory"], c["pool_manager"]
    RPC = os.environ.get(c["rpc_env"]) or c["rpc_default"]
    NATIVE_SIDE = {NATIVE, WETH}


def _named_coins(assets: list[str]) -> list[dict]:
    """Assets as the main loop takes them, with their symbols read off the chain."""
    symbols = multicall([(a, selector("symbol()")) for a in assets])
    out = []
    for asset, (ok, ret) in zip(assets, symbols):
        try:
            symbol = abi_decode(["string"], bytes(ret))[0] if ok and len(ret) > 32 else asset[:8]
        except Exception:
            symbol = asset[:8]
        out.append({"asset": asset, "symbol": symbol})
    return out


def _rejection(coin: dict, found: list[dict], args) -> dict:
    """Why an asset did not make the list: nothing quotes it on a venue the contract can read, or its
    deepest pool is under `--min-depth`."""
    best = found[0] if found else None
    if best is None:
        reason = "no Uniswap V2/V3/V4 pool against native or the reference"
    else:
        reason = f"too thin: deepest pool holds {best['depth']:,.2f} native, under --min-depth {args.min_depth}"
    return {
        "symbol": coin["symbol"],
        "asset": coin["asset"],
        "rstock": coin.get("rstock", False),
        **({"memecoin": True} if coin.get("memecoin") else {}),
        "reason": reason,
        "venue": f'v{best["pool"]["v"]}' if best else None,
        "depthNative": round(best["depth"], 4) if best else 0.0,
    }


def _source(listing: dict) -> dict:
    """One listing's on-chain `PriceSource`, as the seven parallel arrays hold it. A disabled entry
    keeps its real one; `WhitelistRobinhoodAssets` swaps in `Venue.NONE` when it retires it."""
    key = listing["pool"]
    v4 = key["v"] == 4
    return {
        # The contract's `Venue` enum, not the Uniswap version: NONE, V2, V3, V4.
        "venue": key["v"] - 1,
        "pool": key.get("pool") or NATIVE,  # the V2 pair or V3 pool; zero for V4
        "c0": key["t0"] if v4 else NATIVE,
        "c1": key["t1"] if v4 else NATIVE,
        "fee": key["fee"] if v4 else 0,
        "ts": key["ts"] if v4 else 0,
        "hooks": key["hooks"] if v4 else NATIVE,
    }


def _readable(listing: dict, reference_rate: float, reference: str | None) -> dict:
    """One row of the review section, which is never read on chain."""
    return {
        "symbol": listing["symbol"],
        "asset": listing["asset"],
        "rstock": listing.get("rstock", False),
        **({"arcus": True} if listing.get("arcus") else {}),
        **({"memecoin": True} if listing.get("memecoin") else {}),
        "venue": f'v{listing["pool"]["v"]}',
        "quote": "native" if listing["quote"] == NATIVE else reference,
        # None for an Arcus pool reading no in-range liquidity; it is listed regardless.
        "depthNative": None if listing["depth"] is None else round(listing["depth"], 4),
        # Priced in the reference asset, which on a chain that has one is a dollar stablecoin.
        "priceUsd": round(reference_rate / listing["rate"], 8) if REFERENCE else None,
        "perNative": round(listing["rate"], 8),
    }


def _row(listing: dict, reference_rate: float, reference: str | None) -> dict:
    """One entry of the file: what `render` writes, and what a subset run carries over verbatim."""
    return {"asset": listing["asset"], "symbol": listing["symbol"], "enabled": listing.get("enabled", True),
            "source": _source(listing), "readable": _readable(listing, reference_rate, reference)}


def render(rows: list[dict], reference_rate: float, rejected: list[dict], old: dict) -> str:
    """The file `WhitelistRobinhoodAssets` reads.

    Two halves: the arrays the forge script parses (one entry per listing, same order), and the
    `readable`/`rejected` sections, which are there for the human reviewing the list and are never read
    on chain. Parallel arrays rather than an array of structs because `vm.parseJson` can only decode one
    JSON value at a time."""
    sources = [r["source"] for r in rows]
    reference = (rows[0]["symbol"] if REFERENCE else None) or old["reference"]
    return json.dumps(
        {
            "chainId": CHAIN_ID,
            # Whole reference units per native, the rate every reference-quoted listing prices through.
            "reference": reference,
            "referencePerNative": round(reference_rate, 6) if REFERENCE else None,
            "assets": [r["asset"] for r in rows],
            "symbols": [r["symbol"] for r in rows],  # labels for the script's log, nothing more
            # The registry's switch. true: list it. false: keep the entry, and retire it if still priced.
            "enabled": [r["enabled"] for r in rows],
            "venues": [s["venue"] for s in sources],
            "pools": [s["pool"] for s in sources],
            "currency0": [s["c0"] for s in sources],
            "currency1": [s["c1"] for s in sources],
            "fees": [s["fee"] for s in sources],
            "tickSpacings": [s["ts"] for s in sources],
            "hooks": [s["hooks"] for s in sources],
            "readable": [r["readable"] for r in rows],
            # Everything considered and left out, with the number that decided it. Reviewing this is
            # how the depth threshold gets retuned, and how an rStock missing from the list is explained.
            "rejected": sorted(rejected, key=lambda r: (not r["rstock"], -(r["depthNative"] or 0))),
        },
        indent=1,
    )


if __name__ == "__main__":
    raise SystemExit(main())
