# Unfunded creators check

`check_unfunded_creators.py` queries the Realm indexer for mainnet reward creators with `accountedEth > 0`, then reads each creator's wallet balance via `eth_getBalance`. If any wallet holds **exactly 0 ETH**, the script raises so the wrapping process exits non-zero — these are accounts that have rewards owed but cannot pay gas to claim them.

## Run locally

```bash
export MAINNET_RPC_URL=https://...
uv run check_unfunded_creators.py
```

(Or drop a `.env` next to the script with `MAINNET_RPC_URL=...` — `python-dotenv` is loaded as a fallback.)

## CI

Runs daily at 08:00 UTC via `.github/workflows/check-unfunded-creators.yml`. The workflow fails if and only if at least one unfunded creator is found, which triggers GitHub's standard "workflow failed" email to the repo owner. To trigger ad-hoc, use **Actions → Check unfunded reward creators → Run workflow**.
