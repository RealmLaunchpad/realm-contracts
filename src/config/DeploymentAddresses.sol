// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Deployment Address Constants for Ethereum Mainnet
/// @notice Centralized constants for protocol infrastructure addresses on Ethereum Mainnet
/// @dev These addresses are network-specific and must be updated for other chains
library DeploymentAddressesEthereumMainnet {
    /// @notice Blockchain ID for Ethereum Mainnet
    uint256 public constant BLOCKCHAIN_ID = 1;

    /// @notice Uniswap V4 Pool Manager contract
    /// @dev Core contract managing all V4 pools and their lifecycle
    address public constant UNIV4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @notice Uniswap V4 Position Manager contract
    /// @dev Manages liquidity positions for V4 pools
    address public constant UNIV4_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;

    /// @notice Uniswap V4 Universal Router contract
    /// @dev Handles routing and execution of V4 swaps
    address public constant UNIV4_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    /// @notice Permit2 contract
    /// @dev Token approval contract used across multiple protocols
    /// @dev Note: Permit2 may be deployed at the same address on multiple chains
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Wrapped Ether (WETH) token contract
    /// @dev Official WETH contract for Ethereum Mainnet
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Uniswap V2 Router contract
    /// @dev Handles routing and execution of V2 swaps
    address public constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    /// @notice Uniswap V2 Factory contract
    /// @dev Creates and manages V2 pair contracts
    address public constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    /// @notice keccak256 of the UniswapV2Pair contract creation code used by UNIV2_FACTORY
    /// @dev Required by `RealmGraduatorUniswapV2` to predict the CREATE2 pair address without
    ///      deploying the pair upfront. Canonical stock UniswapV2 value.
    bytes32 public constant UNIV2_PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    /// @notice Dead address used for burning LP tokens
    /// @dev Standard burn address that works on all chains
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Max native amount (wei) a taxable token's `processBurn`/`processLiquidity` processes per call.
    /// @dev With the once-per-block cooldown, caps what a price-manipulation sandwich can extract from the
    ///      earnings buffers PER BLOCK; the remainder stays buffered for later calls. It does not bound
    ///      the fraction of a single call that can be taken — only the keeper gate does that. See
    ///      `DividendDistribution.MAX_DIVIDEND_PER_CONVERSION`.
    uint256 public constant MAX_EARNINGS_PER_PROCESS = 0.2 ether;

    /// @notice Minimum accrued native amount the dividend buffer must hold before
    ///         `processDividends` may convert it and stream it to holders. Per-chain because a wei value
    ///         cannot be shared between an ETH chain and a USDC-native one. Bypassed only once the
    ///         token has gone `STALE_DIVIDEND_WINDOW` without a distribution, so a sub-threshold residual
    ///         on a dead token can never strand.
    uint256 public constant DIVIDEND_THRESHOLD = 0.1 ether;

    /// @notice Gas forwarded to a holder's `receive()` on a NATIVE dividend payout in a keeper batch.
    /// @dev Bounded so one holder with an expensive (or reverting) fallback cannot starve the rest of a
    ///      batch. Per-chain because the wallets in common use differ per chain and the ceiling is a
    ///      property of them, not of the protocol. It is NOT an eligibility gate: a holder who needs
    ///      more can always call `claimDividends()`, which forwards all remaining gas.
    uint256 public constant NATIVE_PAYOUT_GAS = 50_000;

    /// @notice Flat amount of native the `RealmDividendSwapRegistry` diverts to the keeper wallet on each
    ///         `swapNativeToAsset`, as gas money for the conversion that keeper just paid for.
    /// @dev SIZED AS A MULTIPLE OF ONE CONVERSION'S GAS, not as a share of the conversion. Gas is an
    ///      absolute cost, so a percentage would starve the keeper on a small conversion and overcharge
    ///      holders on a large one — and the conversion band is narrow anyway
    ///      (`DIVIDEND_THRESHOLD`..`MAX_EARNINGS_PER_PROCESS`). Deliberately generous: an underfunded
    ///      keeper stops every token's distributions at once, while an over-generous one costs holders a
    ///      few basis points of one conversion.
    /// @dev A constant rather than a stored setting because the registry is a proxy — repricing it is an
    ///      upgrade, which is the right cadence for a number that moves with gas regimes, not with the
    ///      market. Per-chain for the same reason `DIVIDEND_THRESHOLD` is.
    /// @dev ~300k gas at 20 gwei is ~0.006 ETH, so this is roughly break-even at that regime. NOT
    ///      DEPLOYED HERE: dividends ship on Robinhood Chain only, and this value exists so the mainnet
    ///      library stays a complete config, not because anything reads it today.
    uint256 public constant KEEPER_FEE = 0.005 ether;

    /// @notice The `RealmDividendSwapRegistry` proxy: the eligibility gate for a third-asset dividend
    ///         payout and the venue its native -> asset conversion crosses.
    /// @dev ⚠️ PLACEHOLDER — NOT DEPLOYED YET on this chain. The leading zeros and the `D1d3ADd5` tail
    ///      are the tell; it is deliberately NOT `address(0)`, because tests have to `etch` a working
    ///      registry AT this address and most ERC20s (USDC included) revert on a `transfer` to the zero
    ///      address, which would make every third-asset payout untestable.
    /// @dev What actually enforces "remember to update this" is not the value but the assertion: every
    ///      script that deploys a taxable token implementation requires
    ///      `DIVIDEND_SWAP_REGISTRY.code.length != 0` before broadcasting. Deploy the registry proxy
    ///      first, paste it here, then deploy the impls — they bake this in as a constant and clones
    ///      cannot be repointed.
    /// @dev Left unset, everything fails closed: `_initializeDividends` reverts on the codeless registry
    ///      so no third-asset token can be created, and `_swapNativeToDividendAsset`'s `code.length`
    ///      guard stops a conversion handing its native to an address that cannot give it back. Native
    ///      and self-token payouts are unaffected either way.
    address public constant DIVIDEND_SWAP_REGISTRY = 0x00000000000000000000000000000000D1d3ADd5;

    /// @notice The `RealmKeepersRegistry`: the set of addresses allowed to trigger a token's out-of-band
    ///         earnings conversions (`processDividends`, `processBurn`, `processLiquidity`).
    /// @dev ⚠️ PLACEHOLDER — NOT DEPLOYED YET on this chain. The `CeEbEe95` tail is the tell; it is
    ///      deliberately NOT `address(0)` so tests can `etch` a working registry AT this address, the
    ///      same convention `DIVIDEND_SWAP_REGISTRY` uses.
    /// @dev Baked into token implementations as a constant, so deploy the registry first and paste it
    ///      here; the impl deploy scripts assert it has code before broadcasting. Left unset everything
    ///      fails closed — `_requireKeeper` reverts on the codeless address, so no conversion runs at
    ///      all, which is the safe direction for a gate.
    address public constant REALM_KEEPERS_REGISTRY = 0x00000000000000000000000000000000CeEbEe95;
    /// @notice Realm Treasury. TEMPORARY: the `realm.dev` EOA stands in until Realm has its own
    ///         treasury — replace before production. Consumed by core contracts at deploy time.
    address public constant REALM_TREASURY = 0x1a209bB4d0bC40f169c06dC2808d7d512Aea62bb;
}

