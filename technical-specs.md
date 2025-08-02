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
- `preGraduationOrchestrator` address
- Array of deployed tokens

### 2. LivoToken
**Purpose**: Standard ERC20 token with anti-bot protection and configurable fees

**Functions**:
- Standard ERC20 functions (`transfer`, `approve`, etc.)
- `setAntiBotProtection(bool enabled) external onlyFactory`
- `setBuyFee(uint256 basisPoints) external onlyFactory`
- `setSellFee(uint256 basisPoints) external onlyFactory`
- `setFeeExempt(address account, bool exempt) external onlyFactory`
- `isGraduated() external view returns (bool)`
- `graduate() external onlyOrchestrator`

**State Variables**:
- Standard ERC20 properties
- `creator` address
- `factory` address
- `orchestrator` address
- `graduated` bool
- `antiBotEnabled` bool
- `buyFeeBps` uint256
- `sellFeeBps` uint256
- Mapping of fee-exempt addresses

### 3. PreGraduationOrchestrator
**Purpose**: Handles all pre-graduation trading, bonding curves, and token custody

**Functions**:
- `buyToken(address token) external payable`
- `sellToken(address token, uint256 tokenAmount) external`
- `getBuyPrice(address token, uint256 ethAmount) external view returns (uint256)`
- `getSellPrice(address token, uint256 tokenAmount) external view returns (uint256)`
- `getTotalEthCollected(address token) external view returns (uint256)`
- `checkGraduationEligibility(address token) external view returns (bool)`
- `graduateToken(address token) external`
- `emergencyWithdraw(address token) external onlyCreator`

**State Variables**:
- `mapping(address => address) tokenToBondingCurve` - Maps token to its bonding curve contract
- `mapping(address => TokenConfig) tokenConfigs` - Fee configurations per token
- `mapping(address => uint256) ethCollected` - ETH collected per token
- `mapping(address => bool) graduated` - Graduation status per token
- `mapping(address => address) tokenCreators` - Token creator mapping
- `factory` address
- `graduationManager` address

**TokenConfig Struct**:
```solidity
struct TokenConfig {
    uint256 tradingFeeBps;
    uint256 creatorFeeBps;
    uint256 bondingCurveSupply;
    bool active;
}
```

### 4. BondingCurve
**Purpose**: Individual bonding curve logic for each token

**Functions**:
- `getBuyPrice(uint256 ethAmount) external view returns (uint256)`
- `getSellPrice(uint256 tokenAmount) external view returns (uint256)`
- `getTokensForEth(uint256 ethAmount) external view returns (uint256)`
- `getEthForTokens(uint256 tokenAmount) external view returns (uint256)`

**State Variables**:
- `basePrice` uint256
- `priceSlope` uint256
- `currentSupply` uint256
- `maxSupply` uint256

**Bonding Curve Logic**:
- Linear curve: `price = basePrice + (currentSupply * priceSlope)`
- Initial price: 0.000001 ETH per token
- Price increases with tokens sold

### 5. LiquidityLocker
**Purpose**: Permanently locks Uniswap V2 LP tokens after graduation

**Functions**:
- `lockLiquidity(address lpToken, uint256 amount) external`
- `collectFees(address lpToken) external`
- `withdrawFees() external onlyOwner`

**State Variables**:
- Mapping of locked LP tokens
- Fee collection tracking

### 6. GraduationManager
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
2. Factory deploys new `LivoToken` contract (standard ERC20)
3. Factory deploys dedicated `BondingCurve` contract for the token
4. Factory registers token with `PreGraduationOrchestrator`
5. Orchestrator holds 80% of token supply for bonding curve trading
6. Users trade via `PreGraduationOrchestrator.buyToken()` and `sellToken()`
7. 1% trading fee split 50/50 between creator and treasury

### Phase 2: Graduation Process
1. Token reaches 20 ETH collected threshold in `PreGraduationOrchestrator`
2. Anyone can call `PreGraduationOrchestrator.graduateToken()`
3. Orchestrator calls `GraduationManager.graduateToken()`
4. Process:
   - Pay 0.1 ETH graduation fee to treasury
   - Transfer 1% of supply to creator
   - Transfer remaining tokens and ETH to `GraduationManager`
   - Create Uniswap V2 pair with tokens and ETH
   - Lock LP tokens in `LiquidityLocker`
   - Mark token as graduated in both `LivoToken` and `PreGraduationOrchestrator`

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

1. Deploy `LiquidityLocker`
2. Deploy `GraduationManager`
3. Deploy `PreGraduationOrchestrator`
4. Deploy `LaunchpadFactory`
5. Configure factory parameters and contract addresses
6. Set up frontend integration points

## Gas Optimization

- Minimal proxy pattern for token deployments
- Batch operations where possible
- Efficient storage packing
- View function optimizations for frontend queries