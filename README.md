# Foundry

For Sherlock auditors for January 2026, please read ./audit-info.md .

## Build the project

      forge build

## Running tests

Excluding invariants:

      forge test --no-match-contract Invariant

Only invariants

      forge test --match-contract Invariant

## Coverage

This displays also coverage for the /script/ files, which are out of scope (and have 0% coverage) which takes down the average to 87%

      forge coverage --nmc Invariant --exclude-tests


---------------

# Realm Launchpad

Realm Launchpad is a decentralized token launch platform that enables fair token distribution through a bonding curve mechanism, with automatic liquidity provision to Uniswap V2 upon reaching graduation criteria. A separate direct venue (`RealmFactoryUniV4Direct`) launches tokens straight into Uniswap V4 pools, with no bonding curve.

## Meta info

- Deployment chains: **Robinhood Chain mainnet** (4663) and **Robinhood Chain testnet** (46630)
- Integrations:
  - Uniswap v2 (liquidity addition)
  - Uniswap V4 (direct-launch pools)

## Protocol Overview

The Realm Launchpad protocol is a token factory and trading system that enables fair token distribution through a bonding curve mechanism, with the following features:

1. **Token Creation**: Anyone can create an ERC20 token with a fixed supply of 1 billion tokens using a minimal proxy pattern for gas-efficient deployment
2. **Bonding Curve Trading**: Users buy/sell tokens from the launchpad through a constant product bonding curve until graduation
3. **Automatic Graduation**: When ETH reserves reach 8.5 ETH, tokens automatically graduate to Uniswap
4. **Liquidity Provision**: All collected ETH (minus fees) is used to create a permanent, locked liquidity pool in Uniswap V2 (LP tokens sent to dead address)
5. **Creator Rewards**: Token creators receive 1% of supply (10M tokens) at graduation
6. **Fair Launch**: No pre-mines or pre-allocations. All supply is minted to the launchpad where it can be purchased.
7. **Pre-Graduation Trading Fees**: 1% fee on buys/sells, allocated to Realm treasury.
8. **Post-Graduation Trading Fees**: Uniswap V2: no additional fees
9. **Graduation Fee**: 0.5 ETH paid to treasury at graduation (configurable by admin)

## Architecture

### Core Contracts

#### `RealmLaunchpad.sol`

The main entry point and orchestrator contract that:

- Deploys new tokens via `createToken()`
- Handles buy/sell orders via `buyTokensWithExactEth()` and `sellExactTokens()`
- Manages token state and configuration
- Triggers graduation when threshold is met
- Collects and distributes fees
- Any re-configuration of graduation or fees dynamics only affects future token creations

#### `RealmToken.sol`

Minimal ERC20 implementation with graduation controls:

