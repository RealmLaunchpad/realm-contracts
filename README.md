# Livo Launchpad

Livo Launchpad is a decentralized token launch platform that enables fair token distribution through a bonding curve mechanism, with automatic liquidity provision to either Uniswap V2 or Uniswap V4 upon reaching graduation criteria.

## Protocol Overview

The Livo Launchpad protocol consists of a token factory and trading system that:

1. **Token Creation**: Anyone can create an ERC20 token with a fixed supply of 1 billion tokens using a minimal proxy pattern (for a gas-efficient deployment)
2. **Bonding Curve Trading**: Users buy/sell tokens from the launchpad through a constant product bonding curve before graduation
3. **Automatic Graduation**: When ETH reserves reach ~8 ETH (7.956 ETH exactly), tokens automatically graduate to Uniswap
4. **Liquidity Provision**: All collected ETH (minus fees) is used to create a permanent liquidity pool in Uniswap
5. **Creator Rewards in tokens**: Token creators receive 1% of supply (10M tokens) at graduation. 

### Key Features

- **Fair launch** mechanism with no pre-mines (except 1% creator allocation at graduation)
- **Liquidity lock** - Liquidity after graduation is locked: Univ2 LP tokens are sent to dead address and Univ4 NFT liquidity position is locked in a Liquidity lock contract.
- **Trading fees Before graduation**: 1% fee on buys/sells.
- **Trading fees After graduation**: 
  - Uniswap V2 graduation: No fees
  - Uniswap V4 graduation: 1% LP fees. Token fees are locked in the liquidity lock. Eth fees are shared between creator and Livo team.
- **Graduation fee** of 0.5 ETH paid to treasury at graduation (configurable, it can be updated by admin).

## Architecture

### Core Contracts

#### `LivoLaunchpad.sol`
The main entry point and orchestrator contract that:
- Deploys new tokens via `createToken()`
- Handles buy/sell orders via `buyTokensWithExactEth()` and `sellExactTokens()`
- Manages token state and configuration
- Triggers graduation when threshold is met
- Collects and distributes fees

**Key State Variables:**
- `tokenImplementation`: ERC20 implementation used for cloning
- `baseEthGraduationThreshold`: ~7.956 ETH required for graduation
- `baseGraduationFee`: 0.5 ETH fee at graduation
- `baseBuyFeeBps` / `baseSellFeeBps`: Trading fees (100 bps = 1%)
- `tokenConfigs`: Mapping of token address to `TokenConfig` struct
- `tokenStates`: Mapping of token address to `TokenState` struct

