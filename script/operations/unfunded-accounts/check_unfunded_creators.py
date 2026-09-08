# /// script
# requires-python = ">=3.11"
# dependencies = ["requests", "python-dotenv", "rich"]
# ///
"""Daily alert: fail if any Realm reward creator has pending ETH claims but a 0 ETH wallet.

Checks both Ethereum mainnet and Robinhood Chain mainnet. Runs in CI via
.github/workflows/check-unfunded-creators.yml. On match, exits 1 so GitHub fires the
standard workflow-failed email. Locally, runnable with `uv run check_unfunded_creators.py`
after exporting MAINNET_RPC_URL (Robinhood defaults to its public RPC; override with
ROBINHOOD_RPC_URL). Env vars can also live in a sibling .env file.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import requests
from dotenv import load_dotenv
from rich.console import Console
from rich.table import Table

GRAPHQL_URL = "https://indexer.livo.trade/v1/graphql"
JSONRPC_BATCH_SIZE = 100
HTTP_TIMEOUT = 30
MIN_ACCRUED_WEI = 5 * 10**16  # 0.05 ETH: ignore dust claims not worth funding gas for

# We flag a creator only when ALL three hold on the chain where they accrued:
#   1. total accrued > MIN_ACCRUED_WEI
#   2. never claimed anything on that chain (they don't know how to claim yet)
#   3. exactly 0 ETH balance (any balance means they have gas / have held ETH before)

# Chains to check. rpc_default lets Robinhood work without a configured secret (public RPC).
CHAINS = [
    {"name": "ethereum", "chain_id": "1", "rpc_env": "MAINNET_RPC_URL", "rpc_default": None},
    {
        "name": "robinhood",
        "chain_id": "4663",
        "rpc_env": "ROBINHOOD_RPC_URL",
        "rpc_default": "https://rpc.mainnet.chain.robinhood.com",
    },
]

# No claimedEth filter here: rows are per-token, so we must aggregate every token a
# creator has on the chain to know whether they have EVER claimed. Filtering rows by
# claimedEth == 0 would keep a creator who claimed on one token but not another.
QUERY = """
query MyQuery {{
  RewardsTokenCreator(
    where: {{
      chainId: {{_eq: "{chain_id}"}},
      accountedEth: {{_gt: "0"}}
    }}
  ) {{
    accruedEth
    claimedEth
    creator
  }}
}}
"""

console = Console(highlight=False)


def fetch_creators(chain_id: str) -> list[dict]:
    resp = requests.post(
        GRAPHQL_URL, json={"query": QUERY.format(chain_id=chain_id)}, timeout=HTTP_TIMEOUT
    )
    if resp.status_code != 200:
        raise RuntimeError(f"GraphQL HTTP {resp.status_code}: {resp.text}")
    payload = resp.json()
    if "errors" in payload:
        raise RuntimeError(f"GraphQL errors: {payload['errors']}")
    return payload["data"]["RewardsTokenCreator"]


def unique_creators(rows: list[dict]) -> dict[str, tuple[int, int]]:
    """Return {lowercased address: (total accruedEth, total claimedEth) in wei}."""
    totals: dict[str, tuple[int, int]] = {}
    for row in rows:
        addr = row["creator"].lower()
        accrued, claimed = totals.get(addr, (0, 0))
        totals[addr] = (accrued + int(row["accruedEth"]), claimed + int(row["claimedEth"]))
    return totals


def get_balances(addresses: list[str], rpc_url: str) -> dict[str, int]:
    """Batched eth_getBalance. Returns {address: balance_wei}."""
    out: dict[str, int] = {}
    for start in range(0, len(addresses), JSONRPC_BATCH_SIZE):
        chunk = addresses[start : start + JSONRPC_BATCH_SIZE]
        batch = [
            {
                "jsonrpc": "2.0",
                "id": start + i,
                "method": "eth_getBalance",
                "params": [addr, "latest"],
            }
            for i, addr in enumerate(chunk)
        ]
        resp = requests.post(rpc_url, json=batch, timeout=HTTP_TIMEOUT)
        if resp.status_code != 200:
            raise RuntimeError(f"RPC HTTP {resp.status_code}: {resp.text}")
        results = resp.json()
        by_id = {r["id"]: r for r in results}
        for i, addr in enumerate(chunk):
            r = by_id[start + i]
            if "error" in r:
                raise RuntimeError(f"RPC error for {addr}: {r['error']}")
            out[addr] = int(r["result"], 16)
    return out


def main() -> int:
    load_dotenv(Path(__file__).resolve().parent / ".env")

    unfunded: list[tuple[str, str, int, int]] = []  # (chain, addr, balance_wei, accrued_wei)
    errors: list[str] = []  # per-chain failures, reported at the end so one bad chain doesn't hide the other

    for chain in CHAINS:
        name = chain["name"]
        rpc_url = os.getenv(chain["rpc_env"]) or chain["rpc_default"]
        if not rpc_url:
            errors.append(f"{name}: {chain['rpc_env']} not set")
            console.print(f"[red]{name}: {chain['rpc_env']} not set — skipping[/red]")
            continue
        try:
            console.print(f"[dim]{name}: querying Realm indexer…[/dim]")
            totals = unique_creators(fetch_creators(chain["chain_id"]))
            # Rules 1 & 2: enough accrued and never claimed on this chain.
            candidates = {
                addr: accrued
                for addr, (accrued, claimed) in totals.items()
                if accrued > MIN_ACCRUED_WEI and claimed == 0
            }
            console.print(f"[dim]{name}: {len(candidates)} creators with unclaimed rewards ≥ 0.05 ETH.[/dim]")
            if not candidates:
                continue
            console.print(f"[dim]{name}: reading balances ({len(candidates)} wallets, batched)…[/dim]")
            balances = get_balances(list(candidates), rpc_url)
            for addr, accrued in candidates.items():
                if balances[addr] == 0:  # Rule 3: exactly 0 ETH means no gas and never held ETH.
                    unfunded.append((name, addr, balances[addr], accrued))
        except Exception as e:  # noqa: BLE001 — keep going so the other chain still gets checked
            errors.append(f"{name}: {e}")
            console.print(f"[red]{name}: error — {e}[/red]")

    unfunded.sort(key=lambda x: x[3], reverse=True)

    if unfunded:
        table = Table(title=f"Unfunded creators (0 ETH balance, unclaimed ≥ 0.05 ETH): {len(unfunded)}")
        table.add_column("chain", style="magenta", no_wrap=True)
        table.add_column("creator", style="cyan", no_wrap=True)
        table.add_column("balance (ETH)", justify="right")
        table.add_column("accrued (ETH)", justify="right", style="green")
        for chain_name, addr, bal_wei, accrued_wei in unfunded:
            table.add_row(chain_name, addr, f"{bal_wei / 1e18:.6f}", f"{accrued_wei / 1e18:.6f}")
        console.print(table)

    if not unfunded and not errors:
        console.print("[green]OK: no unfunded creators with pending claims on any chain.[/green]")
        return 0

    parts: list[str] = []
    if unfunded:
        per_chain: dict[str, int] = {}
        for chain_name, *_ in unfunded:
            per_chain[chain_name] = per_chain.get(chain_name, 0) + 1
        breakdown = ", ".join(f"{n} on {c}" for c, n in per_chain.items())
        parts.append(
            f"{len(unfunded)} creator(s) have ≥ 0.05 ETH unclaimed, never claimed, and a 0 ETH balance "
            f"({breakdown}) — fund them or investigate."
        )
    if errors:
        parts.append("Chain errors: " + "; ".join(errors))
    raise RuntimeError(" | ".join(parts))


if __name__ == "__main__":
    sys.exit(main())
