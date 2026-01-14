# Livo Launchpad

Livo Launchpad is a decentralized token launch platform that enables fair token distribution through a bonding curve mechanism, with automatic liquidity provision to either Uniswap V2 or Uniswap V4 upon reaching graduation criteria.

## Meta info

- Deployment chain: **Ethereum mainnet**
- Integrations:
  - Uniswap v2 (liquidity addition)
  - Uniswap V4 (liquidity addition)

## Protocol Overview

The Livo Launchpad protocol is a token factory and trading system that enables fair token distribution through a bonding curve mechanism, with the following features:

1. **Token Creation**: Anyone can create an ERC20 token with a fixed supply of 1 billion tokens using a minimal proxy pattern for gas-efficient deployment
2. **Bonding Curve Trading**: Users buy/sell tokens from the launchpad through a constant product bonding curve until graduation
3. **Automatic Graduation**: When ETH reserves reach ~8 ETH (7.956 ETH exactly), tokens automatically graduate to Uniswap
4. **Liquidity Provision**: All collected ETH (minus fees) is used to create a permanent, locked liquidity pool in Uniswap:
   - Uniswap V2: LP tokens sent to dead address
   - Uniswap V4: NFT liquidity position locked in a Liquidity Lock contract
5. **Creator Rewards**: Token creators receive 1% of supply (10M tokens) at graduation
6. **Fair Launch**: No pre-mines or pre-allocations. All supply is minted to the launchpad where it can be purchased.
7. **Pre-Graduation Trading Fees**: 1% fee on buys/sells, allocated to Livo treasury.
8. **Post-Graduation Trading Fees**:
   - Uniswap V2: No additional fees
   - Uniswap V4: 1% LP fees with ETH fees split 50/50 between creator and Livo treasury; token fees locked
9. **Graduation Fee**: 0.5 ETH paid to treasury at graduation (configurable by admin)

## Architecture

### Core Contracts

#### `LivoLaunchpad.sol`

The main entry point and orchestrator contract that:

- Deploys new tokens via `createToken()`
- Handles buy/sell orders via `buyTokensWithExactEth()` and `sellExactTokens()`
- Manages token state and configuration
- Triggers graduation when threshold is met
- Collects and distributes fees
- Any re-configuration of graduation or fees dynamics only affects future token creations

#### `LivoToken.sol`

Minimal ERC20 implementation with graduation controls:

