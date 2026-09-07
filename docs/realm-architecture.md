# Realm Protocol Architecture

## System Overview

This diagram shows the main contracts and fund flows in the Realm protocol, including token creation, trading, and graduation to DEX liquidity.

```mermaid
graph TB
    %% Actors
    Creator([Creator])
    TraderPre([Trader])
    TraderPost([Trader])

    %% Main Contracts
    Launchpad[RealmLaunchpad]
    Token[RealmToken / RealmTaxableTokenUniV4]
    GraduatorV2[RealmGraduatorUniswapV2]
    GraduatorV4[RealmGraduatorUniswapV4]
    SwapHook[RealmSwapHook]
    LiquidityLock[LiquidityLockUniv4WithFees]

    %% External Systems
    UniV2[Uniswap V2 Pool]
    UniV4[Uniswap V4 Pool]

    %% Token Creation Flow
    Creator -->|createToken| Launchpad
    Launchpad -->|deploys| Token

    %% Trading Flow (Pre-Graduation)
    TraderPre -->|buyTokensWithExactEth/
    sellExactTokens| Launchpad
    Launchpad -->|queries price| BondingCurve

    %% Graduation Flow - V2
    Launchpad -->|_graduateToken| GraduatorV2
    GraduatorV2 -->|adds liquidity| UniV2

    TraderPost -->|swaps| UniV4

    %% Graduation Flow - V4
    Launchpad -->|_graduateToken| GraduatorV4
    GraduatorV4 -->|adds liquidity| UniV4
    GraduatorV4 -->|locks LP
     NFTs| LiquidityLock


    %% Trading Flow (Post-Graduation)
    TraderPost -->|swaps| UniV2

    %% V4 Tax System
    UniV4 -->|hooks| SwapHook
    SwapHook -->|reads tax config,<br/>collects buy/sell tax| Token

    %% Fee Collection (V4)
    Creator -->|collectEthFees| GraduatorV4
    GraduatorV4 -->|claims fees| LiquidityLock
    LiquidityLock -->|collects fees| UniV4

    %% Styling
    classDef actor fill:#e1f5ff,stroke:#0288d1,stroke-width:2px
    classDef core fill:#fff3e0,stroke:#f57c00,stroke-width:3px
    classDef graduator fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    classDef external fill:#e8f5e9,stroke:#388e3c,stroke-width:2px

    class Creator,Trader actor
    class Launchpad,Token,BondingCurve core
    class GraduatorV2,GraduatorV4,SwapHook,LiquidityLock graduator
    class UniV2,UniV4 external
```

## Key Fund Flows

### 1. Token Creation
- **Creator** calls `createToken()` on **RealmLaunchpad**
- Launchpad deploys a **RealmToken** or **RealmTaxableTokenUniV4**
- Assigns a **ConstantProductBondingCurve** for pricing

### 2. Pre-Graduation Trading
- **Trader** calls `buyTokensWithExactEth()` to purchase tokens
  - ETH sent to launchpad reserves
  - Trading fee taken to treasury
  - Bonding curve calculates token amount
- **Trader** calls `sellExactTokens()` to sell tokens
  - Tokens burned from circulation
  - ETH returned from reserves (minus fee)

### 3. Graduation (Triggered Automatically)
When ETH reserves reach graduation threshold:

#### V2 Graduation Path
- Launchpad calls `graduateToken()` on **RealmGraduatorUniswapV2**
- Creates **Uniswap V2 Pool** via `initialize()`
- Adds liquidity and locks LP tokens at dead address

#### V4 Graduation Path
- Launchpad calls `graduateToken()` on **RealmGraduatorUniswapV4**
- Creates **Uniswap V4 Pool** via `initialize()`
- Adds two liquidity positions (balanced + single-sided ETH)
- Locks LP NFTs in **LiquidityLockUniv4WithFees**
- **RealmSwapHook** reads each token's `TaxConfig` (`buyTaxBps`, `sellTaxBps`, `taxDurationSeconds`) and collects the configured buy/sell tax on every V4 swap while `block.timestamp <= graduationTimestamp + taxDurationSeconds`. The hook itself does not enforce any duration cap; the cap is enforced at creation by the factory (`MAX_TAX_DURATION_SECONDS = 365 days` for the default path, up to `MAX_CHARITY_TAX_DURATION_SECONDS = 120 years` in charity mode — a single non-deployer fee receiver and ownership renounced at creation; the charity address is NOT verified on-chain) and the resulting window is immutable on the token.

### 4. Post-Graduation Fee Collection (V4 only)
- **Creator** calls `collectEthFees()` on graduator
- Graduator claims fees from locked LP positions
- Splits 50/50 between creator and protocol treasury