#### `LivoToken.sol`
Minimal ERC20 implementation with graduation controls:
- Initialized via `initialize()` (not constructor, since it's cloned)
- Prevents transfers to liquidity pool before graduation
- Marked as graduated by graduator contract via `markGraduated()`

#### `ConstantProductBondingCurve.sol`
Implements the pricing formula for token purchases/sales:
- Uses constant product formula: `K = (t + T0) * (e + E0)`
- Numerically tuned constants ensure smooth price progression
- Graduation at 8 ETH with ~200M tokens remaining in reserves
- Total curve capacity: ~37.5 ETH if all tokens sold

#### `LivoGraduatorUniswapV2.sol`
Handles graduation to Uniswap V2:
- Creates Uniswap V2 pair at token creation via `initializePair()`
- Adds liquidity to Uniswap V2 via `graduateToken()`
- Sends LP tokens to dead address (`0xdEaD`)
- Handles edge case of ETH donations to pair before graduation
- **No creator fees** - all LP fees go to LP token holders (which are locked)

#### `LivoGraduatorUniswapV4.sol`
Handles graduation to Uniswap V4:
- Initializes Uniswap V4 pool at token creation via `initializePair()`
- Adds concentrated liquidity position via `graduateToken()`
- Locks liquidity NFT in `LiquidityLockUniv4WithFees` contract
- **Creator fees enabled** - 50% of LP fees go to token creator, 50% to Livo treasury
- Collects and distributes fees via `collectEthFees()`

#### `LiquidityLockUniv4WithFees.sol`
Custody contract for Uniswap V4 liquidity positions:
- Holds NFT representing liquidity position
- Allows fee collection via `claimUniV4PositionFees()` without withdrawing liquidity
- Prevents withdrawal of locked position NFT

### Token Data Structures

#### `TokenConfig` (set at creation, immutable)
- `bondingCurve`: Address of pricing contract
- `graduator`: Address of graduation handler (V2 or V4)
- `creator`: Token creator address
- `graduationEthFee`: Fee paid at graduation (0.5 ETH)
- `ethGraduationThreshold`: ETH needed for graduation (~7.956 ETH)
- `creatorReservedSupply`: Tokens reserved for creator (10M)
- `buyFeeBps` / `sellFeeBps`: Trading fees in basis points (100 = 1%)

#### `TokenState` (dynamic, changes with trading)
- `ethCollected`: ETH accumulated from buys (used for liquidity)
- `releasedSupply`: Tokens in circulation (sold to users)
- `graduated`: Boolean indicating graduation status

## Main Entry Points

### For Token Creators

**`createToken(string name, string symbol, address bondingCurve, address graduator)`**

Creates a new token with:
- 1B total supply held by launchpad initially
- Selected bonding curve and graduator (must be whitelisted pair)
- Creator receives 10M tokens (1%) at graduation

### For Token Traders (Pre-Graduation)

**`buyTokensWithExactEth(address token, uint256 minTokenAmount, uint256 deadline)`**

Buy tokens from bonding curve:
- Sends ETH, receives tokens based on current price
- 1% fee deducted from ETH amount
- Includes slippage protection via `minTokenAmount`
- Triggers graduation if threshold reached

**`sellExactTokens(address token, uint256 tokenAmount, uint256 minEthAmount, uint256 deadline)`**

Sell tokens back to bonding curve:
- Sends tokens, receives ETH based on current price
- 1% fee deducted from ETH received
- Includes slippage protection via `minEthAmount`
- Cannot sell after graduation

### For Uniswap Trading (Post-Graduation)

After graduation, tokens trade on Uniswap V2 or V4 like any other token:
- **Uniswap V2**: Standard AMM trading at `https://app.uniswap.org`
- **Uniswap V4**: Concentrated liquidity trading via Uniswap Universal Router

## Graduation Process

### When Does Graduation Happen?

Graduation is triggered automatically when `ethCollected >= ethGraduationThreshold` (~7.956 ETH).

The threshold has a small excess allowance of 0.5 ETH to prevent DOS attacks. If a buy would exceed `threshold + 0.5 ETH`, it reverts.

### What Happens at Graduation?

1. **Fees Collected**: Graduation fee (0.5 ETH) goes to treasury
2. **Creator Allocation**: 10M tokens transferred to creator
3. **Liquidity Addition**: Remaining tokens + ETH sent to graduator
4. **Pool Creation**: Graduator adds liquidity to Uniswap
5. **State Update**: Token marked as graduated, trading disabled on launchpad
6. **Reserves Reset**: `ethCollected` set to 0

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
- **Higher gas costs**: Full ERC20 pair contract deployment
- **LP tokens burned**: Sent to `0xdEaD` address, liquidity permanently locked
- **No creator fees**: All trading fees go to LP (which is locked, so fees accumulate in pair)
- **Simple mechanism**: Standard Uniswap V2 `addLiquidityETH()`
- **Full price range**: Liquidity across entire price curve

**Liquidity Details:**
- LP tokens sent to `address(0xdEaD)`
- ETH donated to pair before graduation is handled gracefully
- Price matching ensures Uniswap price ≥ bonding curve price at graduation

### Uniswap V4 Graduation

**Characteristics:**
- **Lower gas costs**: Single pool manager, concentrated liquidity
- **Liquidity NFT locked**: Held in `LiquidityLockUniv4WithFees` contract
- **Creator fees enabled**: 50% of LP fees to creator, 50% to Livo treasury
- **Concentrated liquidity**: Position set between ticks -7000 to 203600
- **Fee collection**: `collectEthFees()` can be called by anyone to distribute fees

**Liquidity Details:**
- Liquidity NFT locked in custody contract
- Position spans from 0.497 to 694,694,034 tokens per ETH
- Starting price: ~39,011,306,440 tokens per ETH
- Fee tier: 1% (10,000 pips)
- Tick spacing: 200

**Fee Collection:**
Anyone can call `LivoGraduatorUniswapV4.collectEthFees(address[] tokens)` to:
1. Claim accumulated fees from Uniswap V4 position
2. Split ETH fees 50/50 between creator and Livo treasury
3. Token fees remain in graduator contract (effectively burned)

## Intended User Flow

### 1. Token Creation
```
Creator → createToken() → LivoToken deployed
                       → Uniswap pair/pool initialized
                       → All tokens held by launchpad
```

### 2. Pre-Graduation Trading (Bonding Curve)
```
Buyer → buyTokensWithExactEth() → ETH sent to launchpad
                                → Tokens transferred to buyer
                                → ethCollected increases
                                → Price increases for next buyer

Seller → sellExactTokens() → Tokens sent to launchpad
                           → ETH sent to seller
                           → ethCollected decreases
                           → Price decreases for next buyer
```

### 3. Graduation (Automatic)
```
Final Buyer → buyTokensWithExactEth() → ethCollected >= threshold
                                      → _graduateToken() triggered
                                      → Fees collected
                                      → Creator receives 10M tokens
                                      → Liquidity added to Uniswap
                                      → Token marked as graduated
```

### 4. Post-Graduation Trading (Uniswap)

#### Uniswap V2
```
Trader → Uniswap V2 Router → Swap ETH/Token
                           → Trading fees accumulate in pair (locked)
```

#### Uniswap V4
```
Trader → Uniswap Universal Router → Swap ETH/Token
                                  → Trading fees accumulate in position

Anyone → collectEthFees([token]) → Fees distributed:
                                  → 50% to creator
                                  → 50% to Livo treasury
```

### 5. Fee Collection (Uniswap V4 Only)
```
Anyone → collectEthFees([token1, token2, ...]) → Batch fee collection
                                                → Gas-efficient for multiple tokens
```

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

5. **Whitelist Components**
   ```solidity
   launchpad.whitelistCurveAndGraduator(address(bondingCurve), address(graduatorV2), true);
   launchpad.whitelistCurveAndGraduator(address(bondingCurve), address(graduatorV4), true);
   ```

## Security Considerations

### Known Issues & Mitigations

#### 1. **Bonding Curve Overflow (>37 ETH)**
The `ConstantProductBondingCurve` has numerical limits and will revert if `ethReserves > ~37 ETH`.

**Mitigation**: Graduation threshold (7.956 ETH) + max excess (0.5 ETH) = 8.456 ETH, well below 37 ETH limit.

#### 2. **ETH Donations to Uniswap V2 Pair Pre-Graduation**
Malicious actors could send ETH directly to the pair to manipulate the price at graduation.

**Mitigation**: `LivoGraduatorUniswapV2` includes:
- `sync()` call before reading reserves
- Price matching algorithm that transfers tokens directly to pair first
- Fallback to naive liquidity addition if needed
- Ensures Uniswap price ≥ bonding curve price

#### 3. **Large Last Purchase (Graduation Excess)**
If the last purchase before graduation is large (e.g., 0.5 ETH excess), the resulting Uniswap pool price will be higher than the bonding curve price.

**Impact**: The last buyer gets an immediate small profit. The larger the excess, the larger the instant price difference.

**Mitigation**: This is considered acceptable as it encourages graduation. The max excess of 0.5 ETH limits the maximum impact.

#### 4. **Token Transfers to Pool Before Graduation**
Tokens cannot be transferred to the liquidity pool before graduation.

**Mitigation**: `LivoToken._update()` blocks transfers to `pair` address before `graduated == true`.

#### 5. **DOS via Excessive Graduation Limit**
A user could try to buy exactly `threshold + MAX_THRESHOLD_EXCESS + 1 wei` to DOS token graduation.

**Mitigation**: The `buyTokensWithExactEth()` function reverts if `ethCollected + msg.value >= ethGraduationThreshold + MAX_THRESHOLD_EXCESS`.

#### 6. **Minimal Dust Tokens Burned at Graduation**
When adding liquidity to Uniswap V4, a small amount of tokens (~0.000001% of supply) may remain unallocated due to rounding.

**Impact**: Negligible ETH value (<$0.0004 at current prices).

**Mitigation**: Leftover tokens remain in graduator contract (effectively burned without gas cost).

### Admin Controls

The launchpad owner can:
- Update `tokenImplementation` (affects future tokens only)
- Update `baseEthGraduationThreshold` (affects future tokens only)
- Update `baseGraduationFee` (affects future tokens only)
- Update `baseBuyFeeBps` / `baseSellFeeBps` (affects future tokens only)
- Update `treasury` address
- Whitelist/un-whitelist bonding curve and graduator pairs

**Note**: Admin changes do NOT affect already-created tokens, only future deployments.

### No Rug Pull Vectors

- Launchpad does not have direct control over graduated tokens
- LP tokens are locked (V2: burned to `0xdEaD`, V4: locked in contract)
- No admin functions to withdraw user funds
- No pausing or emergency withdrawal mechanisms
- Creator cannot modify token after deployment

### Recommendations for Users

1. **Verify components**: Check that bonding curve and graduator are whitelisted
2. **Check graduation threshold**: Ensure it's the expected ~7.956 ETH
3. **Understand fee structure**: 1% trading fees + 0.5 ETH graduation fee
4. **Consider gas costs**: Uniswap V4 tokens are cheaper to deploy but require V4-compatible wallets/interfaces
5. **Creator fees (V4 only)**: Token creators earn 50% of LP fees on Uniswap V4 tokens

## Contract Addresses

_Deployment addresses will be added here after mainnet deployment._

## Testing

The protocol includes comprehensive test coverage:

```bash
# Run all tests
forge test

# Run specific test files
forge test --match-path test/launchpad/createTokens.t.sol
forge test --match-path test/launchpad/buyTokens.t.sol
forge test --match-path test/graduators/graduation.t.sol

# Run with gas reporting
forge test --gas-report

# Run with coverage
forge coverage
```

## License

MIT
