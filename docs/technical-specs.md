# Livo Launchpad Technical Architecture

## Core Contracts

### 1. LivoLaunchpad
**Purpose**: Central contract for creating new token launches, handling pre-graduation trading, bonding curves, and token custody

**Permissionless Functions**:
- `createToken(string name, string symbol, string metadata, address bondingCurve, address graduationManager) external payable returns (address)`
- `buyToken(address token) external payable`
- `sellToken(address token, uint256 tokenAmount) external`
- `graduateToken(address token) external`
**OnlyOwner Functions**:
- `setGraduationThreshold(uint256 ethAmount) external onlyOwner`
- `setFeeRecipient(address recipient) external onlyOwner`
- `setCreatorFeeShare(uint256 basisPoints) external onlyOwner`
- `whitelistGraduationManager(address graduationManager, bool whitelisted) external onlyOwner`
**View Functions**:
- `checkGraduationEligibility(address token) external view returns (bool)`
- `isGraduated(address token) external view returns (bool)`
- `getBuyPrice(address token, uint256 ethAmount) external view returns (uint256)`
- `getSellPrice(address token, uint256 tokenAmount) external view returns (uint256)`
- `getEthCollectedByToken(address token) external view returns (uint256)`

**State Variables**:
- `graduationThreshold` (20 ETH)
- `tradingFeeBps` (100 = 1%)
- `graduationFee` (0.1 ETH)
- `creatorFeeBps` (5000 = 50%)
- `treasury` address
- `graduationManager` address (ILivoGraduator) - legacy, kept for backwards compatibility
- `mapping(address => bool) whitelistedGraduationManagers` - Whitelisted graduation managers
- `mapping(address => TokenData) tokens` - Consolidated token data mapping

**TokenData Struct**:
```solidity
struct TokenData {
    address bondingCurve;        // ILivoBoundingCurve compliant contract
    address creator;             // Token creator address
    address graduationManager;   // ILivoGraduator compliant contract assigned to this token
    uint256 ethCollected;        // ETH collected from trading
    uint256 creatorFeesCollected;// ETH fees collected for the creator
    uint96 buyFeeBps;           // Buy trading fee basis points
    uint96 sellFeeBps;          // Sell trading fee basis points
    uint96 creatorFeeBps;       // Creator fee basis points
    bool graduated;              // Graduation status
}
```

**Notes**:
- `createToken` should use OpenZeppelin's clone for minimal proxy.
- `setGraduationThreshold` and `setCreatorFeeShare` should only affect future tokens, not already deployed ones.
- Holds all created tokens and all ETH from purchases until each token is graduated
- Each token has its own bonding curve via the mapping to ILivoBoundingCurve compliant contracts
- Each token has its own graduation manager selected at creation time from whitelisted options
- Each token has its own fee structure via TokenData
- Admins can whitelist/unwhitelist graduation managers via `whitelistGraduationManager()`
- Token creators choose their preferred graduation manager at token creation from whitelisted options

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

**Notes:** 
- inherits ERC20 from Openzeppelin 

### 3. BondingCurves

Admins will deploy a number of bounding curves with the following pure functions. Admins can whitelist bonding curves such that the creators can chose between them in the LivoLaunchpad.

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

### 4. GraduationManagers

Admins will deploy one GraduationManager to begin with, but the Launchpad will be able to whitelist different graduation managers. In this way, we keep the graduation logic modularized and composable.

**Purpose**: Handles the graduation process and Uniswap V2 integration

**Functions**:
- `checkGraduationEligibility(address tokenAddress) external view returns (bool)`
- `graduateToken(address tokenAddress) external`

**Dependencies**:
- Uniswap V2 Router
- Uniswap V2 Factory
- Chainlink ETH/USD price feed

## Architecture Flow

### Phase 1: Token Creation & Bonding Curve
0. Admins deploy and whitelist valid BondingCurve and GraduationManager contracts
1. User creates token with `LivoLaunchpad.createToken()`, choosing from whitelisted bonding curves and graduation managers
2. LivoLaunchpad deploys new `LivoToken` contract (standard ERC20) mapping the token to specified bonding curve and graduation manager
3. Users trade via `LivoLaunchpad.buyTokensWithExactEth()` and `sellToken()`
4. 1% trading fee split 50/50 between creator and treasury

### Phase 2: Graduation Process
1. Token reaches 20 ETH collected threshold in `LivoLaunchpad`, then `checkGraduationEligibility(token)` returns True.
2. Anyone can call `LivoLaunchpad.graduateToken()`
4. Process:
   - Pay 0.1 ETH graduation fee to treasury
   - Transfer 1% of supply to creator  (TBD??)
   - Transfer remaining tokens and ETH to the token's specific `GraduationManager` (chosen at creation)
   - Graduation manager handles liquidity creation according to its implementation
   - Mark token as graduated in both `LivoToken` and `LivoLaunchpad`

## Gas Optimization

- Minimal proxy pattern for token deployments
- Efficient storage packing