- Initialized via `initialize()` (not constructor, since it's cloned with a minimal proxy pattern)
- Prevents transfers to liquidity pool before graduation
- Marked as graduated by graduator contract via `markGraduated()`
- No fees on transfer, no token owner.

#### `ConstantProductBondingCurve.sol`

Implements the pricing formula for token purchases/sales:

- Uses constant product formula: `K = (t + T0) * (e + E0)`
- Numerically tuned constants ensure smooth price progression until graduation, which should happen at 8.5 ETH with ~200M tokens remaining in reserves
  - Note: out of those ~200M tokens, 10M are allocated to token creator, so only ~190M are used for liquidity.
- Total curve capacity: ~37.5 ETH if all tokens were sold through the bonding curve. Beyond that point the curve breaks. This point should never be reached, so graduation threshold should be far away from that limit (8.5 ETH currently).

#### `RealmGraduatorUniswapV2.sol`

Handles graduation to Uniswap V2:

- Creates Uniswap V2 pair at token creation via `initialize()`
- Adds liquidity to Uniswap V2 via `graduateToken()`
- Sends LP tokens to dead address (`0xdEaD`)
- Handles edge case of ETH donations to pair before graduation preventing graduation DOS
- **No creator fees** - all LP fees go to LP token holders (which are locked in the `0xdEaD` address)

#### `RealmDirectGraduatorUniV4.sol`

Direct V4 launch venue (called by `RealmFactoryUniV4Direct`, no launchpad or bonding curve):

- Creates 1-3 Uniswap V4 pools at creator-chosen prices in the token's creation tx
- Seeds the supply as single-sided token bands and executes the optional dev buy
- Holds the position NFTs forever (the liquidity lock); no graduation fee
- LP fees and taxes are taken by the swap hook (`RealmHook` for native pools, `RealmHookAnyPair` for ERC20-quoted pools)

### Token Data Structures

#### `TokenConfig` (set at creation, immutable)

- Stores per-token launchpad config set at creation (bonding curve and trading fees)
- For more info see docstrings in the structs defined in `src/types/tokenData.sol::TokenConfig`.

#### `TokenState` (dynamic, changes with trading)

- Stores variables defining the state of each deployed token (eth collected, released supply, if it has been graduated, etc).
- For more info see docstrings in the structs defined in `src/types/tokenData.sol::TokenState`.

## Main Entry Points

### For Token Creators

- **`createToken()`**: Deploy new tokens

### For Token Traders (Pre-Graduation)

- **`buyTokensWithExactEth()`**: Buy tokens on Realm Launchpad
- **`sellExactTokens()`**: Sell tokens on Realm Launchpad

### For Uniswap Trading (Post-Graduation)

After graduation, tokens trade on Uniswap V2 or V4 like any other token.

## Graduation Process

### When Does Graduation Happen?

Graduation is triggered automatically when `ethCollected >= ethGraduationThreshold` (8.5 ETH currently).

The threshold has a small excess allowance of 0.1 ETH. If a buy would exceed `threshold + 0.1 ETH`, the purchase reverts. This ensures that the price spread between the last launchpad buy and the uniswap pool doesn't deviate too much

The excess ETH is deposited as liquidity, which should be reflected as a higher token price.
Empirical forked tests show that:

### What Happens at Graduation?

1. **Fees Collected**: Graduation fee (0.5 ETH) goes to treasury
2. **Creator Allocation**: 10M tokens transferred to creator
3. **Liquidity Addition**: Remaining tokens + ETH sent to graduator contract
4. **Pool Creation**: Graduator adds liquidity to Uniswap
5. **State Update**: Token marked as graduated, trading disabled on launchpad
6. **Reserves Reset**: `ethCollected` set to 0
7. The token can be traded now via Uniswap

#### Calculation Example (Exact Graduation)

```
ETH collected: 8.5 ETH
Graduation fee: 0.5 ETH
ETH to liquidity: 8.0 ETH

Total supply: 1,000,000,000 tokens
Creator reserved: 10,000,000 tokens
Tokens sold: ~799,000,000 tokens
Tokens to liquidity: ~191,000,000 tokens
```

## Uniswap V2 Graduation

**Characteristics:**

- **Higher gas costs at token creation**: Full ERC20 pair contract deployment at token creation
- **LP tokens burned**: Sent to `0xdEaD` address, liquidity permanently locked
- **No creator fees**: Uniswap V2 trading accumulate as LP, which are locked in the `0xdEaD` address.
- **Invariant**: Uniswap price ≥ bonding curve price at graduation

## Deployment & Setup

### Prerequisites

- Uniswap V2 Router (for V2 graduator): `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` (mainnet)
- Uniswap V4 Pool Manager: `0x000000000004444c5dc75cB358380D2e3dE08A90` (mainnet)
- Uniswap V4 Position Manager: `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` (mainnet)
- Permit2: `0x000000000022D473030F116dDEE9F6B43aC78BA3` (mainnet)

### Deployment Steps

See [`docs/deploymentPlan.md`](docs/deploymentPlan.md) — a fresh chain is brought up in two broadcasts
(`just deploy-prereqs-<chain>` then `just deploy-stack-<chain>`), with a paste-and-rebuild step between
them because the two registry addresses are compile-time constants in the taxable token bytecode.

## Security Considerations

### Known Issues

**_Please challenge these known issues. Try to find ways of exploiting them further._**

#### 1. **Price drop in Uniswap V2 graduator**

Due to lower LP fees (0.3% vs 1% in launchpad), the swap price after graduation is slightly lower than in the launchpad.

- (!) The swap price is about `0.6712%` lower when graduation happens exactly at threshold
- (✔) The swap price is higher than launchpad when the last purchase is right below the excess cap

#### 2. **Price difference when selling back large amounts in uniswap compared to bonding curve**

The launchpad price when X tokens are in circulation before graduation does not match exactly the uniswap price when the same amount of tokens are in circulation. [see curves diagrams].

This is accepted, as not all the eth used for purchases is used in reserves (eth fees) and not all the eth reserves are used for liquidity (graduation fees).

#### 3. **ETH Donations to Uniswap V2 Pair Pre-Graduation**

Malicious actors could send ETH directly to the pair to manipulate the price at graduation.

**Mitigation**: `RealmGraduatorUniswapV2` includes:

- `sync()` call before reading reserves
- Price matching algorithm that transfers tokens directly to pair first
- Fallback to naive liquidity addition if needed
- Ensures Uniswap price ≥ bonding curve price

- If the last purchase before graduation is large (e.g., 0.1 ETH excess), the resulting Uniswap pool price will be higher than the bonding curve price. This is expected, as more ETH has been spent in purchasing
- Even if the max excess is hit, the price in uniswap after graduation should **always** be higher than the last price in the launchpad (fair pricing).
- The last buyer gets an immediate small profit. The larger the excess, the larger the instant price difference.
- This is considered acceptable as it encourages graduation. The max excess of 0.1 ETH limits the maximum impact.

#### 4. **Token Transfers to Pool Before Graduation**

Tokens cannot be transferred to the liquidity pool before graduation to avoid DOS of the graduation transaction.

- `RealmToken._update()` blocks transfers to `pair` address before `graduated == true`.

#### 5. **Minimal Dust Tokens Burned at Graduation**

When seeding Uniswap V4 positions (direct venue), a small amount of tokens (~0.000001% of supply) may remain unallocated due to rounding. This is accepted, but should not be a large portion (0.1% of the supply would be unacceptable).

#### 6. **Bonding Curve Overflow (>37 ETH)**

The `ConstantProductBondingCurve` has numerical limits and will revert if `ethReserves > ~37 ETH`.

**Mitigation**: Graduation threshold (8.5 ETH) + max excess (0.1 ETH), well below 37 ETH limit.



---------------------------------

## Updates