/// @title Deployment Address Constants for Sepolia Testnet
/// @notice Centralized constants for protocol infrastructure addresses on Sepolia Testnet
library DeploymentAddressesEthereumSepolia {
    /// @notice Blockchain ID for Sepolia Testnet
    uint256 public constant BLOCKCHAIN_ID = 11155111;

    /// @notice Uniswap V4 Pool Manager contract
    address public constant UNIV4_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    /// @notice Uniswap V4 Position Manager contract
    address public constant UNIV4_POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;

    /// @notice Uniswap V4 Universal Router contract
    address public constant UNIV4_UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;

    /// @notice Permit2 contract
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Wrapped Ether (WETH) token contract
    address public constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9; // this is WETH deployed by uniswap for uniswap tests

    /// @notice Uniswap V2 Router contract
    address public constant UNIV2_ROUTER = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;

    /// @notice Uniswap V2 Factory contract
    address public constant UNIV2_FACTORY = 0x7E0987E5b3a30e3f2828572Bb659A548460a3003;

    /// @notice keccak256 of the UniswapV2Pair contract creation code used by UNIV2_FACTORY
    /// @dev Required by `RealmGraduatorUniswapV2` to predict the CREATE2 pair address without
    ///      deploying the pair upfront. The Sepolia factory at `UNIV2_FACTORY` is NOT Uniswap's
    ///      canonical V2 deployment — it's a fork whose pair init code differs from mainnet, so
    ///      the hash here is different from the stock mainnet value. Derived empirically from the
    ///      CREATE2 input of a pair created by this factory; verified by predicting a known pair.
    bytes32 public constant UNIV2_PAIR_INIT_CODE_HASH =
        0x4156ccc01dad273e6c65c4335c428a2ff4a4b0c95a9a228f6bfed45a069d3fe7;

    /// @notice Dead address used for burning LP tokens
    /// @dev Standard burn address that works on all chains
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Max native amount (wei) a taxable token's `processBurn`/`processLiquidity` processes per call.
    /// @dev See the mainnet library for the rationale (sandwich-extraction cap).
    uint256 public constant MAX_EARNINGS_PER_PROCESS = 0.2 ether;

    /// @notice Minimum accrued native amount the dividend buffer must hold before
    ///         `processDividends` may convert it and stream it to holders. Per-chain because a wei value
    ///         cannot be shared between an ETH chain and a USDC-native one. Bypassed only once the
    ///         token has gone `STALE_DIVIDEND_WINDOW` without a distribution, so a sub-threshold residual
    ///         on a dead token can never strand.
    uint256 public constant DIVIDEND_THRESHOLD = 0.001 ether;

    /// @notice Gas forwarded to a holder's `receive()` on a NATIVE dividend payout in a keeper batch.
    /// @dev Bounded so one holder with an expensive (or reverting) fallback cannot starve the rest of a
    ///      batch. Per-chain because the wallets in common use differ per chain and the ceiling is a
    ///      property of them, not of the protocol. It is NOT an eligibility gate: a holder who needs
    ///      more can always call `claimDividends()`, which forwards all remaining gas.
    uint256 public constant NATIVE_PAYOUT_GAS = 50_000;

    /// @notice Flat amount of native the `RealmDividendSwapRegistry` diverts to the keeper wallet on each
    ///         `swapNativeToAsset`, as gas money for the conversion that keeper just paid for.
    /// @dev SIZED AS A MULTIPLE OF ONE CONVERSION'S GAS, not as a share of the conversion. Gas is an
    ///      absolute cost, so a percentage would starve the keeper on a small conversion and overcharge
    ///      holders on a large one — and the conversion band is narrow anyway
    ///      (`DIVIDEND_THRESHOLD`..`MAX_EARNINGS_PER_PROCESS`). Deliberately generous: an underfunded
    ///      keeper stops every token's distributions at once, while an over-generous one costs holders a
    ///      few basis points of one conversion.
    /// @dev A constant rather than a stored setting because the registry is a proxy — repricing it is an
    ///      upgrade, which is the right cadence for a number that moves with gas regimes, not with the
    ///      market. Per-chain for the same reason `DIVIDEND_THRESHOLD` is.
    /// @dev Testnet gas is free-ish and the threshold here is 100x smaller than mainnet's; this is only
    ///      large enough to prove the plumbing moves money.
    uint256 public constant KEEPER_FEE = 0.0001 ether;

    /// @notice The `RealmDividendSwapRegistry` proxy: the eligibility gate for a third-asset dividend
    ///         payout and the venue its native -> asset conversion crosses.
    /// @dev Deployed by `DeployRealmPrereqs`; owner is `REALM_TREASURY`.
    /// @dev What actually enforces "remember to update this" is not the value but the assertion: every
    ///      script that deploys a taxable token implementation requires
    ///      `DIVIDEND_SWAP_REGISTRY.code.length != 0` before broadcasting. Deploy the registry proxy
    ///      first, paste it here, then deploy the impls — they bake this in as a constant and clones
    ///      cannot be repointed.
    /// @dev Left unset, everything fails closed: `_initializeDividends` reverts on the codeless registry
    ///      so no third-asset token can be created, and `_swapNativeToDividendAsset`'s `code.length`
    ///      guard stops a conversion handing its native to an address that cannot give it back. Native
    ///      and self-token payouts are unaffected either way.
    address public constant DIVIDEND_SWAP_REGISTRY = 0x9b3c560D86909B8116468536737a272Fe0cE327d;

    /// @notice The `RealmKeepersRegistry`: the set of addresses allowed to trigger a token's out-of-band
    ///         earnings conversions (`processDividends`, `processBurn`, `processLiquidity`).
    /// @dev Deployed by `DeployRealmPrereqs`; owner is `REALM_TREASURY`.
    /// @dev Baked into token implementations as a constant, so deploy the registry first and paste it
    ///      here; the impl deploy scripts assert it has code before broadcasting. Left unset everything
    ///      fails closed — `_requireKeeper` reverts on the codeless address, so no conversion runs at
    ///      all, which is the safe direction for a gate.
    address public constant REALM_KEEPERS_REGISTRY = 0xCba49A6057256392cF480C17C81DF2170FB650CB;
    /// @notice Realm Treasury. TEMPORARY: the `realm.dev` EOA stands in until Realm has its own
    ///         treasury — replace before production. Consumed by core contracts at deploy time.
    address public constant REALM_TREASURY = 0x1a209bB4d0bC40f169c06dC2808d7d512Aea62bb;
}

