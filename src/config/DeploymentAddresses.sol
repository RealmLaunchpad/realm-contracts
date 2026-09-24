// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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

    /// @notice Uniswap V3 factory. `RealmAssetsWhitelist` validates V3 price pools against it.
    address public constant UNIV3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;

    /// @notice keccak256 of the UniswapV2Pair contract creation code used by UNIV2_FACTORY
    /// @dev Robinhood's official V2 factory uses the CANONICAL UniswapV2 pair init code hash
    ///      (the canonical UniswapV2 value). Verified by predicting an existing pair created by this
    ///      factory and matching `getPair()`.
    bytes32 public constant UNIV2_PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    /// @notice Dead address used for burning LP tokens
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
    /// @dev THE ONE THAT MATTERS — dividends ship here. Deliberately over-provisioned: an Arbitrum L2
    ///      conversion costs a tiny fraction of this even with the L1 data fee, so the fee survives an
    ///      L1 fee spike, a stretch of conversions that revert on their floor, and a gas regime nobody
    ///      forecast — the cost of being wrong the other way is every token's distributions stopping at
    ///      once. It is ~2% of a threshold-sized conversion (0.1 ETH) and ~1% of a maximum one.
    uint256 public constant KEEPER_FEE = 0.002 ether;

    /// @notice The `RealmDividendSwapRegistry` proxy: the eligibility gate for a third-asset dividend
    ///         payout and the venue its native -> asset conversion crosses.
    /// @dev Deployed by `DeployRealmRegistries` (also via `DeployRealmPrereqs`); owner is the `realm.dev` deployer.
    /// @dev What actually enforces "remember to update this" is not the value but the assertion: every
    ///      script that deploys a taxable token implementation requires
    ///      `DIVIDEND_SWAP_REGISTRY.code.length != 0` before broadcasting. Deploy the registry proxy
    ///      first, paste it here, then deploy the impls — they bake this in as a constant and clones
    ///      cannot be repointed.
    /// @dev Left unset, everything fails closed: `_initializeDividends` reverts on the codeless registry
    ///      so no third-asset token can be created, and `_swapNativeToDividendAsset`'s `code.length`
    ///      guard stops a conversion handing its native to an address that cannot give it back. Native
    ///      and self-token payouts are unaffected either way.
    address public constant DIVIDEND_SWAP_REGISTRY = 0x5606c6EDF892FEd317c60C95a1BCcDA5c1c5f551;

    /// @notice The `RealmKeepersRegistry`: the set of addresses allowed to trigger a token's out-of-band
    ///         earnings conversions (`processDividends`, `processBurn`, `processLiquidity`).
    /// @dev Deployed by `DeployRealmRegistries` (also via `DeployRealmPrereqs`); owner is the `realm.dev` deployer.
    /// @dev Baked into token implementations as a constant, so deploy the registry first and paste it
    ///      here; the impl deploy scripts assert it has code before broadcasting. Left unset everything
    ///      fails closed — `_requireKeeper` reverts on the codeless address, so no conversion runs at
    ///      all, which is the safe direction for a gate.
    address public constant REALM_KEEPERS_REGISTRY = 0x914e8A6fcA2af6E8Cf4434d1D50234fC89CdF2Ec;
    /// @notice The treasury before `TEAM_TREASURY`. Still baked into the deployed `SWAP_HOOK`'s fallback
    ///         and into the pre-upgrade `SwapLpFeeRouter` impl, so funds can keep landing here; kept so
    ///         nobody forgets to sweep it.
    address public constant LEGACY_TREASURY = 0x7826AaE926AfD2886257976770e93e0240D2426e;
    /// @notice Team treasury multisig: the 2/3 leg of `RealmTreasuryRouter`.
    address public constant TEAM_TREASURY = 0x24CF0733F2b6F9407ab34E2BE9059C16A33cFE8D;
    /// @notice Ops wallet that pulls each round's 1/3 from `RealmVoting` (`processWinner`) and buys the
    ///         winner. Set as a voting admin at deploy.
    address public constant VOTE_BUYBACK_WALLET = 0x636A44e110a79d2a799BFe2F79ABdF9D6C2CE0A6;
    /// @notice Realm Treasury. Consumed by core contracts at deploy time: the address every treasury push
    ///         lands on. The team multisig until `RealmTreasuryRouter` is live, then that proxy.
    address public constant REALM_TREASURY = TEAM_TREASURY;
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

    /// @notice No Uniswap V3 on this testnet (none published by Uniswap or Robinhood): V3 price pools
    ///         are refused by `RealmAssetsWhitelist`.
    address public constant UNIV3_FACTORY = address(0);

    /// @notice keccak256 of the UniswapV2Pair creation code used by UNIV2_FACTORY.
    /// @dev The factory was deployed from Uniswap's canonical bytecode, so this is the canonical
    ///      mainnet value. Verified: keccak256 of the canonical UniswapV2Pair creation code.
    bytes32 public constant UNIV2_PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    /// @notice Dead address used for burning LP tokens
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Max native amount (wei) a taxable token's `processBurn`/`processLiquidity` processes per call.
    /// @dev See the Robinhood mainnet library for the rationale (sandwich-extraction cap).
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
    /// @dev Deployed by `DeployRealmRegistries` (also via `DeployRealmPrereqs`); owner is the `realm.dev` deployer.
    /// @dev What actually enforces "remember to update this" is not the value but the assertion: every
    ///      script that deploys a taxable token implementation requires
    ///      `DIVIDEND_SWAP_REGISTRY.code.length != 0` before broadcasting. Deploy the registry proxy
    ///      first, paste it here, then deploy the impls — they bake this in as a constant and clones
    ///      cannot be repointed.
    /// @dev Left unset, everything fails closed: `_initializeDividends` reverts on the codeless registry
    ///      so no third-asset token can be created, and `_swapNativeToDividendAsset`'s `code.length`
    ///      guard stops a conversion handing its native to an address that cannot give it back. Native
    ///      and self-token payouts are unaffected either way.
    address public constant DIVIDEND_SWAP_REGISTRY = 0xAF6Ac909330edE7fEd2080714241F6Baa7fC6aE4;

    /// @notice The `RealmKeepersRegistry`: the set of addresses allowed to trigger a token's out-of-band
    ///         earnings conversions (`processDividends`, `processBurn`, `processLiquidity`).
    /// @dev Deployed by `DeployRealmRegistries` (also via `DeployRealmPrereqs`); owner is the `realm.dev` deployer.
    /// @dev Baked into token implementations as a constant, so deploy the registry first and paste it
    ///      here; the impl deploy scripts assert it has code before broadcasting. Left unset everything
    ///      fails closed — `_requireKeeper` reverts on the codeless address, so no conversion runs at
    ///      all, which is the safe direction for a gate.
    address public constant REALM_KEEPERS_REGISTRY = 0x2B466c7d6C7Dcc3e8a9649154020F5cfAF227959;
    /// @notice Realm Treasury. Consumed by core contracts at deploy time: the address every treasury push
    ///         lands on. The `RealmTreasuryRouter` proxy (`TREASURY_ROUTER` in the manifest) since
    ///         2026-09-14; the `realm.dev` EOA before that.
    address public constant REALM_TREASURY = 0xE28B56Fd2409bEa3AA0e9861F8327502e6aB562B;

    /// @notice The wallet on the 2/3 leg of `RealmTreasuryRouter`. Separate from `REALM_TREASURY`, which
    ///         became the router proxy itself once the router went live: resolving the leg from that would
    ///         have the router forwarding to its own address.
    /// @dev The dev deployer on this chain, not a multisig — Robinhood mainnet is the only chain with a
    ///      dedicated one. Rotated from `0x1a209bB4d0bC40f169c06dC2808d7d512Aea62bb`, which the router
    ///      implementation deployed 2026-09-14 still pays; an upgrade moves it here.
    address public constant TEAM_TREASURY = 0x81f7D06a88223f5a2850411E72256AacC9E27035;
}
