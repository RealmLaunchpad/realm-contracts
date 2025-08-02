# Livo Launchpad Technical Architecture

## Core Contracts

### 1. LaunchpadFactory
**Purpose**: Central factory for creating new token launches

**Functions**:
- `createToken(string name, string symbol, string metadata) external payable returns (address)`
- `setGraduationThreshold(uint256 ethAmount) external onlyOwner`
- `setFeeRecipient(address recipient) external onlyOwner`
- `setCreatorFeeShare(uint256 basisPoints) external onlyOwner`
- `getTokenCount() external view returns (uint256)`
- `getTokenByIndex(uint256 index) external view returns (address)`

**State Variables**:
- `graduationThreshold` (20 ETH)
- `tradingFeeBps` (100 = 1%)
- `graduationFee` (0.1 ETH)
- `creatorFeeBps` (5000 = 50%)
- `treasury` address
- Array of deployed tokens

### 2. BondingCurveToken
**Purpose**: Individual token contract with integrated bonding curve

**Functions**:
- `buy() external payable`
- `sell(uint256 tokenAmount) external`
- `getPrice() external view returns (uint256)`
- `getTotalEthCollected() external view returns (uint256)`
- `isGraduated() external view returns (bool)`
- `graduate() external`
- `emergencyWithdraw() external onlyCreator` (pre-graduation only)

**State Variables**:
- Standard ERC20 properties
- `creator` address
- `ethCollected` 
- `graduated` bool
- `bondingCurveSupply` (tokens available via bonding curve)
- `factory` address
- Chainlink price feed reference

**Bonding Curve Logic**:
- Linear curve: `price = basePrice + (ethCollected * priceSlope)`
- Initial price: 0.000001 ETH per token
- Price increases with ETH collected

### 3. LiquidityLocker
**Purpose**: Permanently locks Uniswap V2 LP tokens after graduation

**Functions**:
- `lockLiquidity(address lpToken, uint256 amount) external`
- `collectFees(address lpToken) external`
- `withdrawFees() external onlyOwner`

**State Variables**:
- Mapping of locked LP tokens
- Fee collection tracking

### 4. GraduationManager
**Purpose**: Handles the graduation process and Uniswap V2 integration

**Functions**:
- `graduateToken(address tokenAddress) external`
- `checkGraduationEligibility(address tokenAddress) external view returns (bool)`

**Dependencies**:
- Uniswap V2 Router
- Uniswap V2 Factory
- Chainlink ETH/USD price feed

## Architecture Flow

### Phase 1: Token Creation & Bonding Curve
1. User calls `LaunchpadFactory.createToken()`
2. Factory deploys new `BondingCurveToken` contract
3. Token enters bonding curve phase
4. Users trade via `buy()` and `sell()` functions
5. 1% trading fee split 50/50 between creator and treasury

### Phase 2: Graduation Process
1. Token reaches 20 ETH collected threshold
2. Anyone can call `BondingCurveToken.graduate()`
3. Contract calls `GraduationManager.graduateToken()`
4. Process:
   - Pay 0.1 ETH graduation fee to treasury
   - Mint 1% of supply to creator
   - Create Uniswap V2 pair with remaining ETH and tokens
   - Lock LP tokens in `LiquidityLocker`
   - Disable bonding curve trading

## Token Economics

### Supply Distribution
- **Total Supply**: 1,000,000,000 tokens
- **Bonding Curve**: 800,000,000 tokens (80%)
- **Creator Reward**: 10,000,000 tokens (1% - minted at graduation)
- **Liquidity**: Remaining tokens go to Uniswap V2

### Fee Structure
- **Trading Fee**: 1% on bonding curve trades
- **Graduation Fee**: 0.1 ETH
- **Fee Distribution**: 50/50 creator/treasury (configurable for new tokens)

## Security Considerations

### Access Controls
- Factory owner can update parameters
- Only factory can deploy tokens
- Only creator can emergency withdraw (pre-graduation)
- Graduated tokens cannot return to bonding curve

### Reentrancy Protection
- All external calls use reentrancy guards
- State updates before external calls
- Pull payment pattern for fee distributions

### Oracle Security
- Chainlink ETH/USD feed for market cap calculations
- Graduation based on ETH amount (not USD) to avoid oracle manipulation
- Fallback mechanisms for oracle failures

## Technical Dependencies

### External Contracts
- **Uniswap V2 Router**: `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`
- **Uniswap V2 Factory**: `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f`
- **Chainlink ETH/USD**: `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`

### Libraries
- OpenZeppelin Contracts (ERC20, Ownable, ReentrancyGuard)
- Chainlink price feeds
- Uniswap V2 interfaces

## Deployment Strategy

1. Deploy `LaunchpadFactory`
2. Deploy `LiquidityLocker` 
3. Deploy `GraduationManager`
4. Configure factory parameters
5. Set up frontend integration points

## Gas Optimization

- Minimal proxy pattern for token deployments
- Batch operations where possible
- Efficient storage packing
- View function optimizations for frontend queries