- Initialized via `initialize()` (not constructor, since it's cloned with a minimal proxy pattern)
- Prevents transfers to liquidity pool before graduation
- Marked as graduated by graduator contract via `markGraduated()`
- No fees on transfer, no token owner.

#### `ConstantProductBondingCurve.sol`

Implements the pricing formula for token purchases/sales:

- Uses constant product formula: `K = (t + T0) * (e + E0)`
- Numerically tuned constants ensure smooth price progression until graduation, which should happen at 7.956 ETH ~200M tokens remaining in reserves
  - Note: out of those ~200M tokens, 10M are allocated to token creator, so only ~190M are used for liquidity.
- Total curve capacity: ~37.5 ETH if all tokens were sold through the bonding curve. Beyond that point the curve breaks. This point should never be reached, so graduation threshold should be far away from that limit (~8 ETH initially).

#### `LivoGraduatorUniswapV2.sol`

Handles graduation to Uniswap V2:

- Creates Uniswap V2 pair at token creation via `initializePair()`
- Adds liquidity to Uniswap V2 via `graduateToken()`
- Sends LP tokens to dead address (`0xdEaD`)
- Handles edge case of ETH donations to pair before graduation preventing graduation DOS
- **No creator fees** - all LP fees go to LP token holders (which are locked in the `0xdEaD` address)

#### `LivoGraduatorUniswapV4.sol`

Handles graduation to Uniswap V4:

- Initializes Uniswap V4 pool at token creation via `initializePair()`
- Adds concentrated liquidity position via `graduateToken()`
- Locks liquidity NFT in `LiquidityLockUniv4WithFees` contract
- **Creator ETH fees enabled**
  - LP Fees collected as tokens are left locked in the univ4 graduator
  - LP Fees collected as ETH are split 50/50% between the token creator and Livo treasury
- Collects and distributes fees via `collectEthFees()`

#### `LiquidityLockUniv4WithFees.sol`

Custody contract for Uniswap V4 liquidity positions:

- Holds the UniV4 NFTs representing liquidity positions of all graduated tokens
- Allows fee collection via `claimUniV4PositionFees()` without withdrawing liquidity
- Prevents withdrawal of locked position NFT

### Token Data Structures

#### `TokenConfig` (set at creation, immutable)

- Stores immutable attributes of a token when it is created (bondig curve, graduator, creator, etc)
- For more info see docstrings in the structs defined in `src/types/tokenData.sol::TokenConfig`.

#### `TokenState` (dynamic, changes with trading)

- Stores variables defining the state of each deployed token (eth collected, released supply, if it has been graduated, etc).
- For more info see docstrings in the structs defined in `src/types/tokenData.sol::TokenState`.

## Main Entry Points

### For Token Creators

- **`createToken()`**: Deploy new tokens

### For Token Traders (Pre-Graduation)

- **`buyTokensWithExactEth()`**: Buy tokens on Livo Launchpad
- **`sellExactTokens()`**: Sell tokens on Livo Launchpad

### For Uniswap Trading (Post-Graduation)

After graduation, tokens trade on Uniswap V2 or V4 like any other token.

## Graduation Process

### When Does Graduation Happen?

Graduation is triggered automatically when `ethCollected >= ethGraduationThreshold` (~7.956 ETH initially).

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
ETH collected: 7.956 ETH
Graduation fee: 0.5 ETH
ETH to liquidity: 7.456 ETH

Total supply: 1,000,000,000 tokens
Creator reserved: 10,000,000 tokens
Tokens sold: ~799,000,000 tokens
Tokens to liquidity: ~191,000,000 tokens
```

## Uniswap V2 vs Uniswap V4 Graduation

### Uniswap V2 Graduation

**Characteristics:**

- **Higher gas costs at token creation**: Full ERC20 pair contract deployment at token creation
- **LP tokens burned**: Sent to `0xdEaD` address, liquidity permanently locked
- **No creator fees**: Uniswap V2 trading accumulate as LP, which are locked in the `0xdEaD` address.
- **Invariant**: Uniswap price ≥ bonding curve price at graduation

### Uniswap V4 Graduation

**Characteristics:**

- **Lower gas costs at token creation**: pair is initialized in the pool manager, no contract deployment.
- **Liquidity NFT locked**: Held in `LiquidityLockUniv4WithFees` contract
- **Invariant**: Uniswap price ≥ bonding curve price at graduation
- **Fee tier**: 1% (10,000 pips)
- **Tick spacing**: 200
- // todo review these two below:
- **Position spans** from 0.497 to 694,694,034 tokens per ETH
- **Starting price**: ~39,011,306,440 tokens per ETH

**Fee Collection:**
Anyone can call `LivoGraduatorUniswapV4.collectEthFees()` to:

1. Claim accumulated fees from Uniswap V4 positions of an array of graduated tokens
2. Split ETH fees 50/50 between creator and Livo treasury
3. Token fees remain in graduator contract (effectively burned)

## Deployment & Setup

### Prerequisites

- Uniswap V2 Router (for V2 graduator): `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` (mainnet)
- Uniswap V4 Pool Manager: `0x000000000004444c5dc75cB358380D2e3dE08A90` (mainnet)
- Uniswap V4 Position Manager: `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` (mainnet)
- Permit2: `0x000000000022D473030F116dDEE9F6B43aC78BA3` (mainnet)

### Deployment Steps

1. **Deploy Token Implementation**

   ```solidity
   LivoToken tokenImplementation = new LivoToken();
   ```

2. **Deploy Launchpad**

   ```solidity
   LivoLaunchpad launchpad = new LivoLaunchpad(treasury, tokenImplementation);
   ```

3. **Deploy Bonding Curve**

   ```solidity
   ConstantProductBondingCurve bondingCurve = new ConstantProductBondingCurve();
   ```

4. **Deploy Graduators**

   ```solidity
   // Uniswap V2
   LivoGraduatorUniswapV2 graduatorV2 = new LivoGraduatorUniswapV2(
       UNISWAP_V2_ROUTER,
       address(launchpad)
   );

   // Uniswap V4
   LiquidityLockUniv4WithFees liquidityLock = new LiquidityLockUniv4WithFees(
       UNIV4_NFT_POSITIONS,
       UNIV4_POSITION_MANAGER
   );

   LivoGraduatorUniswapV4 graduatorV4 = new LivoGraduatorUniswapV4(
       address(launchpad),
       address(liquidityLock),
       POOL_MANAGER,
       POSITION_MANAGER,
       PERMIT2,
       UNIV4_NFT_POSITIONS
   );
   ```

5. **Whitelist curves & graduators pairs**
   ```solidity
   launchpad.whitelistComponents(address(bondingCurve), address(graduatorV2), true);
   launchpad.whitelistComponents(address(bondingCurve), address(graduatorV4), true);
   ```

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

#### 3. **Capitalization differences between uniV2 and uniV4**

Because the price in univ2 and univ4 will be slightly different at graduation, so will the market capitalization and the eth worth of liquidity deposited.

Here we calculate the maximum difference between the two (when the graduation is exact):

**Uniswap V2 graduator**:

- Token price: 39181184229 wei/token = 0.00000003918 ETH
- Market cap = 39.18 ETH

**Uniswap V4 graduator**:

- Token price: 39457675015 wei/token = 0.00000003945 ETH
- Market cap: 39.45 ETH

The price (and market cap) after graduation on univ4 tokens is about 0.7% higher than univ2.

Note that the prices here are the effective prices making a swap, (ethSpent/tokensBought), which also includes the swap fees (1% in Univ4 vs 0.3% in Univ2).

#### 4. **ETH Donations to Uniswap V2 Pair Pre-Graduation**

Malicious actors could send ETH directly to the pair to manipulate the price at graduation.

**Mitigation**: `LivoGraduatorUniswapV2` includes:

- `sync()` call before reading reserves
- Price matching algorithm that transfers tokens directly to pair first
- Fallback to naive liquidity addition if needed
- Ensures Uniswap price ≥ bonding curve price

- If the last purchase before graduation is large (e.g., 0.1 ETH excess), the resulting Uniswap pool price will be higher than the bonding curve price. This is expected, as more ETH has been spent in purchasing
- Even if the max excess is hit, the price in uniswap after graduation should **always** be higher than the last price in the launchpad (fair pricing).
- The last buyer gets an immediate small profit. The larger the excess, the larger the instant price difference.
- This is considered acceptable as it encourages graduation. The max excess of 0.1 ETH limits the maximum impact.

#### 5. **Token Transfers to Pool Before Graduation**

Tokens cannot be transferred to the liquidity pool before graduation to avoid DOS of the graduation transaction.

- `LivoToken._update()` blocks transfers to `pair` address before `graduated == true`.

#### 6. **Minimal Dust Tokens Burned at Graduation**

When adding liquidity to Uniswap V4, a small amount of tokens (~0.000001% of supply) may remain unallocated due to rounding. This is accepted, but should not be a large portion (0.1% of the supply would be unacceptable).

#### 7. **Bonding Curve Overflow (>37 ETH)**

The `ConstantProductBondingCurve` has numerical limits and will revert if `ethReserves > ~37 ETH`.

**Mitigation**: Graduation threshold (7.956 ETH) + max excess (0.1 ETH), well below 37 ETH limit.



---------------------------------

## Updates

### Uniswap hooks

To find the hook address with create2, run the script:

   forge script MineHookAddressForTests

This should be run for the latest version of the hook, since it uses its creation code. 

This should print an output like this:

```
  === MINED ADDRESS ===
  Hook Address: 0xf84841AB25aCEcf0907Afb0283aB6Da38E5FC044
  Salt: 0x0x3b57
  
  === Copy this to your test file ===
  address constant PRECOMPUTED_HOOK_ADDRESS = 0xf84841AB25aCEcf0907Afb0283aB6Da38E5FC044;
  bytes32 constant HOOK_SALT = bytes32(uint256(0x0x3b57));
```