/// @title Deployment Address Constants for Robinhood Chain Mainnet (chain id 4663)
/// @notice Centralized constants for protocol infrastructure addresses on Robinhood Chain.
/// @dev Robinhood Chain is an Arbitrum L2 with native ETH. Uniswap V4 + V2 are officially
///      deployed (verified on-chain). The V2 factory uses the CANONICAL UniswapV2 pair init
///      code hash (verified by predicting an existing pair). Permit2 is at the canonical address.
library DeploymentAddressesRobinhoodMainnet {
    /// @notice Blockchain ID for Robinhood Chain Mainnet
    uint256 public constant BLOCKCHAIN_ID = 4663;

    /// @notice Uniswap V4 Pool Manager contract
    address public constant UNIV4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    /// @notice Uniswap V4 Position Manager contract
    address public constant UNIV4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    /// @notice Uniswap V4 Universal Router contract
    address public constant UNIV4_UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;

    /// @notice Permit2 contract (canonical address)
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Wrapped Ether (WETH) token contract
    address public constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// @notice Uniswap V2 Router contract
    address public constant UNIV2_ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;

    /// @notice Uniswap V2 Factory contract
    address public constant UNIV2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;

    /// @notice keccak256 of the UniswapV2Pair contract creation code used by UNIV2_FACTORY
    /// @dev Robinhood's official V2 factory uses the CANONICAL UniswapV2 pair init code hash
    ///      (same as Ethereum mainnet). Verified by predicting an existing pair created by this
    ///      factory and matching `getPair()`.
    bytes32 public constant UNIV2_PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    /// @notice Dead address used for burning LP tokens
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Max native amount (wei) a taxable token's `processBurn`/`processLiquidity` processes per call.
    /// @dev See the Ethereum mainnet library for the rationale (sandwich-extraction cap).
    uint256 public constant MAX_EARNINGS_PER_PROCESS = 0.2 ether;

    /// @notice Minimum accrued native amount the dividend buffer must hold before
    ///         `processDividends` may convert it and stream it to holders. Per-chain because a wei value
    ///         cannot be shared between an ETH chain and a USDC-native one. Bypassed only once the
    ///         token has gone `STALE_DIVIDEND_WINDOW` without a distribution, so a sub-threshold residual
    ///         on a dead token can never strand.
    uint256 public constant DIVIDEND_THRESHOLD = 0.1 ether;

    /// @notice Gas forwarded to a holder's `receive()` on a NATIVE dividend payout in a keeper batch.
    /// @dev Bounded so one holder with an expensive (or reverting) fallback cannot starve the rest of a
    ///      batch. Per-chain because the wallets in common use differ per chain and the ceiling is a
    ///      property of them, not of the protocol. It is NOT an eligibility gate: a holder who needs
    ///      more can always call `claimDividends()`, which forwards all remaining gas.
    uint256 public constant NATIVE_PAYOUT_GAS = 50_000;

    /// @notice Flat amount of native the `RealmDividendSwapRegistry` diverts to the keeper wallet on each
    ///         `swapNativeToAsset`, as gas money for the conversion that keeper just paid for.
    /// @dev SIZED AS A MULTIPLE OF ONE CONVERSION'S GAS, not as a share of the conversion. Gas is an
    ///      absolute cost, so a percentage would starve the keeper on a small conversion and overcharge
    ///      holders on a large one — and the conversion band is narrow anyway
    ///      (`DIVIDEND_THRESHOLD`..`MAX_EARNINGS_PER_PROCESS`). Deliberately generous: an underfunded
    ///      keeper stops every token's distributions at once, while an over-generous one costs holders a
    ///      few basis points of one conversion.
    /// @dev A constant rather than a stored setting because the registry is a proxy — repricing it is an
    ///      upgrade, which is the right cadence for a number that moves with gas regimes, not with the
    ///      market. Per-chain for the same reason `DIVIDEND_THRESHOLD` is.
    /// @dev THE ONE THAT MATTERS — dividends ship here. Deliberately over-provisioned: an Arbitrum L2
    ///      conversion costs a tiny fraction of this even with the L1 data fee, so the fee survives an
    ///      L1 fee spike, a stretch of conversions that revert on their floor, and a gas regime nobody
    ///      forecast — the cost of being wrong the other way is every token's distributions stopping at
    ///      once. It is ~2% of a threshold-sized conversion (0.1 ETH) and ~1% of a maximum one.
    uint256 public constant KEEPER_FEE = 0.002 ether;

    /// @notice The `RealmDividendSwapRegistry` proxy: the eligibility gate for a third-asset dividend
    ///         payout and the venue its native -> asset conversion crosses.
    /// @dev ⚠️ PLACEHOLDER — NOT DEPLOYED YET on this chain. The leading zeros and the `D1d3ADd5` tail
    ///      are the tell; it is deliberately NOT `address(0)`, because tests have to `etch` a working
    ///      registry AT this address and most ERC20s (USDC included) revert on a `transfer` to the zero
    ///      address, which would make every third-asset payout untestable.
    /// @dev What actually enforces "remember to update this" is not the value but the assertion: every
    ///      script that deploys a taxable token implementation requires
    ///      `DIVIDEND_SWAP_REGISTRY.code.length != 0` before broadcasting. Deploy the registry proxy
    ///      first, paste it here, then deploy the impls — they bake this in as a constant and clones
    ///      cannot be repointed.
    /// @dev Left unset, everything fails closed: `_initializeDividends` reverts on the codeless registry
    ///      so no third-asset token can be created, and `_swapNativeToDividendAsset`'s `code.length`
    ///      guard stops a conversion handing its native to an address that cannot give it back. Native
    ///      and self-token payouts are unaffected either way.
    address public constant DIVIDEND_SWAP_REGISTRY = 0x00000000000000000000000000000000D1d3ADd5;

    /// @notice The `RealmKeepersRegistry`: the set of addresses allowed to trigger a token's out-of-band
    ///         earnings conversions (`processDividends`, `processBurn`, `processLiquidity`).
    /// @dev ⚠️ PLACEHOLDER — NOT DEPLOYED YET on this chain. The `CeEbEe95` tail is the tell; it is
    ///      deliberately NOT `address(0)` so tests can `etch` a working registry AT this address, the
    ///      same convention `DIVIDEND_SWAP_REGISTRY` uses.
    /// @dev Baked into token implementations as a constant, so deploy the registry first and paste it
    ///      here; the impl deploy scripts assert it has code before broadcasting. Left unset everything
    ///      fails closed — `_requireKeeper` reverts on the codeless address, so no conversion runs at
    ///      all, which is the safe direction for a gate.
    address public constant REALM_KEEPERS_REGISTRY = 0x00000000000000000000000000000000CeEbEe95;
    /// @notice Realm Treasury. Consumed by core contracts at deploy time.
    address public constant REALM_TREASURY = 0x7826AaE926AfD2886257976770e93e0240D2426e;
}

