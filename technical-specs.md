# Livo Launchpad Technical Architecture

## Core Contracts

### 1. LaunchpadFactory
**Purpose**: Central factory for creating new token launches

**Functions**:
- `createToken(string name, string symbol, string metadata) external payable returns (address)`
- `setGraduationThreshold(uint256 ethAmount) external onlyOwner`
- `setFeeRecipient(address recipient) external onlyOwner`
- `setCreatorFeeShare(uint256 basisPoints) external onlyOwner`

**State Variables**:
- `graduationThreshold` (20 ETH)
- `tradingFeeBps` (100 = 1%)
- `graduationFee` (0.1 ETH)
- `creatorFeeBps` (5000 = 50%)
- `treasury` address
- `preGraduationOrchestrator` address

**Notes**:
- `createToken` should use OpenZeppelin's clone for minimal proxy.
- `setGraduationThreshold` and `setCreatorFeeShare` should only affect future tokens, not already deployed ones.

### 2. LivoToken
**Purpose**: Standard ERC20 token with anti-bot protection and configurable fees

**Functions**:
- Standard ERC20 functions (`transfer`, `approve`, etc.)
- `setAntiBotProtection(bool enabled) external onlyFactory`
- `setBuyFee(uint256 basisPoints) external onlyFactory`
- `setSellFee(uint256 basisPoints) external onlyFactory`
- `setFeeExempt(address account, bool exempt) external onlyFactory`

**State Variables**:
- Standard ERC20 properties
- `creator` address
- `factory` address
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
- `canBeGraduated(address token) external view returns (bool)`
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

### 4. BondingCurves

Admins will deploy a number of bounding curves with the following pure functions. Admins can whitelist bonding curves such that the creators can chose between them in the PreGraduationOrchestrator.

**Purpose**: Individual bonding curve logic for each token

**Functions**:
- `getBuyPrice(uint256 ethAmount, uint256 totalSupply, uint256 ethSupply) external pure returns (uint256)`
- `getSellPrice(uint256 tokenAmount, uint256 totalSupply, uint256 ethSupply) external pure returns (uint256)`
- `getTokensForEth(uint256 ethAmount, uint256 totalSupply, uint256 ethSupply) external pure returns (uint256)`
- `getEthForTokens(uint256 tokenAmount, uint256 totalSupply, uint256 ethSupply) external pure returns (uint256)`

**Bonding Curve Logic**:
- Linear curve: `price = basePrice + (currentSupply * priceSlope)`
- Initial price: 0.000001 ETH per token
- Price increases with tokens sold

**Notes**:
The constants related to each bonding curve will be hardcoded as immutable/constants in the contracts themselves.

### 6. GraduationManagers

Admins will deploy one GraduationManager to begin with, but the Launchpad will be able to whitelist different graduation managers. In this way, we keep the graduation logic modularized and composable.

**Purpose**: Handles the graduation process and Uniswap V2 integration

**Functions**:
- `canBeGraduated(address tokenAddress) external view returns (bool)`
- `graduateToken(address tokenAddress) external`

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

## Gas Optimization

- Minimal proxy pattern for token deployments
- Efficient storage packing