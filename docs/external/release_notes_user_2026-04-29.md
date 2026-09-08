# Realm — Release Notes (2026-04-29)

## For token creators

- **Sniper protection (new factory variants).** Optional anti-bot caps configured at deploy: max buy per tx (0.1%–3%), max wallet (0.1%–3%), protection window (1m–24h), and an address whitelist that bypasses the caps. Available for V2, V4, and tax-token variants.
- **Creator graduation reward raised to 0.125 ETH on V4** (was 0.05 ETH). V2 stays at 0.125 ETH — both graduators now pay the same.
- **Creator buy with multiple recipients.** The deploy-time buy can now be split across several wallets (team, treasury, marketing, airdrop) in one tx instead of going entirely to the deployer.
- **Multiple fee receivers, unified flow.** A single `createToken` call accepts 1 or many fee recipients with bps shares — no separate "with fee split" entry point. A fee splitter is auto-deployed when there are 2+ recipients.
- **Optional ownership renouncement on V4.** Deployers choose at creation whether to keep or renounce token ownership. V2 still always renounces.
- **Configurable buy/sell taxes** repacked into a single `TaxConfigInit` struct (buy bps, sell bps, duration), aligned with the new sniper config layout.

## For traders

- **Sniper-protected tokens enforce per-buyer caps** during the launch window — buys exceeding the per-tx or per-wallet limit are rejected on-chain.
- **`RealmQuoter` is the new quoting source** for the webapp: a single view returns the actual fillable amount plus a reason code (`SNIPER_CAP`, `GRADUATION_EXCESS`, `NOT_ENOUGH_SUPPLY`, `INSUFFICIENT_RESERVES`, `GRADUATED`, `INVALID_TOKEN`, or `NONE`), so the UI can show clear "you can buy at most X" hints instead of failing txs.
- **`maxTokenPurchase(buyer)`** view function exposed on every token — returns the largest amount a specific wallet can currently buy from the launchpad (max uint when no cap applies).

## Other

- Sepolia factory + quoter addresses redeployed; `deployments.sepolia.md` updated.
- Deployment addresses now sourced from the `.sol` config files; CI flags drift between `.sol` and `.md`.
