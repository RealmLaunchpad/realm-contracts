# Bridge Stocks

A pooled vault that gives on-chain holders exposure to a single stock. Users deposit a USD
stablecoin and receive shares; shares are redeemed back into stablecoin or ETH. The stock itself is
held off-chain by an operator, so the vault issues **exposure**, not a claim on a specific token.

## How it works

**Mint.** A user calls `mint(amount)` with the deposit token, or `mintWithETH(minDepositOut)` with
native ETH (swapped to the deposit token at the edge through Uniswap V3). The deposit is escrowed in
the vault and a request id is returned. The controller then calls `confirmMint(requestId, sharesOut)`
and the shares are minted.

**Redeem.** A user calls `redeem(shareAmount)`, or `redeemToETH(shareAmount, minEthOut)`. The shares
are burned into a pending request. The controller calls `confirmRedeem(requestId, payoutAmount)` and
the payout is pulled **from the controller** and sent to the user.

Requests are not instant by design: the controller sizes or unwinds the real position first, then
confirms with the resulting numbers.

**Pricing.** Shares are priced at net asset value — backing divided by supply — as reported by the
controller at confirmation time. There is no on-chain oracle and no 1:1 redemption against a token.

## Backing and the peg

The vault does not care how the backing is held. Two shapes work:

| Backing | Capital needed | Trade-offs |
|---|---|---|
| Spot tokenized stock (e.g. an xStock bought on Solana) | 100% of exposure | nothing to maintain, no liquidation, backing is the asset itself; acquisition and unwind depend on that market's depth |
| Delta-hedged perp position | margin only, roughly 5–10x more exposure per dollar | funding costs, hedge drift, liquidation risk, continuous keeper attention |

The peg — a share staying worth about one share of the stock — is held by policy, not by the
contract: NAV pricing on mint and redeem, plus an off-chain keeper arbitraging the pool price back
toward the mark. A user must trust that the operator holds the backing and reports it honestly.

If you want a peg the contract enforces instead, that is a different design: a 1:1 wrapper where the
token is redeemable for a specific bridged asset and arbitrage does the work. This vault deliberately
trades that away in order to back exposure without holding spot inventory.

## Trust model

The controller is trusted to price fairly. The contract bounds what that trust can cost:

- **Deposits are escrowed** in the vault until `confirmMint`; they are never handed to the controller.
- **Payouts are pulled from the controller** at confirm time, so an unfunded controller cannot drain
  the pool — it simply cannot confirm.
- **Every confirmation's implied share price is checked** against the previous one and rejected beyond
  `maxPriceDeviationBps` (10% at initialization, owner-settable). The first confirmation has nothing
  to compare against and sets the baseline (`priceBootstrapped`).
- **The ETH payout floor is set by the user**, not the controller: `redeemToETH(shares, minEthOut)`.
  The controller therefore cannot both fund a redemption and remove its slippage bound.
- **An ETH send that fails does not brick the redemption.** The payout is re-wrapped and credited as
  claimable WETH (`claimWeth`), so a contract user that rejects ETH cannot grief anyone.
- **Unconfirmed requests expire.** After `requestTimeout` a user can `reclaimExpiredMint` to take the
  deposit back. Expired redeems need `authorizeRedeemReclaim` from the owner first, because the vault
  cannot tell "never processed" from "already settled off-chain".

What the controller can still do: report an unfavourable-but-in-band price, or stall by never
confirming (bounded by the expiry paths above).

## Contracts

| Contract | Role |
|---|---|
| `StockBridgeVault` | deposits, redemptions, share pricing, the operator bounds above. UUPS-upgradeable, owner-controlled |
| `StockBridgeShare` | the share token. Mint and burn restricted to the vault; created by `initialize()` so it survives upgrades |

`src/interfaces/` holds the external interfaces used at the ETH edge (`ISwapRouter02`) and an oracle
interface (`IPyth`) kept for reference.

## Roles

- **Owner** — upgrades, sets the controller, the deviation band, the minimum deposit and the swap fee
  tier.
- **Controller** — confirms mints and redeems. Holds the real position off-chain.
- **Users** — mint, redeem, claim, and reclaim expired requests.

## Configuration

Set at `initialize`: deposit token, controller, request timeout, swap router, WETH, owner. Defaults
applied there: swap pool fee tier `500`, `maxPriceDeviationBps = 1000` (10%). A request timeout of
zero is rejected — it would make requests reclaimable in the next block.

## Build

This repository contains contracts only. Build with Foundry against OpenZeppelin 5.3.x
(`@openzeppelin/contracts` and `@openzeppelin/contracts-upgradeable`), solc 0.8.30, `via_ir` enabled.