/// @title Deployment Address Constants for Robinhood Chain Testnet (chain id 46630)
/// @notice Centralized constants for protocol infrastructure addresses on Robinhood Chain Testnet.
/// @dev Uniswap V4 + Permit2 are deployed; the V4 set below is the one whose PositionManager
///      reports this chain's canonical WETH. Uniswap V2 is NOT natively on the testnet, so Realm
///      deployed a stock UniswapV2 instance (Factory + Router02) from Uniswap's CANONICAL creation
///      bytecode (via `just deploy-univ2-robintest`); the pair init code hash is therefore the
///      canonical mainnet value.
library DeploymentAddressesRobinhoodTestnet {
    /// @notice Blockchain ID for Robinhood Chain Testnet
    uint256 public constant BLOCKCHAIN_ID = 46630;

    /// @notice Uniswap V4 Pool Manager contract
    address public constant UNIV4_POOL_MANAGER = 0x552815eF68E6eb418A3d65D0AA1043d93204F612;

    /// @notice Uniswap V4 Position Manager contract
    address public constant UNIV4_POSITION_MANAGER = 0x00EB6902D1e3be1A8C667041f9E75b77B7Ad3ba6;

    /// @notice Uniswap V4 Universal Router contract
    /// @dev Realm-deployed. The chain's pre-existing router (0xE28c…) is an old pre-V4 UniversalRouter
    ///      (no `unlockCallback`) that reverts on V4 swaps, so Realm redeployed Robinhood mainnet's
    ///      exact V4-capable UR bytecode re-pointed at this testnet's V4 infra.
    address public constant UNIV4_UNIVERSAL_ROUTER = 0x79E3a3473ad2d9285A7C87ACfb4A5C871396240d;

    /// @notice Permit2 contract (canonical address)
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Wrapped Ether (WETH) token contract
    address public constant WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;

    /// @notice Uniswap V2 Router — Realm-deployed stock UniswapV2Router02 (canonical bytecode)
    address public constant UNIV2_ROUTER = 0xfD550c5dC070Ea575A06A40f2e18304D85211663;

    /// @notice Uniswap V2 Factory — Realm-deployed stock UniswapV2Factory (canonical bytecode)
    address public constant UNIV2_FACTORY = 0x7766e3a6A8C98a76308CFb4040E330c3308F7C73;

    /// @notice keccak256 of the UniswapV2Pair creation code used by UNIV2_FACTORY.
    /// @dev The factory was deployed from Uniswap's canonical bytecode, so this is the canonical
    ///      mainnet value. Verified: keccak256 of the canonical UniswapV2Pair creation code.
    bytes32 public constant UNIV2_PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    /// @notice Dead address used for burning LP tokens
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Max native amount (wei) a taxable token's `processBurn`/`processLiquidity` processes per call.
    /// @dev See the Ethereum mainnet library for the rationale (sandwich-extraction cap).
    uint256 public constant MAX_EARNINGS_PER_PROCESS = 0.2 ether;

    /// @notice Minimum accrued native amount the dividend buffer must hold before
    ///         `processDividends` may convert it and stream it to holders. Per-chain because a wei value
    ///         cannot be shared between an ETH chain and a USDC-native one. Bypassed only once the
    ///         token has gone `STALE_DIVIDEND_WINDOW` without a distribution, so a sub-threshold residual
    ///         on a dead token can never strand.
    uint256 public constant DIVIDEND_THRESHOLD = 0.001 ether;

    /// @notice Gas forwarded to a holder's `receive()` on a NATIVE dividend payout in a keeper batch.
    /// @dev Bounded so one holder with an expensive (or reverting) fallback cannot starve the rest of a
    ///      batch. Per-chain because the wallets in common use differ per chain and the ceiling is a
    ///      property of them, not of the protocol. It is NOT an eligibility gate: a holder who needs
    ///      more can always call `claimDividends()`, which forwards all remaining gas.
    uint256 public constant NATIVE_PAYOUT_GAS = 50_000;

    /// @notice Flat amount of native the `RealmDividendSwapRegistry` diverts to the keeper wallet on each
    ///         `swapNativeToAsset`, as gas money for the conversion that keeper just paid for.
    /// @dev SIZED AS A MULTIPLE OF ONE CONVERSION'S GAS, not as a share of the conversion. Gas is an
    ///      absolute cost, so a percentage would starve the keeper on a small conversion and overcharge
    ///      holders on a large one — and the conversion band is narrow anyway
    ///      (`DIVIDEND_THRESHOLD`..`MAX_EARNINGS_PER_PROCESS`). Deliberately generous: an underfunded
    ///      keeper stops every token's distributions at once, while an over-generous one costs holders a
    ///      few basis points of one conversion.
    /// @dev A constant rather than a stored setting because the registry is a proxy — repricing it is an
    ///      upgrade, which is the right cadence for a number that moves with gas regimes, not with the
    ///      market. Per-chain for the same reason `DIVIDEND_THRESHOLD` is.
    /// @dev Scaled to this chain's 100x smaller `DIVIDEND_THRESHOLD`, same ratio as the mainnet pair.
    uint256 public constant KEEPER_FEE = 0.0002 ether;

    /// @notice The `RealmDividendSwapRegistry` proxy: the eligibility gate for a third-asset dividend
    ///         payout and the venue its native -> asset conversion crosses.
    /// @dev ⚠️ PLACEHOLDER — NOT DEPLOYED YET on this chain. The leading zeros and the `D1d3ADd5` tail
    ///      are the tell; it is deliberately NOT `address(0)`, because tests have to `etch` a working
    ///      registry AT this address and most ERC20s (USDC included) revert on a `transfer` to the zero
    ///      address, which would make every third-asset payout untestable.
    /// @dev What actually enforces "remember to update this" is not the value but the assertion: every
    ///      script that deploys a taxable token implementation requires
    ///      `DIVIDEND_SWAP_REGISTRY.code.length != 0` before broadcasting. Deploy the registry proxy
    ///      first, paste it here, then deploy the impls — they bake this in as a constant and clones
    ///      cannot be repointed.
    /// @dev Left unset, everything fails closed: `_initializeDividends` reverts on the codeless registry
    ///      so no third-asset token can be created, and `_swapNativeToDividendAsset`'s `code.length`
    ///      guard stops a conversion handing its native to an address that cannot give it back. Native
    ///      and self-token payouts are unaffected either way.
    address public constant DIVIDEND_SWAP_REGISTRY = 0x00000000000000000000000000000000D1d3ADd5;

    /// @notice The `RealmKeepersRegistry`: the set of addresses allowed to trigger a token's out-of-band
    ///         earnings conversions (`processDividends`, `processBurn`, `processLiquidity`).
    /// @dev ⚠️ PLACEHOLDER — NOT DEPLOYED YET on this chain. The `CeEbEe95` tail is the tell; it is
    ///      deliberately NOT `address(0)` so tests can `etch` a working registry AT this address, the
    ///      same convention `DIVIDEND_SWAP_REGISTRY` uses.
    /// @dev Baked into token implementations as a constant, so deploy the registry first and paste it
    ///      here; the impl deploy scripts assert it has code before broadcasting. Left unset everything
    ///      fails closed — `_requireKeeper` reverts on the codeless address, so no conversion runs at
    ///      all, which is the safe direction for a gate.
    address public constant REALM_KEEPERS_REGISTRY = 0x00000000000000000000000000000000CeEbEe95;
    /// @notice Realm Treasury. TEMPORARY: the `realm.dev` EOA stands in until Realm has its own
    ///         treasury — replace before production. Consumed by core contracts at deploy time.
    address public constant REALM_TREASURY = 0x1a209bB4d0bC40f169c06dC2808d7d512Aea62bb;
}

