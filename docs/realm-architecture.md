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
    DirectFactory[RealmFactoryUniV4Direct]
    GraduatorV4[RealmDirectGraduatorUniV4]
    SwapHook[RealmHook / RealmHookAnyPair]
    LpFeeRouter[SwapLpFeeRouter]

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

    %% Direct V4 launch (no curve)
    Creator -->|createToken| DirectFactory
    DirectFactory -->|graduateToken| GraduatorV4
    GraduatorV4 -->|seeds single-sided,<br/>holds LP NFTs| UniV4


    %% Trading Flow (Post-Graduation)
    TraderPost -->|swaps| UniV2

    %% V4 Tax System
    UniV4 -->|hooks| SwapHook
    SwapHook -->|reads tax config,<br/>collects buy/sell tax| Token

    %% LP fee routing (V4)
    SwapHook -->|forwards LP fee| LpFeeRouter

    %% Styling
    classDef actor fill:#e1f5ff,stroke:#0288d1,stroke-width:2px
    classDef core fill:#fff3e0,stroke:#f57c00,stroke-width:3px
    classDef graduator fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    classDef external fill:#e8f5e9,stroke:#388e3c,stroke-width:2px

    class Creator,Trader actor
    class Launchpad,Token,BondingCurve core
    class DirectFactory,GraduatorV2,GraduatorV4,SwapHook,LpFeeRouter graduator
    class UniV2,UniV4 external
```

## Key Fund Flows

### 1. Token Creation
- **Creator** calls `createToken()` on **RealmLaunchpad**
- Launchpad deploys a **RealmToken** or **RealmTaxableTokenUniV2**
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

#### Direct V4 launch (no curve)
V4 tokens never touch the launchpad or a bonding curve:
- **Creator** calls `createToken()` on **RealmFactoryUniV4Direct**
- **RealmDirectGraduatorUniV4** creates 1-3 **Uniswap V4 Pools** at creator-chosen prices (native pools on **RealmHook**, ERC20-quoted pools on **RealmHookAnyPair**), seeds the supply as single-sided token bands and executes the optional dev buy, all in the creation tx
- The token is graduated from birth; the graduator holds the position NFTs forever (the liquidity lock). No graduation fee
- The hook reads each token's fees via `getSwapFees()` and forwards the LP fee and any tax on every swap

### 4. Post-Graduation Fee Collection (V4 only)
- The hook forwards the LP fee to **SwapLpFeeRouter**, which splits it 70/30 between the creator (via `RealmMasterFeeHandler`) and the protocol treasury
- Creators claim their share from `RealmMasterFeeHandler`
