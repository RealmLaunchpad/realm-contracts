# Frontend Integration Changes: `refactor/factory-based-token-deployment`

Summary of all function signature and functionality changes that affect frontend integration compared to `main`.

---

## 1. Token Creation

- **Removed**: `LivoLaunchpad.createToken()` no longer exists on the launchpad.
- **New**: Token creation is now handled by factory contracts. Each factory may have different input arguments. There is no need to pass graduator, token implementation, bonding curve, etc. — they are hardcoded in each factory.

### `LivoFactoryBase` (for UniV2 and UniV4 tokens)

```solidity
// Single fee receiver
function createToken(
    string name,
    string symbol,
    address feeReceiver,
    bytes32 salt
) external returns (address token)

// Multiple fee receivers via fee splitter
function createTokenWithFeeSplit(
    string name,
    string symbol,
    address[] recipients,
    uint256[] sharesBps,  // must sum to 10_000
    bytes32 salt
) external returns (address token, address feeSplitter)
```

### `LivoFactoryTaxToken` (for UniV4 taxable tokens)

```solidity
// Single fee receiver + tax config
function createToken(
    string name,
    string symbol,
    address feeReceiver,
    bytes32 salt,
    uint16 sellTaxBps,          // max 500 (5%)
    uint32 taxDurationSeconds    // max 14 days
) external returns (address token)

// Multiple fee receivers via fee splitter + tax config
function createTokenWithFeeSplit(
    string name,
    string symbol,
    address[] recipients,
    uint256[] sharesBps,  // must sum to 10_000
    bytes32 salt,
    uint16 sellTaxBps,
    uint32 taxDurationSeconds
) external returns (address token, address feeSplitter)
```

**Notes:**
- `feeReceiver` is the address that accumulates fees in the fee handler. It can be an EOA or a fee splitter.
- `salt` is used for deterministic clone deployment (combined with `msg.sender`, `block.timestamp`, and `symbol`).
- `createTokenWithFeeSplit()` deploys a `LivoFeeSplitter` clone that acts as the `feeReceiver`, splitting fees among multiple recipients.

---


## 2. Fee Claiming

Fee management is now handled by dedicated fee handler contracts instead of the graduator. Each token points to its fee handler via `token.feeHandler()`.

### Which contract to call `claim()` on?

Always ask for `ILivoToken.feeHandler()`, and that fee handler will expose:
- `feeHandler.getClaimable(address[] tokens, address account)`
- `feeHandler.claim(address[] tokens)`

However, `getClaimable()` won't be necessary, as we read it directly from envio. More on that in another document. So the only relevant one here is to call `claim()` on the `tokenData.feeHandler` read from envio.




---

## 4. Token Info (view functions on `ILivoToken`)

New view functions available on each token contract:

```solidity
function owner() external view returns (address)              // token owner
function proposedOwner() external view returns (address)       // pending ownership transfer
function feeHandler() external view returns (address)          // fee handler contract
function feeReceiver() external view returns (address)         // fee receiver (EOA or splitter)
function graduated() external view returns (bool)              // graduation status
function pair() external view returns (address)                // Uniswap pair/poolManager address
function graduator() external view returns (address)           // graduator contract

// Returns underlying recipients + shares. If feeReceiver is a splitter,
// returns the splitter's recipients. Otherwise returns [feeReceiver] with [10_000].
function getFeeReceivers() external view
    returns (address[] memory receivers, uint256[] memory sharesBps)

// Tax config (returns zeros for non-taxable tokens)
function getTaxConfig() external view returns (TaxConfig memory config)
// TaxConfig { buyTaxBps, sellTaxBps, taxDurationSeconds, graduationTimestamp }
```

**Taxable token only** (`LivoTaxableTokenUniV4`):
```solidity
function rescueTokens(address token) external  // owner only, pass address(0) for native ETH
```

---

## 5. Ownership Management

Ownership transfer has **moved from the launchpad to the token contract** and now uses a 2-step propose/accept pattern.

```solidity
// On the token contract (only current owner or launchpad):
function proposeNewOwner(address newOwner) external

// On the token contract (only proposed owner):
function acceptTokenOwnership() external

// On the token contract (only owner):
function setFeeReceiver(address newFeeReceiver) external
```

**`communityTakeOver()`** remains on the launchpad (admin only). It calls `proposeNewOwner()` on the token:
```solidity
// LivoLaunchpad (onlyOwner):
function communityTakeOver(address token, address newTokenOwner) external
```

---

## 6. Key Events (for indexer/frontend)

### Factory events (`ILivoFactory`)

```solidity
event TokenCreated(
    address indexed token, string name, string symbol,
    address tokenOwner, address launchpad, address graduator,
    address feeHandler, address feeReceiver
)

event FeeSplitterCreated(
    address indexed token, address indexed feeSplitter,
    address[] recipients, uint256[] sharesBps
)
```

### Launchpad events

```solidity
event TokenLaunched(address indexed token, uint256 graduationThreshold, uint256 maxExcessOverThreshold)
event TokenGraduated(address indexed token, uint256 ethCollected, uint256 tokensForGraduation)
event LivoTokenBuy(address indexed token, address indexed buyer, uint256 ethAmount, uint256 tokenAmount, uint256 ethFee)
event LivoTokenSell(address indexed token, address indexed seller, uint256 tokenAmount, uint256 ethAmount, uint256 ethFee)
event CommunityTakeOver(address indexed token, address newOwner)
```

### Token events (`ILivoToken`)

```solidity
event Graduated()
event NewOwnerProposed(address owner, address proposedOwner, address caller)
event OwnershipTransferred(address newOwner)
event FeeReceiverUpdated(address newFeeReceiver)
```

### Taxable token event

```solidity
event LivoTaxableTokenInitialized(uint16 buyTaxBps, uint16 sellTaxBps, uint40 taxDurationSeconds)
```

### Fee handler events (`ILivoFeeHandler`)

```solidity
event CreatorFeesDeposited(address indexed token, address indexed account, uint256 amount)
event TreasuryFeesDeposited(address token, uint256 amount)
```

### Claims event (`ILivoClaims` — emitted by fee handlers and fee splitters)

```solidity
event CreatorClaimed(address indexed token, address indexed account, uint256 amount)
```

### Fee splitter events (`ILivoFeeSplitter`)

```solidity
event SharesUpdated(address[] recipients, uint256[] sharesBps)
event FeesAccrued(uint256 amount)
```

### Hook event (`LivoSwapHook`)

```solidity
event CreatorTaxesAccrued(address indexed token, uint256 amount)
```