/// @title Deployment Address Constants for ARC Chain Mainnet (chain id 5042)
/// @notice ARC is Circle's EVM L1 whose native currency is USDC (18-decimal at msg.value/balance).
/// @dev Uniswap is OFFICIALLY deployed on ARC mainnet; the addresses below were verified on-chain by
///      byte-diffing each runtime against the Ethereum canonical deployment (identical except the
///      20-byte self-address immutable). Realm's own contracts are not deployed yet — see
///      a per-chain manifest (ARC is no longer a deploy target). There is NO WETH on ARC: the V2 pair quote token is the
///      6-decimal USDC ERC-20 alias (V4 pairs use native address(0)); the `WETH` field name is kept
///      for consumer compatibility but holds that USDC ERC-20 address.
library DeploymentAddressesArcMainnet {
    /// @notice Blockchain ID for ARC mainnet
    uint256 public constant BLOCKCHAIN_ID = 5042;

    /// @notice Uniswap V4 Pool Manager contract
    address public constant UNIV4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// @notice Uniswap V4 Position Manager contract
    address public constant UNIV4_POSITION_MANAGER = 0x6049c9a0e26405C0985f9E3685C87d0aE917f82B;
    /// @notice Uniswap V4 Universal Router contract
    address public constant UNIV4_UNIVERSAL_ROUTER = 0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1;

    /// @notice Permit2 contract (canonical address)
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice V2 pair quote token = the 6-decimal USDC ERC-20 alias (there is no WETH on ARC).
    /// @dev NOT the deployed Router02's internal weth9: `router.WETH()` returns 0x8bcEaA40…937f, a
    ///      54-byte revert stub (every call reverts with `0xea3559ef`), so the native
    ///      `addLiquidityETH` / `swapExactETHForTokens` paths are dead. The ARC V2 graduator pairs
    ///      `<token, USDC>` using this USDC alias directly via `addLiquidity`.
    address public constant WETH = 0x3600000000000000000000000000000000000000;

    /// @notice Uniswap V2 Router02 contract
    address public constant UNIV2_ROUTER = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    /// @notice Uniswap V2 Factory contract
    address public constant UNIV2_FACTORY = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;

    /// @notice keccak256 of the UniswapV2Pair creation code used by UNIV2_FACTORY.
    /// @dev Stock Uniswap bytecode, so this is the canonical value — unlike ARC testnet, whose
    ///      factory Realm compiled from source. Verified: CREATE2-reproduces `allPairs(0)`.
    bytes32 public constant UNIV2_PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    /// @notice Uniswap V3 contracts. Unused by Realm — recorded for reference only.
    address public constant UNIV3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    address public constant UNIV3_QUOTER_V2 = 0x7DfD4F31be6814D2906BDE155c3e1B146EAc1468;
    address public constant UNIV3_POSITION_MANAGER = 0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377;
    address public constant UNIV3_SWAP_ROUTER_02 = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;

    /// @notice Multicall3 (canonical address)
    address public constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    /// @notice Dead address used for burning LP tokens
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Max native amount (wei) a taxable token's `processBurn`/`processLiquidity` processes per call.
    /// @dev 400 native USDC ≈ 0.2 ETH under the ×2000 ARC repricing assumption. See the Ethereum
    ///      mainnet library for the rationale (sandwich-extraction cap).
    uint256 public constant MAX_EARNINGS_PER_PROCESS = 400e18;

    /// @notice Minimum accrued native amount the dividend buffer must hold before
    ///         `processDividends` may convert it and stream it to holders. Per-chain because a wei value
    ///         cannot be shared between an ETH chain and a USDC-native one. Bypassed only once the
    ///         token has gone `STALE_DIVIDEND_WINDOW` without a distribution, so a sub-threshold residual
    ///         on a dead token can never strand.
    uint256 public constant DIVIDEND_THRESHOLD = 250e18;

    /// @notice Gas forwarded to a holder's `receive()` on a NATIVE dividend payout in a keeper batch.
    /// @dev Bounded so one holder with an expensive (or reverting) fallback cannot starve the rest of a
    ///      batch. Per-chain because the wallets in common use differ per chain and the ceiling is a
    ///      property of them, not of the protocol. It is NOT an eligibility gate: a holder who needs
    ///      more can always call `claimDividends()`, which forwards all remaining gas.
    uint256 public constant NATIVE_PAYOUT_GAS = 50_000;

    /// @notice Flat amount of native the `RealmDividendSwapRegistry` diverts to the keeper wallet on each
    ///         `swapNativeToAsset`, as gas money for the conversion that keeper just paid for.
    /// @dev SIZED AS A MULTIPLE OF ONE CONVERSION'S GAS, not as a share of the conversion. Gas is an
    ///      absolute cost, so a percentage would starve the keeper on a small conversion and overcharge
    ///      holders on a large one — and the conversion band is narrow anyway
    ///      (`DIVIDEND_THRESHOLD`..`MAX_EARNINGS_PER_PROCESS`). Deliberately generous: an underfunded
    ///      keeper stops every token's distributions at once, while an over-generous one costs holders a
    ///      few basis points of one conversion.
    /// @dev A constant rather than a stored setting because the registry is a proxy — repricing it is an
    ///      upgrade, which is the right cadence for a number that moves with gas regimes, not with the
    ///      market. Per-chain for the same reason `DIVIDEND_THRESHOLD` is.
    /// @dev 2 native USDC ~ 0.001 ETH under the x2000 ARC repricing assumption the other values here
    ///      use. Native is 18-dec USDC on ARC, so this is 2 USDC, not 2 ETH.
    uint256 public constant KEEPER_FEE = 2e18;

    /// @notice The `RealmDividendSwapRegistry` proxy: the eligibility gate for a third-asset dividend
    ///         payout and the venue its native -> asset conversion crosses.
    /// @dev ⚠️ PLACEHOLDER — NOT DEPLOYED YET on this chain. The leading zeros and the `D1d3ADd5` tail
    ///      are the tell; it is deliberately NOT `address(0)`, because tests have to `etch` a working
    ///      registry AT this address and most ERC20s (USDC included) revert on a `transfer` to the zero
    ///      address, which would make every third-asset payout untestable.
    /// @dev What actually enforces "remember to update this" is not the value but the assertion: every
    ///      script that deploys a taxable token implementation requires
    ///      `DIVIDEND_SWAP_REGISTRY.code.length != 0` before broadcasting. Deploy the registry proxy
    ///      first, paste it here, then deploy the impls — they bake this in as a constant and clones
    ///      cannot be repointed.
    /// @dev Left unset, everything fails closed: `_initializeDividends` reverts on the codeless registry
    ///      so no third-asset token can be created, and `_swapNativeToDividendAsset`'s `code.length`
    ///      guard stops a conversion handing its native to an address that cannot give it back. Native
    ///      and self-token payouts are unaffected either way.
    address public constant DIVIDEND_SWAP_REGISTRY = 0x00000000000000000000000000000000D1d3ADd5;

    /// @notice The `RealmKeepersRegistry`: the set of addresses allowed to trigger a token's out-of-band
    ///         earnings conversions (`processDividends`, `processBurn`, `processLiquidity`).
    /// @dev ⚠️ PLACEHOLDER — NOT DEPLOYED YET on this chain. The `CeEbEe95` tail is the tell; it is
    ///      deliberately NOT `address(0)` so tests can `etch` a working registry AT this address, the
    ///      same convention `DIVIDEND_SWAP_REGISTRY` uses.
    /// @dev Baked into token implementations as a constant, so deploy the registry first and paste it
    ///      here; the impl deploy scripts assert it has code before broadcasting. Left unset everything
    ///      fails closed — `_requireKeeper` reverts on the codeless address, so no conversion runs at
    ///      all, which is the safe direction for a gate.
    address public constant REALM_KEEPERS_REGISTRY = 0x00000000000000000000000000000000CeEbEe95;
    /// @notice Realm Treasury. TEMPORARY: the `realm.dev` EOA stands in until Realm has its own
    ///         treasury — replace before production. Consumed by core contracts at deploy time.
    address public constant REALM_TREASURY = 0x1a209bB4d0bC40f169c06dC2808d7d512Aea62bb;
}

/// @title Deployment Address Constants for ARC Chain Testnet (chain id 5042002)
/// @dev Uniswap V2 + V4 are Realm-self-deployed (no official Uniswap on ARC testnet) from vendored
///      Uniswap sources. That deploy tooling has since been removed — ARC mainnet ships official
///      Uniswap, so nothing needs it again; recover it from git history (branch
///      `feat/arc-chain-support`) if a future chain does. USDC ERC-20 is the documented predeploy
///      0x3600..0000; Permit2 is at the canonical address. Realm's own contracts live in
///      a per-chain manifest (ARC is no longer a deploy target).
library DeploymentAddressesArcTestnet {
    /// @notice Blockchain ID for ARC testnet
    uint256 public constant BLOCKCHAIN_ID = 5042002;

    /// @notice Uniswap V4 Pool Manager contract (Realm-deployed).
    address public constant UNIV4_POOL_MANAGER = 0xE735d281d313AD09bd8bFF81F181715b6c6aD772;
    /// @notice Uniswap V4 Position Manager contract (Realm-deployed).
    address public constant UNIV4_POSITION_MANAGER = 0xBa1a7Fe65E7aAb563630F5921080996030a80AA1;
    /// @notice Uniswap V4 Universal Router contract (Realm-deployed).
    address public constant UNIV4_UNIVERSAL_ROUTER = 0xe4772247D918E32a9908EDb4225c4a123C576e48;

    /// @notice Permit2 contract (canonical address; present on ARC testnet)
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice V2 pair quote token = the 6-decimal USDC ERC-20 alias (documented testnet predeploy).
    /// @dev NOT the router's internal weth9 (an inert WETH9 stub that `router.WETH()` returns — ARC
    ///      has no wrapped-native). The ARC V2 graduator
    ///      pairs `<token, USDC>` using this USDC alias directly via `addLiquidity`, never the native
    ///      `addLiquidityETH`/`router.WETH()` path.
    address public constant WETH = 0x3600000000000000000000000000000000000000;

    /// @notice Uniswap V2 Router contract: a vendored Router02 baking the correct pair init-code-hash
    ///         0xb5a7…. The original 0x61D6362e1FF2e81059D8fFeAc2407950a65684a6 baked the stock 0x96e8…
    ///         hash and was broken; `test/arc/UniswapV2RouterArcFix.t.sol` proves this one works.
    address public constant UNIV2_ROUTER = 0xF5c4fEaC340e65A95EF72499E0aFaD4d45812946;
    /// @notice Uniswap V2 Factory contract (Realm-deployed UniswapV2Factory).
    address public constant UNIV2_FACTORY = 0xEF6fCB80e976733dCd9e4F0b2F3A9C49771a09Fb;

    /// @notice keccak256 of the UniswapV2Pair creation code used by UNIV2_FACTORY.
    /// @dev Chain-specific: the factory was compiled from source (0.5.16) with this repo's settings,
    ///      so the hash is NOT the canonical mainnet 0x96e8ac42… value. Also baked into the deployed
    ///      UniversalRouter's RouterParameters.
    bytes32 public constant UNIV2_PAIR_INIT_CODE_HASH =
        0xb5a7f1081ecaa7c30957adf56bd79febe0588ca66ec38a0fb1ee92e7d324b3f9;

    /// @notice Dead address used for burning LP tokens
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Max native amount (wei) a taxable token's `processBurn`/`processLiquidity` processes per call.
    /// @dev 400 native USDC ≈ 0.2 ETH under the ×2000 ARC repricing assumption. See the Ethereum
    ///      mainnet library for the rationale (sandwich-extraction cap).
    uint256 public constant MAX_EARNINGS_PER_PROCESS = 400e18;

    /// @notice Minimum accrued native amount the dividend buffer must hold before
    ///         `processDividends` may convert it and stream it to holders. Per-chain because a wei value
    ///         cannot be shared between an ETH chain and a USDC-native one. Bypassed only once the
    ///         token has gone `STALE_DIVIDEND_WINDOW` without a distribution, so a sub-threshold residual
    ///         on a dead token can never strand.
    uint256 public constant DIVIDEND_THRESHOLD = 250e18;

    /// @notice Gas forwarded to a holder's `receive()` on a NATIVE dividend payout in a keeper batch.
    /// @dev Bounded so one holder with an expensive (or reverting) fallback cannot starve the rest of a
    ///      batch. Per-chain because the wallets in common use differ per chain and the ceiling is a
    ///      property of them, not of the protocol. It is NOT an eligibility gate: a holder who needs
    ///      more can always call `claimDividends()`, which forwards all remaining gas.
    uint256 public constant NATIVE_PAYOUT_GAS = 50_000;

    /// @notice Flat amount of native the `RealmDividendSwapRegistry` diverts to the keeper wallet on each
    ///         `swapNativeToAsset`, as gas money for the conversion that keeper just paid for.
    /// @dev SIZED AS A MULTIPLE OF ONE CONVERSION'S GAS, not as a share of the conversion. Gas is an
    ///      absolute cost, so a percentage would starve the keeper on a small conversion and overcharge
    ///      holders on a large one — and the conversion band is narrow anyway
    ///      (`DIVIDEND_THRESHOLD`..`MAX_EARNINGS_PER_PROCESS`). Deliberately generous: an underfunded
    ///      keeper stops every token's distributions at once, while an over-generous one costs holders a
    ///      few basis points of one conversion.
    /// @dev A constant rather than a stored setting because the registry is a proxy — repricing it is an
    ///      upgrade, which is the right cadence for a number that moves with gas regimes, not with the
    ///      market. Per-chain for the same reason `DIVIDEND_THRESHOLD` is.
    /// @dev 2 native USDC, matching ARC mainnet (see there).
    uint256 public constant KEEPER_FEE = 2e18;

    /// @notice The `RealmDividendSwapRegistry` proxy: the eligibility gate for a third-asset dividend
    ///         payout and the venue its native -> asset conversion crosses.
    /// @dev ⚠️ PLACEHOLDER — NOT DEPLOYED YET on this chain. The leading zeros and the `D1d3ADd5` tail
    ///      are the tell; it is deliberately NOT `address(0)`, because tests have to `etch` a working
    ///      registry AT this address and most ERC20s (USDC included) revert on a `transfer` to the zero
    ///      address, which would make every third-asset payout untestable.
    /// @dev What actually enforces "remember to update this" is not the value but the assertion: every
    ///      script that deploys a taxable token implementation requires
    ///      `DIVIDEND_SWAP_REGISTRY.code.length != 0` before broadcasting. Deploy the registry proxy
    ///      first, paste it here, then deploy the impls — they bake this in as a constant and clones
    ///      cannot be repointed.
    /// @dev Left unset, everything fails closed: `_initializeDividends` reverts on the codeless registry
    ///      so no third-asset token can be created, and `_swapNativeToDividendAsset`'s `code.length`
    ///      guard stops a conversion handing its native to an address that cannot give it back. Native
    ///      and self-token payouts are unaffected either way.
    address public constant DIVIDEND_SWAP_REGISTRY = 0x00000000000000000000000000000000D1d3ADd5;

    /// @notice The `RealmKeepersRegistry`: the set of addresses allowed to trigger a token's out-of-band
    ///         earnings conversions (`processDividends`, `processBurn`, `processLiquidity`).
    /// @dev ⚠️ PLACEHOLDER — NOT DEPLOYED YET on this chain. The `CeEbEe95` tail is the tell; it is
    ///      deliberately NOT `address(0)` so tests can `etch` a working registry AT this address, the
    ///      same convention `DIVIDEND_SWAP_REGISTRY` uses.
    /// @dev Baked into token implementations as a constant, so deploy the registry first and paste it
    ///      here; the impl deploy scripts assert it has code before broadcasting. Left unset everything
    ///      fails closed — `_requireKeeper` reverts on the codeless address, so no conversion runs at
    ///      all, which is the safe direction for a gate.
    address public constant REALM_KEEPERS_REGISTRY = 0x00000000000000000000000000000000CeEbEe95;
    /// @notice Realm Treasury. TEMPORARY: the `realm.dev` EOA stands in until Realm has its own
    ///         treasury — replace before production. Consumed by core contracts at deploy time.
    address public constant REALM_TREASURY = 0x1a209bB4d0bC40f169c06dC2808d7d512Aea62bb;
}
