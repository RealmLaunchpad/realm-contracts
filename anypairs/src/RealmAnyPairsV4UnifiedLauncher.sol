// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RealmAnyPairsCreatorVault} from "./RealmAnyPairsCreatorVault.sol";
import {RealmAnyPairsCloneLib} from "./RealmAnyPairsCloneLib.sol";

import {RealmAnyPairsImmutableBase} from "./base/RealmAnyPairsImmutableBase.sol";
import {RealmAnyPairsTaxHookPairImmutable} from "./RealmAnyPairsTaxHookPairImmutable.sol";
import {RealmAnyPairsDividendTracker} from "./RealmAnyPairsDividendTracker.sol";
import {RealmAnyPairsV4PairLpLockerImmutable} from "./RealmAnyPairsV4PairLpLockerImmutable.sol";
import {RealmAnyPairsV4TokenDeployer} from "./RealmAnyPairsV4TokenDeployer.sol";
import {RealmAnyPairsDevBuyQuote} from "./RealmAnyPairsDevBuyQuote.sol";
import {RealmAnyPairsV4PairTrackerDeployer} from "./RealmAnyPairsV4PairTrackerDeployer.sol";
import {RealmAnyPairsDividendTrackerQuote} from "./RealmAnyPairsDividendTrackerQuote.sol";
import {RealmAnyPairsDividendTrackerAutoBasket} from "./RealmAnyPairsDividendTrackerAutoBasket.sol";
import {RealmAnyPairsGasLib} from "./RealmAnyPairsGasLib.sol";

/// @notice The subset of {RealmAnyPairsTokenDividend} the launcher calls after deploying it through
/// {RealmAnyPairsV4TokenDeployer} (which returns a plain `address`).
interface IDividendTokenInit {
    function initTracker(address tracker) external;
}

/// @notice The two entry points every Realm tracker publishes that {_syncLaunchHolders} uses: the
/// permissionless balance repair, and the stipend the coin forwards to one `setBalance`.
/// @dev `syncBalance` is the tracker's OWN repair path -- it re-reads the coin's real balance and re-applies it
/// through the tracker's `excluded` mapping. The launcher cannot call `setBalance` (that is `onlyToken`) and
/// deliberately does not try to: going through `syncBalance` is what makes it impossible for this launcher to
/// give an excluded address reward weight.
interface IDividendTrackerSync {
    function syncBalance(address account) external;
    function balanceSyncGas() external view returns (uint256);
}

/// @dev Minimal reader for the coin duck-type the pair hook uses in {RealmAnyPairsTaxHookPairImmutable._shape}.
/// Declared locally and consulted through try/catch: a quote that does not implement it must simply fail
/// the check, not revert.
interface ICoinLauncher {
    function launcher() external view returns (address);
}

interface ISwapRouter02 {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH9 {
    function deposit() external payable;
}

/**
 * @title RealmAnyPairsV4UnifiedLauncher
 * @notice Single launcher for every V4 launch shape: ETH-native (launch*, launchRewards*), single ERC20
 *         pair (launchPair*) and multi-pool (launchMultiPair*). All families share one hook and one locker.
 *         The caller supplies the opening tick as quote-per-coin; the contract only checks that the pool
 *         math can use it. There is no quote curation and no on-chain price derivation.
 */
contract RealmAnyPairsV4UnifiedLauncher is RealmAnyPairsImmutableBase {
    using SafeERC20 for IERC20;

    // ─────────────────────────── shared constants ───────────────────────────
    uint256 private constant Q96 = 0x1000000000000000000000000;
    /// @dev AUDIT ROUND 12: 3000 -> 0. Every Realm pool is a zero-fee pool; see
    /// {RealmAnyPairsTaxHookPairImmutable.POOL_FEE} for why and for the accepted consequences. The hook refuses any
    /// other fee (`BadPoolFee`), so this value and the hook's must stay equal.
    uint24 public constant LP_FEE = 0;
    int24 public constant TICK_SPACING = 200;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant BPS_DENOM = 10_000;

    /// @dev Low 14 bits of a V4 hook address are its permission flags; the hook must carry exactly this set
    /// (beforeInitialize / beforeSwap / afterSwap / both returnDelta bits).
    uint160 internal constant HOOK_FLAG_MASK = 0x3FFF;
    /// @dev AUDIT ROUND 11 (H-1): 0x20CC -> 0x28CC. `BEFORE_ADD_LIQUIDITY` (1 << 11) is now required, so the
    /// hook address must be mined for the new value. See docs/DEPLOY_UNIFIED.md.
    uint160 internal constant HOOK_FLAGS = 0x28CC;

    uint16 public constant MIN_MAX_WALLET_BPS = 10;      // 0.1% of supply
    uint16 public constant MAX_MAX_WALLET_MINS = 10080;  // 7 days

    // Minimum supply for rewards launches: the tracker's dust floor is totalSupply/1e4, and below this a single
    // holder could capture the first booked reward almost entirely.
    uint256 internal constant MIN_REWARDS_TOTAL_SUPPLY = 1e9;

    // Overflow ceiling for quote-denominated tracker math; see {RealmAnyPairsDividendTracker}.
    uint256 internal constant MAX_QUOTE_TOTAL_SUPPLY = 1.2e26;

    // ─────────────────────────── shared infra ───────────────────────────
    IPoolManager public immutable poolManager;
    address public immutable weth;
    /// @notice The {RealmAnyPairsCreatorVault} implementation every launch's vaults are minimal clones of.
    address public immutable vaultImplementation;

    /// @notice Hook and locker for new launches. Mutable: the hook is part of the PoolKey, so changing it only
    /// affects future launches.
    /// @dev Native and ERC20 quotes share the same hook and locker; the `pair` prefix is kept for ABI stability.
    RealmAnyPairsTaxHookPairImmutable public pairTaxHook;
    RealmAnyPairsV4PairLpLockerImmutable public pairLpLocker;

    /// @notice Router for the ETH->quote dev-buy zap (pair/multi-pair launches only -- the ETH-native path
    /// needs no zap, it seeds with native ETH directly). Mutable for the same reason the hooks/lockers are.
    address public swapRouter;

    /// @notice The Uniswap V3 factory, handed to basket trackers so they can use the admin-set swap route.
    /// @dev Immutable with no setter, so no owner can ever repoint a deployed launcher's routing.
    address public immutable v3Factory;

    /// @notice Base URI every token this launcher deploys builds its own `tokenURI()` from.
    /// @dev Tokens read it back via `baseTokenURI()` at call time, so updating it moves every coin's metadata.
    string public baseTokenURI;

    /// @notice Ceiling on how many pools (and reward denominations) a new multi-pair launch may use.
    /// Owner/admin-adjustable up to 25, for future launches only.
    /// @dev Default 10 keeps multi-basket coins' per-transfer gas reasonable; the tracker itself hard-caps at 25.
    uint256 public defaultMaxDenominations = 10;

    /// @notice Second config key that survives {renounceOwnership}.
    /// @dev Needed because every token reads `baseTokenURI` from this launcher forever; without an admin a
    /// renounce would freeze all coin metadata.
    address public admin;


    /// @notice Ceiling on the TOTAL basket legs a multi-pair rewards launch may configure, across all denominations.
    /// @dev Must equal {RealmAnyPairsDividendTrackerAutoBasket.MAX_TOTAL_LEGS}. Mirrored by hand because the
    /// tracker does not exist yet when this check runs.
    uint256 internal constant MAX_TOTAL_LEGS = 60;

    /// @notice Ceiling on the legs a SINGLE denomination's basket may hold.
    /// @dev Must equal {RealmAnyPairsDividendTrackerAutoBasket.MAX_LEGS}; mirrored for the same reason as {MAX_TOTAL_LEGS}.
    uint256 internal constant MAX_LEGS_PER_BASKET = 10;

    // ─────────────────────────── events ───────────────────────────
    /// @dev SIGNATURE IS FROZEN: indexers match launches by topic0 across launcher addresses. Do NOT change
    /// field order/types.
    event TaxLaunch(address indexed token, address indexed creator, uint256 supply, int24 launchTick, uint256 devBuyEth);
    event DevBuySettled(address indexed token, uint256 offered, uint256 spent);
    event RewardsLaunch(address indexed token, address indexed tracker, uint16 rewardsBps);

    /// @dev SIGNATURE IS FROZEN, same reasoning as {TaxLaunch}.
    event PairLaunch(address indexed token, address indexed creator, address indexed quote, uint256 supply, int24 launchTick, uint256 devBuyEth);
    event PairDevBuySettled(address indexed token, address indexed quote, uint256 ethIn, uint256 quoteSpent);

    event MultiPairLaunch(address indexed token, address indexed creator, uint256 poolCount, uint256 supply, uint256 devBuyEth);
    /// @dev `poolId` lets indexers join a multi-pair coin to its pools without rebuilding each PoolKey.
    event PoolSeeded(
        address indexed token, address indexed quote, bytes32 indexed poolId, uint16 weightBps, int24 launchTick, uint256 poolSupply
    );
    event DefaultMaxDenominationsSet(uint256 from, uint256 to);

    event V4TokenMeta(address indexed token, address indexed creator, string image, string banner, string description, string website, string twitter, string telegram);
    event BaseTokenURISet(string base);
    /// @dev Emitted by {setAdmin}, including the disabling `address(0)` case.
    event AdminSet(address indexed admin);
    event TaxHookSet(address indexed from, address indexed to);
    event LpLockerSet(address indexed from, address indexed to);
    event SwapRouterSet(address indexed from, address indexed to);
    /// @notice A coin launched with an opt-in max wallet. Emitted only when one is set. Separate event
    /// because {TaxLaunch}/{PairLaunch} are frozen.
    event MaxWalletSet(address indexed token, uint256 maxWallet, uint40 maxWalletUntil);

    // ─────────────────────────── errors ───────────────────────────
    /// @dev Launch-size units for {_launchMultiPair}, per pool: plain pool 16, pool with a rewards basket 25, +1
    /// per creator-split recipient, +3/4 per whitelist wallet (rounded up), and on a rewards launch with a dev buy
    /// {LAUNCH_UNITS_REWARDS_DEV_BUY}. {LAUNCH_UNIT_BUDGET} keeps every admitted launch under the tx gas cap.
    uint256 internal constant LAUNCH_UNITS_PER_POOL = 16;
    uint256 internal constant LAUNCH_UNITS_PER_REWARDS_POOL = 25;
    uint256 internal constant LAUNCH_UNITS_REWARDS_DEV_BUY = 16;
    uint256 internal constant LAUNCH_UNIT_BUDGET = 650;

    /// @dev A multi-pair launch whose pools x (per-pool units + recipients + whitelist units + rewards dev-buy
    /// units) exceeds {LAUNCH_UNIT_BUDGET}.
    error LaunchTooLarge();
    error SupplyZero();
    error SupplyTooLarge();
    error SupplyTooSmallForRewards();
    error BadLiquidity();
    error SeedTransferFailed();
    error ZeroAddress();
    error DeployerLibraryMissing();
    error BadHookFlags();
    error LauncherNotAllowlisted();
    error BadMaxWallet();
    error TokenEqualsQuote();
    /// @notice A dev-buy quote above `type(int128).max`: v4 carries swap deltas as int128, so a launch that large
    /// reverts (with a bare SafeCast overflow). Refused by name here instead.
    error DevBuyTooLarge();
    error QuoteSupplyTooLarge();
    error QuoteImpersonatesCoin();
    error QuoteIsWeth();
    error LaunchPriceMoved();
    error BadDevBuyPath();
    /// @notice A basket whose rewards tracker would need more per-transfer gas than the coin can forward (mirrors
    /// {RealmAnyPairsDividendTrackerAutoBasket.TooHeavy}, checked before anything is deployed for the tracker).
    error BasketTooHeavy();

    /// @dev A funded dev buy delivered zero quote to the locker (e.g. a quote that burns 100% of a transfer).
    /// Reverts so the caller's ETH is not spent for nothing; an unfunded launch against the same token still works.
    error DevBuyProducedNothing();

    /// @dev The launch tick is not a multiple of {TICK_SPACING} or not strictly inside the usable band.
    /// See {_checkedTick}.
    error BadLaunchTick();

    /// @dev The launcher itself (or the hook it configures) named as a coin's creator -- see {_requireSaneParty}.
    error SelfParty();

    error NoPairs();

    /// @dev `rewardBaskets.length` is non-zero and differs from `pairs.length` on a multi-pair launch.
    error RewardBasketsLengthMismatch(uint256 baskets, uint256 pairs);

    /// @dev A `rewardBaskets` entry has no legs. Checked before anything is deployed.
    error EmptyRewardBasket(uint256 index);

    /// @dev A `rewardBaskets` entry has more legs than {MAX_LEGS_PER_BASKET}.
    error TooManyLegsInBasket(uint256 index, uint256 legs, uint256 max);
    /// @dev `rewardsBps` set without `rewardBaskets` on {launchMultiPair}. It would otherwise launch a coin with no
    /// tracker and the share silently zeroed, unfixable afterwards. Baskets with `rewardsBps == 0` are allowed.
    error RewardsBpsWithoutBaskets();

    error DuplicateQuote();
    error WeightsNotOneHundredPercent();
    error ZeroWeight();
    error QuoteOrientationMismatch();
    /// @dev PER-LAUNCH gate ({launchMultiPair}): this launch asked for more pools/denominations than
    /// `defaultMaxDenominations` currently allows.
    error TooManyDenominationsForDefault();
    /// @dev PER-LAUNCH gate ({launchMultiPair}): the reward baskets sum to more legs than {MAX_TOTAL_LEGS}.
    error TooManyTotalLegs();
    /// @dev A config setter called by neither the owner nor the admin.
    error NotOwnerOrAdmin();
    /// @dev Renounce attempted while `admin == address(0)`. See {_requireRenounceReady}.
    error AdminZero();
    /// @dev {setAdmin}(address(this)): this contract never calls itself, so that admin could never act.
    error SelfAddress();
    /// @notice Refused: clearing the admin after ownership is renounced would leave nobody able to configure or
    /// rescue, permanently. Rotate to a new admin instead. (Audit round 12.)
    error AdminWouldBeUnrecoverable();
    /// @notice The native transfer of a rescue failed.
    error RescueFailed();
    /// @notice `amount` of `token` (address(0) = native ETH) was sent to `to` by {rescue}.
    event Rescued(address indexed token, address indexed to, uint256 amount);
    /// @dev {setDefaultMaxDenominations} called with a value outside 1-25.
    error BadDefaultMaxDenominations();

    // ─────────────────────────── shared structs ────────────────────────────────────────────────────────
    struct Meta { string image; string banner; string description; string website; string twitter; string telegram; }

    // ─────────────────────────── ETH-native launch params ──────────────────────────────────────────────
    struct LaunchParams {
        /// @dev Creator vesting vaults: up to 5, together <= 20% of supply. Empty = none. See {VaultParams}.
        VaultParams[] vaults;
        /// @dev Split the dev buy's coin across up to 10 wallets (bps summing to 10,000; the last takes the rounding
        /// remainder). Leave both empty to send it all to the creator. Validated by the locker.
        address[] devBuyRecipients;
        uint16[] devBuyBps;
        string name;
        string symbol;
        uint256 totalSupply;
        RealmAnyPairsTaxHookPairImmutable.ConfigParams tax; // creator field is overwritten with msg.sender
        bytes32 salt;
        uint16 maxWalletBps;
        uint16 maxWalletMins;
        /// @dev Opening price as quote-per-coin: wei of ETH per raw coin unit, `price = 1.0001^launchTick`, a multiple
        /// of {TICK_SPACING}. Native ETH is always currency0, so {_finishLaunch} negates it into the pool tick.
        int24 launchTick;
    }

    struct RewardsLaunchParams {
        /// @dev Creator vesting vaults: up to 5, together <= 20% of supply. Empty = none. See {VaultParams}.
        VaultParams[] vaults;
        /// @dev Split the dev buy's coin across up to 10 wallets (bps summing to 10,000; the last takes the rounding
        /// remainder). Leave both empty to send it all to the creator. Validated by the locker.
        address[] devBuyRecipients;
        uint16[] devBuyBps;
        string name;
        string symbol;
        uint256 totalSupply;
        RealmAnyPairsTaxHookPairImmutable.ConfigParams tax;
        bytes32 salt;
        uint16 maxWalletBps;
        uint16 maxWalletMins;
        /// @dev Quote-per-coin, exactly as {LaunchParams.launchTick}.
        int24 launchTick;
    }

    /// @dev {RewardsLaunchParams} with a reward `basket` appended last. Holders' ETH rewards are converted into
    /// the basket's assets by an auto-converting tracker.
    struct RewardsBasketLaunchParams {
        VaultParams[] vaults;
        address[] devBuyRecipients;
        uint16[] devBuyBps;
        string name;
        string symbol;
        uint256 totalSupply;
        RealmAnyPairsTaxHookPairImmutable.ConfigParams tax;
        bytes32 salt;
        uint16 maxWalletBps;
        uint16 maxWalletMins;
        int24 launchTick;
        RealmAnyPairsDividendTrackerAutoBasket.Leg[] basket;
        /// @dev AUDIT ROUND 11. The route each basket leg converts through, in the same order as {basket}. A route is
        /// a V4 `PoolKey` (abi-encoded) or a V3 path.
        ///
        /// LENGTH: EMPTY, or EXACTLY as long as {basket}. Anything else reverts {
        /// RealmAnyPairsDividendTrackerAutoBasket.RoutesLengthMismatch} at launch -- audit round 12 made this exact,
        /// because a SHORT array silently left the tail routeless and a front end that omitted the placeholder entry
        /// for a direct leg shifted every route by one. DO NOT TRIM TRAILING ROUTELESS ENTRIES: pass an empty `bytes`
        /// at that index instead, which is what "this leg has no route" means inside a full-length array. A leg with
        /// no route is paid out in the input on the usual clocks until the platform admin sets one. A NON-EMPTY entry
        /// at a DIRECT leg (`asset == input`, which converts through nothing) is refused outright with {
        /// RealmAnyPairsDividendTrackerAutoBasket.RouteAtDirectLeg}, for the same reason.
        ///
        /// There is no on-chain route discovery: the route is CHOSEN, at launch, by you. Whichever pool you name
        /// prices every future conversion of that leg, so name a real, liquid market -- and holders who would rather
        /// not be bound by your choice can take the input instead (`claimPending`) or convert into anything they name
        /// themselves (`claimAs`).
        bytes[] basketRoutes;
    }

    // ─────────────────────────── single-pair launch params ───────────────────────────
    struct PairLaunchParams {
        /// @dev Creator vesting vaults: up to 5, together <= 20% of supply. Empty = none. See {VaultParams}.
        VaultParams[] vaults;
        /// @dev Split the dev buy's coin across up to 10 wallets (bps summing to 10,000; the last takes the rounding
        /// remainder). Leave both empty to send it all to the creator. Validated by the locker.
        address[] devBuyRecipients;
        uint16[] devBuyBps;
        /// @dev Anti-sniper whitelist (<= 50): skips max buy (hook, on tx.origin) and max wallet (token), never the
        /// trading delay or launch tax. Part of the token's init code, so it affects the mined address.
        address[] whitelist;
        string name;
        string symbol;
        uint256 totalSupply;
        address pairToken;
        uint16 buyBps;
        uint16 sellBps;
        address[] recipients;
        uint16[] splitBps;
        bytes ethQuotePath;
        uint256 minQuoteOut;
        bytes32 salt;
        bool autoSend;
        uint80 autoThreshold;
        uint16 maxBuyBps; uint16 launchTaxBps; uint16 launchTaxSecs; uint8 tradingDelaySecs; uint16 buybackBps; uint16 lpBps;
        uint16 maxWalletBps;
        uint16 maxWalletMins;
        /// @dev Opening price as quote-per-coin: `price = 1.0001^launchTick` in raw token units, a multiple of
        /// {TICK_SPACING}, computed off chain from the target market cap. The launcher negates it into the pool tick
        /// when the coin sorts as currency1, so the caller never needs to know the mined address's sort order.
        int24 launchTick;
    }

    struct PairRewardsLaunchParams {
        /// @dev Creator vesting vaults: up to 5, together <= 20% of supply. Empty = none. See {VaultParams}.
        VaultParams[] vaults;
        /// @dev Split the dev buy's coin across up to 10 wallets (bps summing to 10,000; the last takes the rounding
        /// remainder). Leave both empty to send it all to the creator. Validated by the locker.
        address[] devBuyRecipients;
        uint16[] devBuyBps;
        /// @dev Anti-sniper whitelist (<= 50): skips max buy (hook, on tx.origin) and max wallet (token), never the
        /// trading delay or launch tax. Part of the token's init code, so it affects the mined address.
        address[] whitelist;
        string name; string symbol; uint256 totalSupply; address pairToken;
        uint16 buyBps; uint16 sellBps; address[] recipients; uint16[] splitBps;
        uint16 rewardsBps;
        /// @dev Pay holder rewards in the coin itself ("reflections") instead of the pair token. Only the
        /// quote-tracker path ({launchPairRewards}) honours it.
        bool rewardsInCoin;
        bytes ethQuotePath; uint256 minQuoteOut;
        bytes32 salt;
        bool autoSend;
        uint80 autoThreshold;
        uint16 maxBuyBps; uint16 launchTaxBps; uint16 launchTaxSecs; uint8 tradingDelaySecs; uint16 buybackBps; uint16 lpBps;
        uint16 maxWalletBps;
        uint16 maxWalletMins;
        /// @dev Opening price as quote-per-coin: `price = 1.0001^launchTick` in raw token units, a multiple of
        /// {TICK_SPACING}, computed off chain from the target market cap. The launcher negates it into the pool tick
        /// when the coin sorts as currency1, so the caller never needs to know the mined address's sort order.
        int24 launchTick;
    }

    struct PairRewardsBasketLaunchParams {
        /// @dev Creator vesting vaults: up to 5, together <= 20% of supply. Empty = none. See {VaultParams}.
        VaultParams[] vaults;
        /// @dev Split the dev buy's coin across up to 10 wallets (bps summing to 10,000; the last takes the rounding
        /// remainder). Leave both empty to send it all to the creator. Validated by the locker.
        address[] devBuyRecipients;
        uint16[] devBuyBps;
        /// @dev Anti-sniper whitelist (<= 50): skips max buy (hook, on tx.origin) and max wallet (token), never the
        /// trading delay or launch tax. Part of the token's init code, so it affects the mined address.
        address[] whitelist;
        string name; string symbol; uint256 totalSupply; address pairToken;
        uint16 buyBps; uint16 sellBps; address[] recipients; uint16[] splitBps;
        uint16 rewardsBps;
        /// @dev Pay holder rewards in the coin itself ("reflections") instead of the pair token. Only the
        /// quote-tracker path ({launchPairRewards}) honours it.
        bool rewardsInCoin;
        bytes ethQuotePath; uint256 minQuoteOut;
        bytes32 salt;
        bool autoSend;
        uint80 autoThreshold;
        uint16 maxBuyBps; uint16 launchTaxBps; uint16 launchTaxSecs; uint8 tradingDelaySecs; uint16 buybackBps; uint16 lpBps;
        RealmAnyPairsDividendTrackerAutoBasket.Leg[] basket;
        /// @dev AUDIT ROUND 11. The route each basket leg converts through, in the same order as {basket}. A route is
        /// a V4 `PoolKey` (abi-encoded) or a V3 path.
        ///
        /// LENGTH: EMPTY, or EXACTLY as long as {basket}. Anything else reverts {
        /// RealmAnyPairsDividendTrackerAutoBasket.RoutesLengthMismatch} at launch -- audit round 12 made this exact,
        /// because a SHORT array silently left the tail routeless and a front end that omitted the placeholder entry
        /// for a direct leg shifted every route by one. DO NOT TRIM TRAILING ROUTELESS ENTRIES: pass an empty `bytes`
        /// at that index instead, which is what "this leg has no route" means inside a full-length array. A leg with
        /// no route is paid out in the input on the usual clocks until the platform admin sets one. A NON-EMPTY entry
        /// at a DIRECT leg (`asset == input`, which converts through nothing) is refused outright with {
        /// RealmAnyPairsDividendTrackerAutoBasket.RouteAtDirectLeg}, for the same reason.
        ///
        /// There is no on-chain route discovery: the route is CHOSEN, at launch, by you. Whichever pool you name
        /// prices every future conversion of that leg, so name a real, liquid market -- and holders who would rather
        /// not be bound by your choice can take the input instead (`claimPending`) or convert into anything they name
        /// themselves (`claimAs`).
        bytes[] basketRoutes;
        uint16 maxWalletBps;
        uint16 maxWalletMins;
        /// @dev Opening price as quote-per-coin: `price = 1.0001^launchTick` in raw token units, a multiple of
        /// {TICK_SPACING}, computed off chain from the target market cap. The launcher negates it into the pool tick
        /// when the coin sorts as currency1, so the caller never needs to know the mined address's sort order.
        int24 launchTick;
    }

    // ─────────────────────────── multi-pair launch params ──────────────────────────────────────────────
    struct PairSpec {
        address quoteToken;
        uint16 weightBps;
        /// @dev This pool's opening price in quote-per-coin (see {PairLaunchParams.launchTick}). Per pool because one
        /// market cap is a different number in each quote asset.
        int24 launchTick;
        bytes ethQuotePath;
    }

    struct MultiLaunchParams {
        /// @dev Creator vesting vaults: up to 5, together <= 20% of supply. Empty = none. See {VaultParams}.
        VaultParams[] vaults;
        /// @dev Split the dev buy's coin across up to 10 wallets (bps summing to 10,000; the last takes the rounding
        /// remainder). Leave both empty to send it all to the creator. Validated by the locker.
        address[] devBuyRecipients;
        uint16[] devBuyBps;
        /// @dev Anti-sniper whitelist (<= 50): skips max buy (hook, on tx.origin) and max wallet (token), never the
        /// trading delay or launch tax. Part of the token's init code, so it affects the mined address.
        address[] whitelist;
        string name;
        string symbol;
        uint256 totalSupply;
        PairSpec[] pairs;
        uint16 buyBps;
        uint16 sellBps;
        address[] recipients;
        uint16[] splitBps;
        uint256 minQuoteOutFirstPair;
        bytes32 salt;
        bool autoSend;
        uint80 autoThreshold;
        uint16 maxBuyBps; uint16 launchTaxBps; uint16 launchTaxSecs; uint8 tradingDelaySecs; uint16 buybackBps; uint16 lpBps;
        uint16 maxWalletBps; uint16 maxWalletMins;
        RealmAnyPairsDividendTrackerAutoBasket.Leg[][] rewardBaskets;
        /// @dev AUDIT ROUND 11. The route each basket leg converts through, in the same order as each entry of
        /// {rewardBaskets}. A route is a V4 `PoolKey` (abi-encoded) or a V3 path.
        ///
        /// LENGTH, BOTH DIMENSIONS. The OUTER array is empty, or exactly as long as {rewardBaskets}; anything else
        /// reverts {RewardBasketsLengthMismatch}. Each INNER array is empty, or exactly as long as ITS basket;
        /// anything else reverts {RealmAnyPairsDividendTrackerAutoBasket.RoutesLengthMismatch} at launch -- audit
        /// round 12 made this exact, because a SHORT array silently left the tail routeless and a front end that
        /// omitted the placeholder entry for a direct leg shifted every route by one. DO NOT TRIM TRAILING ROUTELESS
        /// ENTRIES: pass an empty `bytes` at that index instead, which is what "this leg has no route" means inside a
        /// full-length array. A leg with no route is paid out in the input on the usual clocks until the platform
        /// admin sets one. A NON-EMPTY entry at a DIRECT leg (`asset == input`, which converts through nothing) is
        /// refused outright with {RealmAnyPairsDividendTrackerAutoBasket.RouteAtDirectLeg}, for the same reason.
        ///
        /// There is no on-chain route discovery: the route is CHOSEN, at launch, by you. Whichever pool you name
        /// prices every future conversion of that leg, so name a real, liquid market -- and holders who would rather
        /// not be bound by your choice can take the input instead (`claimPending`) or convert into anything they name
        /// themselves (`claimAs`).
        bytes[][] basketRoutes;
        uint16 rewardsBps;
    }

    constructor(
        IPoolManager pm,
        RealmAnyPairsTaxHookPairImmutable pairHook,
        address weth_,
        address router_,
        address v3Factory_,
        RealmAnyPairsV4PairLpLockerImmutable pairLocker,
        string memory base,
        address owner_
    ) RealmAnyPairsImmutableBase(owner_) {
        if (address(pairLocker) == address(0)) revert ZeroAddress();
        if (address(pm) == address(0) || address(pairHook) == address(0)
            || weth_ == address(0) || router_ == address(0) || v3Factory_ == address(0)) revert ZeroAddress();
        // ONE hook, ONE flag check. The mined address must carry the exact V4 permission bits this
        // launcher configures pools with.
        if (uint160(address(pairHook)) & HOOK_FLAG_MASK != HOOK_FLAGS) revert BadHookFlags();
        // Token/tracker deployers are linked libraries reached by DELEGATECALL; assert they exist while that is
        // still recoverable.
        // AUDIT ROUND 10: `RealmAnyPairsV4MultiPairTrackerDeployer` was checked here too. It is gone -- nothing
        // called its only function, because a multi-pair launch deploys the AUTO-basket tracker like every other
        // basket launch. One fewer library to deploy and link. See docs/DEPLOY_UNIFIED.md.
        if (address(RealmAnyPairsV4TokenDeployer).code.length == 0
            || address(RealmAnyPairsV4PairTrackerDeployer).code.length == 0) revert DeployerLibraryMissing();
        poolManager = pm;
        v3Factory = v3Factory_;
        pairTaxHook = pairHook;
        weth = weth_;
        swapRouter = router_;
        pairLpLocker = pairLocker;
        baseTokenURI = base;
        // The deployer is the first admin, so the contract is renounce-ready without a {setAdmin} call.
        vaultImplementation = address(new RealmAnyPairsCreatorVault());
        admin = owner_;
    }

    // ─────────────────────────── admin ───────────────────────────

    /// @dev Owner, or the admin when it is non-zero. Ownership transfer and renounce stay `onlyOwner`, so the
    /// admin can never reach the owner seat. The admin may rotate itself.
    modifier onlyOwnerOrAdmin() {
        if (msg.sender != owner && (msg.sender != admin || admin == address(0))) revert NotOwnerOrAdmin();
        _;
    }

    /// @notice Hand the surviving config key to `admin_`. Owner OR admin -- the admin may rotate itself.
    /// @dev `address(0)` disables the admin path; {_requireRenounceReady} refuses to renounce over it.
    /// @dev AUDIT ROUND 12 (Low). Once ownership is renounced the admin is the ONLY remaining authority, so
    /// `setAdmin(address(0))` would permanently freeze every configuration path on this launcher -- with no owner left to appoint a
    /// replacement. It is refused after renounce. Handing the role to a NEW admin stays allowed, because that is
    /// the rotation path a renounced deployment still needs; only the one-way trip to nobody is closed.
    function setAdmin(address admin_) external onlyOwnerOrAdmin {
        if (admin_ == address(this)) revert SelfAddress();
        if (admin_ == address(0) && owner == address(0)) revert AdminWouldBeUnrecoverable();
        admin = admin_;
        emit AdminSet(admin_);
    }

    function _requireRenounceReady() internal view override {
        if (!pairTaxHook.isLauncher(address(this))) revert LauncherNotAllowlisted();
        if (!pairLpLocker.isLauncher(address(this))) revert LauncherNotAllowlisted();
        // AUDIT ROUND 18 (defence in depth). ASSERT THE SAME WIRING INVARIANT BOTH ROTATION PATHS ASSERT.
        // `isLauncher` does NOT imply `isLpProvider` -- that is exactly what round 17 (F-4) proved when it added
        // {_requireWiring} to `setPairTaxHook`. Without this line ownership could be renounced over a pairing in
        // which every GUARDED launch reverts `LiquidityLockedDuringMaxWallet` at the seed, while unguarded launches
        // keep working: a wiring fault that reads like a parameter fault, frozen in place by the renounce.
        //
        // WHY THIS CANNOT BRICK A LEGITIMATE RENOUNCE:
        //   * It is unreachable while the invariant holds, and the invariant holds in every ordinary sequence.
        //     `isLauncher(this)` -- already required on the line above -- can only have been set by the hook's
        //     {RealmAnyPairsTaxHookPairImmutable-setLauncher}, which in the SAME call probes this launcher's
        //     `pairLpLocker()` and registers it as an LP provider. So the instant the first condition is satisfiable
        //     this one is too, and both {setPairTaxHook} and {setPairLpLocker} re-assert it on every rotation after.
        //   * The only way to break it is a hook-side `setLpProvider(locker, false)`, and the repair is the same
        //     hook-side key -- never the launcher's owner. Renouncing HERE does not touch it, so a deployment that
        //     trips this check can always be repaired and then renounce.
        //   * Renounce is the only caller: {RealmAnyPairsImmutableBase} calls {_requireRenounceReady} from
        //     `renounceOwnership` alone, so this can never trap `transferOwnership`/`acceptOwnership`. An owner who
        //     wants out of a broken pairing can still hand the seat on.
        // The check therefore refuses only a deployment that is ALREADY broken for guarded launches -- the same
        // thing {_requireWiring} refuses to adopt.
        _requireWiring(pairTaxHook, pairLpLocker);
        // After renounce neither allowlist is repairable from here, and the admin is the only key left that can
        // change `baseTokenURI` and the rest of the config.
        if (admin == address(0)) revert AdminZero();
    }

    /// @dev THE WIRING INVARIANT, asserted in one place for both rotation paths.
    ///
    /// A guarded launch seeds its pool through `pairLpLocker`, and the hook's {beforeAddLiquidity} refuses that seed
    /// unless `isLpProvider[pairLpLocker]` is true ON the hook the launch uses. So the pair `(pairTaxHook,
    /// pairLpLocker)` must satisfy `pairTaxHook.isLpProvider(pairLpLocker)` after EVERY rotation, whichever half
    /// moved. Break it and guarded launches revert `LiquidityLockedDuringMaxWallet` at the seed while unguarded
    /// launches keep working -- a wiring fault that reads like a parameter fault.
    ///
    /// AUDIT ROUND 15 (F-3) added this on the locker path only. AUDIT ROUND 17 (F-4): the hook path had the same
    /// gap, and round 15's own comment claimed it did not -- it said `setPairTaxHook` "self-heals because it
    /// requires `newHook.isLauncher(this)`". THAT IS FALSE. The hook's `setLauncher` registers an LP provider by
    /// probing `pairLpLocker()` ON THE LAUNCHER AT ALLOWLIST TIME and recording whatever it answers then. Allowlist
    /// the new hook, THEN rotate the locker, and the new hook holds the OLD locker as its LP provider; pointing the
    /// launcher at that hook satisfies `isLauncher` and still breaks every guarded launch. `isLauncher` says the
    /// hook will accept this launcher, not that it knows this launcher's current locker. The invariant is the only
    /// thing that says that, so both paths assert it and neither is assumed to self-heal.
    ///
    /// Repair in either direction is the hook owner's `setLpProvider` (or re-running `setLauncher` after the
    /// rotation); this only refuses to ADOPT a broken pairing.
    function _requireWiring(RealmAnyPairsTaxHookPairImmutable hook_, RealmAnyPairsV4PairLpLockerImmutable locker_)
        internal
        view
    {
        if (!hook_.isLpProvider(address(locker_))) revert LauncherNotAllowlisted();
    }

    function setPairTaxHook(RealmAnyPairsTaxHookPairImmutable newHook) external onlyOwnerOrAdmin {
        if (address(newHook) == address(0)) revert ZeroAddress();
        if (uint160(address(newHook)) & HOOK_FLAG_MASK != HOOK_FLAGS) revert BadHookFlags();
        if (!newHook.isLauncher(address(this))) revert LauncherNotAllowlisted();
        _requireWiring(newHook, pairLpLocker);
        emit TaxHookSet(address(pairTaxHook), address(newHook));
        pairTaxHook = newHook;
    }

    function setPairLpLocker(RealmAnyPairsV4PairLpLockerImmutable newLocker) external onlyOwnerOrAdmin {
        if (address(newLocker) == address(0)) revert ZeroAddress();
        if (!newLocker.isLauncher(address(this))) revert LauncherNotAllowlisted();
        _requireWiring(pairTaxHook, newLocker);
        emit LpLockerSet(address(pairLpLocker), address(newLocker));
        pairLpLocker = newLocker;
    }

    /// @notice The locker that performs this launcher's atomic dev buy.
    /// @dev Required by the hook: it staticcalls `lpLocker()` on its caller to exempt the launch transaction's dev
    /// buy from the launch guards, and fails closed without it.
    function lpLocker() external view returns (address) {
        return address(pairLpLocker);
    }

    /// @notice Repoint the dev-buy zap router (pair/multi-pair launches only).
    function setSwapRouter(address newRouter) external onlyOwnerOrAdmin {
        if (newRouter == address(0)) revert ZeroAddress();
        emit SwapRouterSet(swapRouter, newRouter);
        swapRouter = newRouter;
    }

    function setBaseTokenURI(string calldata base) external onlyOwnerOrAdmin {
        baseTokenURI = base;
        emit BaseTokenURISet(base);
    }

    /// @notice Raise or lower the per-launch pool/denomination ceiling for FUTURE launches.
    /// @dev Capped at 25, matching {RealmAnyPairsDividendTrackerAutoBasket.ABSOLUTE_MAX_DENOMINATIONS}, so this gate
    /// never admits more than the tracker accepts. Applies to rewards and non-rewards launches alike.
    function setDefaultMaxDenominations(uint256 newDefault) external onlyOwnerOrAdmin {
        if (newDefault == 0 || newDefault > 25) revert BadDefaultMaxDenominations();
        emit DefaultMaxDenominationsSet(defaultMaxDenominations, newDefault);
        defaultMaxDenominations = newDefault;
    }

    // ─────────────────────────── shared quote / party sanity ───────────────────────────
    //
    // Arithmetic guards, not curation: each rejects a quote whose pool accounting cannot work. Callers must exclude
    // native ETH, because the typed calls below revert uncatchably on `address(0)`.
    function _requireSaneQuote(address quote) internal view {
        // WETH as a quote would make the ETH->quote dev-buy zap a self-referential no-op and gives the
        // coin a wrapped-ETH pool that the native path already serves natively and better.
        if (quote == weth) revert QuoteIsWeth();
        // Overflow ceiling for quote-denominated tracker math; see {MAX_QUOTE_TOTAL_SUPPLY}.
        if (IERC20(quote).totalSupply() > MAX_QUOTE_TOTAL_SUPPLY) revert QuoteSupplyTooLarge();
        // A quote that duck-types as a coin from this launcher would make the hook's orientation disagree with
        // address ordering (buys taxed as sells), so it is refused.
        try ICoinLauncher(quote).launcher() returns (address l) {
            if (l == address(this)) revert QuoteImpersonatesCoin();
        } catch {}
    }

    /// @dev Refuses this launcher, the hook or the PoolManager as a party: value pushed there would be stuck with
    /// no way to retrieve it.
    function _requireSaneParty(address party) internal view {
        if (party == address(this) || party == address(pairTaxHook) || party == address(poolManager)) revert SelfParty();
    }

    // ─────────────────────────── shared tick/liquidity/max-wallet math ────────────────────────────────
    function _maxWalletOf(uint256 totalSupply_, uint16 bps, uint16 mins, uint8 delaySecs)
        internal pure returns (uint256 cap, uint32 secs)
    {
        if (bps == 0 && mins == 0) return (0, 0);
        if (bps < MIN_MAX_WALLET_BPS || bps > BPS_DENOM) revert BadMaxWallet();
        if (mins == 0 || mins > MAX_MAX_WALLET_MINS) revert BadMaxWallet();
        cap = (totalSupply_ * bps) / BPS_DENOM;
        if (cap == 0) revert BadMaxWallet();
        secs = uint32(mins) * 60;
        if (secs <= uint32(delaySecs)) revert BadMaxWallet();
    }

    function _maxUsable() internal pure returns (int24) { return (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING; }
    function _minUsable() internal pure returns (int24) { return (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING; }

    /// @notice Validates a caller-supplied launch tick: strictly inside the usable band (so the single-sided range
    /// is non-empty in both orientations) and a multiple of {TICK_SPACING}. Misaligned ticks are refused, not
    /// rounded. The range check runs before {_align} to avoid an int24 underflow.
    function _checkedTick(int24 tick) internal pure returns (int24 t) {
        if (tick <= _minUsable() || tick >= _maxUsable()) revert BadLaunchTick();
        t = _align(tick);
        if (t != tick) revert BadLaunchTick();
    }

    function _align(int24 tick) internal pure returns (int24) {
        int24 s = TICK_SPACING;
        int24 aligned = (tick / s) * s;
        if (tick < 0 && tick % s != 0) aligned -= s;
        int24 maxU = (TickMath.MAX_TICK / s) * s;
        int24 minU = _minUsable();
        if (aligned > maxU) aligned = maxU;
        if (aligned < minU) aligned = minU;
        return aligned;
    }

    function _keyForPair(address token, address quote, bool coinIsC0, address hook) internal pure returns (PoolKey memory) {
        (address c0, address c1) = coinIsC0 ? (token, quote) : (quote, token);
        return PoolKey({
            currency0: Currency.wrap(c0), currency1: Currency.wrap(c1),
            fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(hook)
        });
    }

    function _zapEthToQuote(address quote, uint256 ethIn, bytes calldata path, uint256 minOut) internal returns (uint256 got) {
        require((path.length >= 20 ? path.length - 20 : 20) % 23 == 0, "path malformed");
        require(path.length >= 20 && address(bytes20(path[path.length - 20:])) == quote, "path not to quote");
        require(address(bytes20(path[0:20])) == weth, "path not from WETH");
        IWETH9(weth).deposit{value: ethIn}();
        IERC20(weth).forceApprove(swapRouter, ethIn);
        uint256 before = IERC20(quote).balanceOf(address(this));
        try ISwapRouter02(swapRouter).exactInput(
            ISwapRouter02.ExactInputParams({path: path, recipient: address(this), amountIn: ethIn, amountOutMinimum: minOut})
        ) returns (uint256) {} catch {
            revert("dev-buy zap failed: check ethQuotePath and minQuoteOut, or use a smaller amount");
        }
        IERC20(weth).forceApprove(swapRouter, 0);
        got = IERC20(quote).balanceOf(address(this)) - before;
        require(got > 0 && got >= minOut, "dev buy landed below minQuoteOut (or the pair is too illiquid)");
    }

    function _liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) private pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, Q96);
        uint256 l0 = FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA);
        return l0 > type(uint128).max ? type(uint128).max : uint128(l0);
    }

    function _liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) private pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 l1 = FullMath.mulDiv(amount1, Q96, sqrtB - sqrtA);
        return l1 > type(uint128).max ? type(uint128).max : uint128(l1);
    }

    /// @dev Everything about where a launch puts its liquidity, in one place. Used by {_finishLaunch},
    /// {_seedMultiPool} and the dev-buy quote, so none of them can disagree about ticks or liquidity.
    struct LaunchGeometry {
        bool coinIsC0;
        int24 poolTick;     // the pool-native launch tick (quote-per-coin negated when the coin is currency1)
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @dev `launchTick` is quote-per-coin (see {_finishLaunch} for the sign convention). Reverts `BadLaunchTick` /
    /// `BadLiquidity` exactly as a launch does, before any state is written.
    function _launchGeometry(address token, address quote, int24 launchTick, uint256 seedAmount)
        internal
        pure
        returns (LaunchGeometry memory g)
    {
        g.coinIsC0 = token < quote;
        int24 quotePerCoinTick = _checkedTick(launchTick);
        g.poolTick = g.coinIsC0 ? quotePerCoinTick : -quotePerCoinTick;
        if (g.coinIsC0) { g.tickLower = g.poolTick; g.tickUpper = _maxUsable(); }
        else            { g.tickLower = _minUsable(); g.tickUpper = g.poolTick; }
        uint160 sLo = TickMath.getSqrtPriceAtTick(g.tickLower);
        uint160 sHi = TickMath.getSqrtPriceAtTick(g.tickUpper);
        g.liquidity = g.coinIsC0 ? _liquidityForAmount0(sLo, sHi, seedAmount) : _liquidityForAmount1(sLo, sHi, seedAmount);
        if (g.liquidity == 0 || g.liquidity > Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING)) revert BadLiquidity();
    }

    // ─────────────────────────── ETH-native launch ───────────────────────────
    //
    // Native ETH is `quote == address(0)`; every family funnels into {_finishLaunch}. Entry-point names, param
    // encodings and the TaxLaunch + DevBuySettled events are relied on by the frontend and indexers.

    function launch(LaunchParams calldata p) external payable nonReentrant returns (address token) {
        return _launch(p);
    }

    function launchWithMeta(LaunchParams calldata p, Meta calldata meta) external payable nonReentrant returns (address token) {
        token = _launch(p);
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }



    function _launch(LaunchParams calldata p) internal returns (address token) {
        if (p.totalSupply == 0) revert SupplyZero();
        if (p.totalSupply > uint256(uint128(type(int128).max))) revert SupplyTooLarge();

        (uint256 _mwCap, uint32 _mwSecs) = _maxWalletOf(p.totalSupply, p.maxWalletBps, p.maxWalletMins, p.tax.tradingDelaySecs);
        token = RealmAnyPairsV4TokenDeployer.deployPlain(
            p.name, p.symbol, p.totalSupply, address(this), msg.sender,
            _mwCap, _mwSecs, p.tax.whitelist, p.salt
        );
        if (_mwCap != 0) emit MaxWalletSet(token, _mwCap, uint40(block.timestamp + _mwSecs));
        _createVaults(token, p.vaults, p.totalSupply, p.maxWalletMins);

        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory cp = p.tax;
        cp.creator = msg.sender;
        cp.rewardsTracker = address(0);
        cp.rewardsBps = 0;
        // `msg.data[:0]` is an empty `bytes calldata` slice: the native path has no ETH->quote zap path.
        _finishLaunch(
            FinishParams(token, address(0), p.totalSupply, 0, p.launchTick),
            cp, msg.data[:0], _devBuySplit(p.devBuyRecipients, p.devBuyBps)
        );
    }

    // ─────────────────────────── ETH-native rewards launch ─────────────────────────────────────────────

    function launchRewards(RewardsLaunchParams calldata p) external payable nonReentrant returns (address token, address tracker) {
        return _launchRewards(p);
    }

    function launchRewardsWithMeta(RewardsLaunchParams calldata p, Meta calldata meta) external payable nonReentrant returns (address token, address tracker) {
        (token, tracker) = _launchRewards(p);
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }



    function _launchRewards(RewardsLaunchParams calldata p) internal returns (address token, address tracker) {
        if (p.totalSupply == 0) revert SupplyZero();
        if (p.totalSupply > uint256(uint128(type(int128).max))) revert SupplyTooLarge();
        if (p.totalSupply < MIN_REWARDS_TOTAL_SUPPLY) revert SupplyTooSmallForRewards();

        (uint256 _mwCap, uint32 _mwSecs) = _maxWalletOf(p.totalSupply, p.maxWalletBps, p.maxWalletMins, p.tax.tradingDelaySecs);
        token = RealmAnyPairsV4TokenDeployer.deployDividend(
            p.name, p.symbol, p.totalSupply, address(this), msg.sender,
            _mwCap, _mwSecs, p.tax.whitelist, p.salt
        );
        if (_mwCap != 0) emit MaxWalletSet(token, _mwCap, uint40(block.timestamp + _mwSecs));

        address[] memory vaults = _createVaults(token, p.vaults, p.totalSupply, p.maxWalletMins);
        tracker = _deployNativeTracker(token, p.totalSupply, vaults);
        IDividendTokenInit(token).initTracker(tracker);
        _syncLaunchVaults(tracker, vaults);

        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory cp = p.tax;
        cp.creator = msg.sender;
        cp.rewardsTracker = tracker;
        _finishLaunch(
            FinishParams(token, address(0), p.totalSupply, 0, p.launchTick),
            cp, msg.data[:0], _devBuySplit(p.devBuyRecipients, p.devBuyBps)
        );
        // AFTER the TaxLaunch/DevBuySettled pair {_finishLaunch} emits, preserving the exact event ORDER
        // an ETH rewards launch has always produced: TaxLaunch, DevBuySettled, RewardsLaunch.
        emit RewardsLaunch(token, tracker, cp.rewardsBps);
        // Emits nothing, so the frozen event order above is untouched. See {_syncLaunchHolders}.
        _syncLaunchHolders(tracker, _devBuySplit(p.devBuyRecipients, p.devBuyBps), cp.creator);
    }

    /// @dev The native rewards tracker ({RealmAnyPairsDividendTracker}): pays holders in ETH and is funded by the
    /// hook via `feed{value:}`.
    function _deployNativeTracker(address token, uint256 totalSupply, address[] memory vaults) internal returns (address) {
        address[] memory ex = _trackerExcluded(vaults);

        RealmAnyPairsDividendTracker.Config memory c;
        c.token = token;
        c.feeder = address(pairTaxHook);
        c.minEligible = totalSupply / 1e4;
        c.excluded = ex;
        c.poolManager = address(poolManager);
        return RealmAnyPairsV4TokenDeployer.deployTracker(c);
    }

    // ─────────────────────────── ETH-native rewards basket launch ───────────────────────────
    // Same as {launchRewards} (variants, validation, event order); only the tracker differs.

    function launchRewardsBasket(RewardsBasketLaunchParams calldata p) external payable nonReentrant returns (address token, address tracker) {
        return _launchNativeRewardsBasket(p);
    }

    function launchRewardsBasketWithMeta(RewardsBasketLaunchParams calldata p, Meta calldata meta) external payable nonReentrant returns (address token, address tracker) {
        (token, tracker) = _launchNativeRewardsBasket(p);
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }



    function _launchNativeRewardsBasket(RewardsBasketLaunchParams calldata p) internal returns (address token, address tracker) {
        if (p.totalSupply == 0) revert SupplyZero();
        if (p.totalSupply > uint256(uint128(type(int128).max))) revert SupplyTooLarge();
        if (p.totalSupply < MIN_REWARDS_TOTAL_SUPPLY) revert SupplyTooSmallForRewards();

        {
            (uint256 _mwCap, uint32 _mwSecs) = _maxWalletOf(p.totalSupply, p.maxWalletBps, p.maxWalletMins, p.tax.tradingDelaySecs);
            token = RealmAnyPairsV4TokenDeployer.deployDividend(
                p.name, p.symbol, p.totalSupply, address(this), msg.sender,
                _mwCap, _mwSecs, p.tax.whitelist, p.salt
            );
            if (_mwCap != 0) emit MaxWalletSet(token, _mwCap, uint40(block.timestamp + _mwSecs));
        }

        address[] memory vaults = _createVaults(token, p.vaults, p.totalSupply, p.maxWalletMins);
        tracker = _deployNativeBasketTracker(token, p.totalSupply, p.basket, p.basketRoutes, vaults);
        IDividendTokenInit(token).initTracker(tracker);
        _syncLaunchVaults(tracker, vaults);

        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory cp = p.tax;
        cp.creator = msg.sender;
        cp.rewardsTracker = tracker;
        _finishLaunch(
            FinishParams(token, address(0), p.totalSupply, 0, p.launchTick),
            cp, msg.data[:0], _devBuySplit(p.devBuyRecipients, p.devBuyBps)
        );
        emit RewardsLaunch(token, tracker, cp.rewardsBps);
        _syncLaunchHolders(tracker, _devBuySplit(p.devBuyRecipients, p.devBuyBps), cp.creator);
    }

    /// @dev The NATIVE-paired basket launch path: builds a single WETH-input basket and deploys the
    /// auto-converting tracker. `swapRouter` is read at launch and frozen into the tracker.
    /// @dev RENAMED in audit round 17 from `_deployEthBasketTracker`. It has deployed a
    /// {RealmAnyPairsDividendTrackerAutoBasket} since round 108, and the `…EthBasket` tracker it was named after
    /// was deleted in round 17 -- a helper named for a contract that no longer exists is a false signpost.
    function _deployNativeBasketTracker(
        address token, uint256 totalSupply, RealmAnyPairsDividendTrackerAutoBasket.Leg[] calldata basket,
        bytes[] calldata routes, address[] memory vaults
    ) internal returns (address) {
        // Native fees are wrapped to WETH and converted from there; a WETH leg is paid as WETH.
        RealmAnyPairsDividendTrackerAutoBasket.InputBasket[] memory ins = new RealmAnyPairsDividendTrackerAutoBasket.InputBasket[](1);
        ins[0].input = weth;
        ins[0].legs = new RealmAnyPairsDividendTrackerAutoBasket.Leg[](basket.length);
        for (uint256 i; i < basket.length; ++i) {
            ins[0].legs[i] = RealmAnyPairsDividendTrackerAutoBasket.Leg(basket[i].asset, basket[i].bps);
        }
        ins[0].routes = routes; // validated leg by leg in the tracker's constructor, exactly as {setRoute} validates
        return _deployAutoTracker(token, totalSupply, ins, vaults);
    }

    /// @dev Every basket launch (pair, native, multi-pair) deploys {RealmAnyPairsDividendTrackerAutoBasket}.
    function _deployAutoTracker(
        address token, uint256 totalSupply, RealmAnyPairsDividendTrackerAutoBasket.InputBasket[] memory ins,
        address[] memory vaults
    ) internal returns (address) {
        // The one shared cap: one quote + three converting reward tokens (audit round 8, F4).
        if (_autoSyncGas(ins) > RealmAnyPairsGasLib.MAX_TRACKER_STIPEND) revert BasketTooHeavy();
        RealmAnyPairsDividendTrackerAutoBasket.Config memory c;
        c.token = token;
        c.feeder = address(pairTaxHook);
        c.swapRouter = swapRouter;
        c.v3Factory = v3Factory;
        c.poolManager = address(poolManager);
        c.weth = weth;
        c.minEligible = totalSupply / 1e4;
        c.excluded = _trackerExcluded(vaults);
        c.inputs = ins;
        return RealmAnyPairsV4PairTrackerDeployer.deployAutoBasketTracker(c);
    }

    /// @dev The per-transfer balance-sync gas the auto-basket tracker will publish for `ins`: 170k + 34k per distinct
    /// denomination (inputs and assets) + 80k per converting leg. MIRRORS the tracker's constants; the coin forwards at
    /// most 1.1M, and the tracker constructor enforces the same bound.
    function _autoSyncGas(RealmAnyPairsDividendTrackerAutoBasket.InputBasket[] memory ins) internal pure returns (uint256) {
        address[] memory seen = new address[](128);
        uint256 dn;
        uint256 conv;
        for (uint256 i; i < ins.length; ++i) {
            dn = _addSeen(seen, dn, ins[i].input);
            RealmAnyPairsDividendTrackerAutoBasket.Leg[] memory legs = ins[i].legs;
            for (uint256 j; j < legs.length; ++j) {
                dn = _addSeen(seen, dn, legs[j].asset);
                if (legs[j].asset != ins[i].input) ++conv;
            }
        }
        return 170_000 + 34_000 * dn + 80_000 * conv;
    }

    function _addSeen(address[] memory seen, uint256 n, address a) internal pure returns (uint256) {
        for (uint256 k; k < n; ++k) {
            if (seen[k] == a) return n;
        }
        if (n < seen.length) seen[n] = a;
        return n + 1;
    }
    // ─────────────────────────── single-pair launch ───────────────────────────

    function launchPair(PairLaunchParams calldata p) external payable nonReentrant returns (address token) {
        return _launch(p, msg.sender);
    }

    function launchPairWithMeta(PairLaunchParams calldata p, Meta calldata meta) external payable nonReentrant returns (address token) {
        token = _launch(p, msg.sender);
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }

    function _launch(PairLaunchParams calldata p, address creator) internal returns (address token) {
        // ERC20 quotes only: a zero `pairToken` would emit the native event family from a `launchPair*` call.
        if (p.pairToken == address(0)) revert ZeroAddress();
        if (p.totalSupply == 0) revert SupplyZero();
        if (p.totalSupply > uint256(uint128(type(int128).max))) revert SupplyTooLarge();
        // Scoped so the max-wallet values leave the stack before {_finishLaunch}; otherwise via-IR hits stack too deep.
        {
            (uint256 _mwCap, uint32 _mwSecs) = _maxWalletOf(p.totalSupply, p.maxWalletBps, p.maxWalletMins, p.tradingDelaySecs);
            token = RealmAnyPairsV4TokenDeployer.deployPlain(
                p.name, p.symbol, p.totalSupply, address(this), creator,
                _mwCap, _mwSecs, p.whitelist, p.salt
            );
            if (_mwCap != 0) emit MaxWalletSet(token, _mwCap, uint40(block.timestamp + _mwSecs));
        }
        _createVaults(token, p.vaults, p.totalSupply, p.maxWalletMins);
        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory cp = RealmAnyPairsTaxHookPairImmutable.ConfigParams({
            creator: creator, buyBps: p.buyBps, sellBps: p.sellBps,
            recipients: p.recipients, splitBps: p.splitBps, rewardsTracker: address(0), rewardsBps: 0,
            autoSend: p.autoSend, autoThreshold: p.autoThreshold,
            maxBuyBps: p.maxBuyBps, launchTaxBps: p.launchTaxBps,
            launchTaxSecs: p.launchTaxSecs, tradingDelaySecs: p.tradingDelaySecs,
            buybackBps: p.buybackBps, lpBps: p.lpBps,
            whitelist: p.whitelist
        });
        _finishLaunch(
            FinishParams(token, p.pairToken, p.totalSupply, p.minQuoteOut, p.launchTick),
            cp, p.ethQuotePath, _devBuySplit(p.devBuyRecipients, p.devBuyBps)
        );
    }

    function launchPairRewards(PairRewardsLaunchParams calldata p) external payable nonReentrant returns (address token, address tracker) {
        return _launchRewards(p, msg.sender);
    }

    function launchPairRewardsWithMeta(PairRewardsLaunchParams calldata p, Meta calldata meta) external payable nonReentrant returns (address token, address tracker) {
        (token, tracker) = _launchRewards(p, msg.sender);
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }

    function _launchRewards(PairRewardsLaunchParams calldata p, address creator_) internal returns (address token, address tracker) {
        // ERC20 quotes only: this quote tracker cannot be funded from a native pool, so rewards would be stranded.
        if (p.pairToken == address(0)) revert ZeroAddress();
        if (p.totalSupply == 0) revert SupplyZero();
        if (p.totalSupply > uint256(uint128(type(int128).max))) revert SupplyTooLarge();
        if (p.totalSupply < MIN_REWARDS_TOTAL_SUPPLY) revert SupplyTooSmallForRewards();
        address creator = creator_;

        (uint256 _mwCap, uint32 _mwSecs) = _maxWalletOf(p.totalSupply, p.maxWalletBps, p.maxWalletMins, p.tradingDelaySecs);
        token = RealmAnyPairsV4TokenDeployer.deployDividend(
            p.name, p.symbol, p.totalSupply, address(this), creator,
            _mwCap, _mwSecs, p.whitelist, p.salt
        );
        if (_mwCap != 0) emit MaxWalletSet(token, _mwCap, uint40(block.timestamp + _mwSecs));
        address[] memory vaults = _createVaults(token, p.vaults, p.totalSupply, p.maxWalletMins);
        address[] memory ex = _trackerExcluded(vaults);
        tracker = RealmAnyPairsV4PairTrackerDeployer.deployQuoteTracker(RealmAnyPairsDividendTrackerQuote.Config({
            token: token, feeder: address(pairTaxHook),
            // The one field that makes a coin a reflections coin.
            quote: p.rewardsInCoin ? token : p.pairToken,
            poolManager: address(poolManager),
            minEligible: p.totalSupply / 1e4, excluded: ex
        }));
        IDividendTokenInit(token).initTracker(tracker);
        _syncLaunchVaults(tracker, vaults);

        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory cp = RealmAnyPairsTaxHookPairImmutable.ConfigParams({
            creator: creator, buyBps: p.buyBps, sellBps: p.sellBps,
            recipients: p.recipients, splitBps: p.splitBps,
            rewardsTracker: tracker, rewardsBps: p.rewardsBps, autoSend: p.autoSend,
            autoThreshold: p.autoThreshold,
            maxBuyBps: p.maxBuyBps, launchTaxBps: p.launchTaxBps,
            launchTaxSecs: p.launchTaxSecs, tradingDelaySecs: p.tradingDelaySecs,
            buybackBps: p.buybackBps, lpBps: p.lpBps,
            whitelist: p.whitelist
        });
        _finishLaunch(
            FinishParams(token, p.pairToken, p.totalSupply, p.minQuoteOut, p.launchTick),
            cp, p.ethQuotePath, _devBuySplit(p.devBuyRecipients, p.devBuyBps)
        );
        // Emitted after {_finishLaunch} to keep the event order TaxLaunch, DevBuySettled, RewardsLaunch.
        emit RewardsLaunch(token, tracker, p.rewardsBps);
        _syncLaunchHolders(tracker, _devBuySplit(p.devBuyRecipients, p.devBuyBps), creator);
    }

    function launchPairRewardsBasket(PairRewardsBasketLaunchParams calldata p) external payable nonReentrant returns (address token, address tracker) {
        return _launchRewardsBasket(p, msg.sender);
    }

    function launchPairRewardsBasketWithMeta(PairRewardsBasketLaunchParams calldata p, Meta calldata meta) external payable nonReentrant returns (address token, address tracker) {
        (token, tracker) = _launchRewardsBasket(p, msg.sender);
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }

    function _launchRewardsBasket(PairRewardsBasketLaunchParams calldata p, address creator_) internal returns (address token, address tracker) {
        // ERC20 quotes only, for the same reason as {_launchRewards(PairRewardsLaunchParams)}.
        if (p.pairToken == address(0)) revert ZeroAddress();
        if (p.totalSupply == 0) revert SupplyZero();
        if (p.totalSupply > uint256(uint128(type(int128).max))) revert SupplyTooLarge();
        if (p.totalSupply < MIN_REWARDS_TOTAL_SUPPLY) revert SupplyTooSmallForRewards();
        address creator = creator_;

        (uint256 _mwCap, uint32 _mwSecs) = _maxWalletOf(p.totalSupply, p.maxWalletBps, p.maxWalletMins, p.tradingDelaySecs);
        token = RealmAnyPairsV4TokenDeployer.deployDividend(
            p.name, p.symbol, p.totalSupply, address(this), creator,
            _mwCap, _mwSecs, p.whitelist, p.salt
        );
        if (_mwCap != 0) emit MaxWalletSet(token, _mwCap, uint40(block.timestamp + _mwSecs));
        address[] memory vaults = _createVaults(token, p.vaults, p.totalSupply, p.maxWalletMins);
        tracker = _deployPairBasketTracker(token, p.pairToken, p.totalSupply, p.basket, p.basketRoutes, vaults);
        IDividendTokenInit(token).initTracker(tracker);
        _syncLaunchVaults(tracker, vaults);

        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory cp = RealmAnyPairsTaxHookPairImmutable.ConfigParams({
            creator: creator, buyBps: p.buyBps, sellBps: p.sellBps,
            recipients: p.recipients, splitBps: p.splitBps,
            rewardsTracker: tracker, rewardsBps: p.rewardsBps, autoSend: p.autoSend,
            autoThreshold: p.autoThreshold,
            maxBuyBps: p.maxBuyBps, launchTaxBps: p.launchTaxBps,
            launchTaxSecs: p.launchTaxSecs, tradingDelaySecs: p.tradingDelaySecs,
            buybackBps: p.buybackBps, lpBps: p.lpBps,
            whitelist: p.whitelist
        });
        _finishLaunch(
            FinishParams(token, p.pairToken, p.totalSupply, p.minQuoteOut, p.launchTick),
            cp, p.ethQuotePath, _devBuySplit(p.devBuyRecipients, p.devBuyBps)
        );
        // Emitted after {_finishLaunch} to keep the event order TaxLaunch, DevBuySettled, RewardsLaunch.
        emit RewardsLaunch(token, tracker, p.rewardsBps);
        _syncLaunchHolders(tracker, _devBuySplit(p.devBuyRecipients, p.devBuyBps), creator);
    }

    /// @dev Builds a single `quote`-input basket and deploys the auto-converting tracker. In its own frame to
    /// avoid stack too deep in the launch function.
    /// @dev RENAMED in audit round 17 from `_deployBasketTracker`, which collided by name with the linked library
    /// function {RealmAnyPairsV4PairTrackerDeployer.deployBasketTracker} deleted in the same round. This one is the
    /// PAIR basket launch path and deploys a {RealmAnyPairsDividendTrackerAutoBasket}; the deleted one constructed a
    /// {RealmAnyPairsDividendTrackerBasket} (itself deleted in round 17) and had no production caller at all.
    function _deployPairBasketTracker(
        address token, address quote, uint256 totalSupply, RealmAnyPairsDividendTrackerAutoBasket.Leg[] calldata basket,
        bytes[] calldata routes, address[] memory vaults
    ) internal returns (address) {
        RealmAnyPairsDividendTrackerAutoBasket.InputBasket[] memory ins = new RealmAnyPairsDividendTrackerAutoBasket.InputBasket[](1);
        ins[0].input = quote;
        ins[0].legs = new RealmAnyPairsDividendTrackerAutoBasket.Leg[](basket.length);
        for (uint256 i; i < basket.length; ++i) {
            ins[0].legs[i] = RealmAnyPairsDividendTrackerAutoBasket.Leg(basket[i].asset, basket[i].bps);
        }
        ins[0].routes = routes;
        return _deployAutoTracker(token, totalSupply, ins, vaults);
    }

    /// @dev One creator vesting vault: `bps` of the coin's TOTAL supply, nothing claimable before `cliffSecs`,
    /// linear from launch until `vestSecs`.
    struct VaultParams {
        address beneficiary;
        uint16 bps;
        uint32 cliffSecs;
        uint32 vestSecs;
    }

    uint256 internal constant MAX_VAULTS = 5;
    uint256 internal constant MAX_VAULT_BPS = 2_000;
    uint256 internal constant MAX_VAULT_CLIFF = 365 days;
    uint256 internal constant MAX_VAULT_VEST = 4 * 365 days;

    /// @notice A vault did not satisfy the bounds: at most 5, together <= 20% of supply, non-zero bps and
    /// vesting, cliff <= vesting, cliff <= 365 days, vesting <= 4 years, and a real beneficiary.
    error BadVault();
    /// @notice With a max wallet set, a vault's cliff must fall at or after the max-wallet window closes.
    error VaultCliffInsideMaxWallet(uint256 cliffSecs, uint256 maxWalletSecs);
    /// @notice A creator vesting vault was created and funded at launch.
    event CreatorVaultCreated(
        address indexed token, address indexed vault, address indexed beneficiary, uint256 amount, uint64 cliff, uint64 end
    );

    /// @dev Validate, clone, initialise and fund every vault. Called right after the coin is deployed and BEFORE
    /// any tracker, so the vaults can be excluded from rewards. `maxWalletMins` is the launch's own input (zero =
    /// no max wallet); its window is `maxWalletMins * 60` seconds, exactly as {_maxWalletOf} sets.
    function _createVaults(address token, VaultParams[] calldata vaults, uint256 totalSupply, uint16 maxWalletMins)
        internal
        returns (address[] memory addrs)
    {
        uint256 n = vaults.length;
        addrs = new address[](n);
        if (n == 0) return addrs;
        if (n > MAX_VAULTS) revert BadVault();
        uint256 mwSecs = uint256(maxWalletMins) * 60;
        uint256 lockedBps;
        for (uint256 i; i < n; ++i) {
            VaultParams calldata v = vaults[i];
            address b = v.beneficiary;
            if (b == address(0) || b == address(this) || b == address(pairLpLocker) || b == address(poolManager) || b == token) {
                revert BadVault();
            }
            if (v.bps == 0 || v.vestSecs == 0 || v.cliffSecs > v.vestSecs) revert BadVault();
            if (v.cliffSecs > MAX_VAULT_CLIFF || v.vestSecs > MAX_VAULT_VEST) revert BadVault();
            if (mwSecs != 0 && v.cliffSecs < mwSecs) revert VaultCliffInsideMaxWallet(v.cliffSecs, mwSecs);
            lockedBps += v.bps;
        }
        if (lockedBps > MAX_VAULT_BPS) revert BadVault();
        for (uint256 i; i < n; ++i) {
            VaultParams calldata v = vaults[i];
            uint256 amount = (totalSupply * v.bps) / BPS_DENOM;
            if (amount == 0) revert BadVault();
            address vault = RealmAnyPairsCloneLib.clone(vaultImplementation);
            RealmAnyPairsCreatorVault(vault).initialize(token, v.beneficiary, amount, uint64(block.timestamp), v.cliffSecs, v.vestSecs);
            IERC20(token).safeTransfer(vault, amount);
            addrs[i] = vault;
            emit CreatorVaultCreated(
                token, vault, v.beneficiary, amount,
                uint64(block.timestamp) + v.cliffSecs, uint64(block.timestamp) + v.vestSecs
            );
        }
    }

    /// @dev Every rewards tracker's exclusion list: the locker, the PoolManager, this launcher, the burn
    /// address, and this launch's vaults.
    function _trackerExcluded(address[] memory vaults) internal view returns (address[] memory ex) {
        uint256 n = vaults.length;
        ex = new address[](4 + n);
        ex[0] = address(pairLpLocker);
        ex[1] = address(poolManager);
        ex[2] = address(this);
        ex[3] = DEAD;
        for (uint256 i; i < n; ++i) ex[4 + i] = vaults[i];
    }

    /// @dev Register the addresses that already hold this coin with the launch's tracker. Best-effort and
    /// gas-capped; see the headings below. Split in two calls because the two sets become final at different
    /// points of a launch -- the vaults the moment the tracker exists, everything else once the pools are seeded
    /// and the dev buy has settled -- which also keeps the vault list from having to stay live across the whole
    /// of a launch function (see {FinishParams} for why this file cares about that).
    ///
    /// WHY IT IS NEEDED. A tracker only ever learns a balance because the coin told it, and the coin's CREDIT
    /// leg is deliberately skippable ({RealmAnyPairsTokenDividend._update} runs it only above `minNotify`).
    /// Several launch-time balances sit outside that guarantee:
    ///   * The creator vesting vaults are funded by {_createVaults}, which runs BEFORE {initTracker} -- so no
    ///     notification ever ran for them and the tracker has never heard of their coin. Vaults are EXCLUDED,
    ///     and a buffered release divides by `_attributableSupply() = totalSupply - excludedSupply`. An
    ///     unmirrored vault therefore inflates that denominator by up to 20% of supply (the {MAX_VAULT_BPS}
    ///     ceiling), so the first release pays the registered book only a fraction of what it is owed and the
    ///     residue comes out later, booked across whoever is registered by then. The same argument applies to
    ///     the PoolManager's seed and to any tax the hook is already holding: both are credited by the coin's
    ///     OPTIONAL leg, so a launch running close to its gas limit can leave either of them unmirrored.
    ///   * The dev-buy recipients are credited by the payout transfer itself, but again only if that transfer
    ///     carried `minNotify` gas. A gas-tight launch can credit one recipient and skip the next, and the
    ///     registered one is then present for releases the skipped one misses -- the ordering advantage.
    /// Rewards that arrive while eligible supply is under `minEligibleFloor` cannot be booked and are buffered,
    /// so a launch is exactly when this matters: at that moment the whole float is the addresses below.
    ///
    /// VAULTS AND EXCLUDED ADDRESSES ARE NOT MADE ELIGIBLE, AND CANNOT BE. `syncBalance` re-applies the coin's
    /// real balance THROUGH the tracker's `excluded` mapping: an excluded account is mirrored into
    /// `excludedBalance`/`excludedSupply` and pinned to a tracked balance of zero, so it earns nothing and joins
    /// no push ring. For a vault this call can only ever correct the release DENOMINATOR. The list is built by
    /// {_trackerExcluded} -- the very list the tracker was constructed to exclude -- so the two cannot drift,
    /// and the feeder (the hook) is excluded by the tracker's own constructor.
    ///
    /// NOTHING HERE CAN REVERT A LAUNCH. The stipend is the tracker's own published `balanceSyncGas`, read by
    /// raw staticcall and clamped to {RealmAnyPairsGasLib.MAX_TRACKER_STIPEND} -- the established budget, the
    /// same one the coin's transfer path forwards; a tracker that does not answer is simply not synced. Each
    /// repair is gas-capped and wrapped in try/catch, and one is never STARTED unless the frame can spare the
    /// whole stipend after EIP-150's 63/64 rule. That is the same best-effort posture as the coin's credit leg,
    /// and it is why this cannot brick a launch however heavy a tracker behaves. (A HOSTILE tracker is not
    /// reachable on this path at all: the launcher only ever syncs a tracker it deployed itself, in this same
    /// transaction, from its own linked deployers. The posture is kept anyway, because a launch reverting is
    /// the one outcome this repair must never be able to cause.)
    ///
    /// NOT A GENERAL REGISTRATION MECHANISM. Ordinary buyers self-register on their own buy, and buffering
    /// stops for good once eligible supply passes `minEligibleFloor`. This covers only the addresses that exist
    /// before any buy has happened.
    ///
    /// THIS HALF is the VAULTS, called as soon as {initTracker} has run: a vault is funded before the tracker
    /// exists and never moves again during a launch, so this is both the earliest and the last word on it.
    function _syncLaunchVaults(address tracker_, address[] memory vaults) internal {
        uint256 n = vaults.length;
        if (n == 0) return;
        uint256 stipend = _trackerStipend(tracker_);
        if (stipend == 0) return;
        for (uint256 i; i < n; ++i) _syncOneHolder(tracker_, vaults[i], stipend);
    }

    /// @dev The EVERYTHING-ELSE half, called once the pools are seeded and the dev buy has settled: the excluded
    /// infrastructure, whose balances are only final then, and the dev-buy recipients.
    function _syncLaunchHolders(address tracker_, DevBuySplit memory split, address creator) internal {
        uint256 stipend = _trackerStipend(tracker_);
        if (stipend == 0) return;
        // {_trackerExcluded} with no vaults: this launch's vaults are already done by {_syncLaunchVaults}.
        address[] memory ex = _trackerExcluded(new address[](0));
        uint256 n = ex.length;
        for (uint256 i; i < n; ++i) _syncOneHolder(tracker_, ex[i], stipend);
        // The hook is excluded by the tracker's constructor (`excluded[c.feeder]`), not by {_trackerExcluded},
        // and it can already be holding this launch's dev-buy tax.
        _syncOneHolder(tracker_, address(pairTaxHook), stipend);

        // The dev-buy payout is the only coin a NON-excluded address can hold at this point, so with no dev buy
        // there is nothing left to register.
        if (msg.value == 0) return;
        address[] memory r = split.recipients;
        n = r.length;
        if (n == 0) {
            _syncOneHolder(tracker_, creator, stipend); // the whole dev buy went to the creator
        } else {
            for (uint256 i; i < n; ++i) _syncOneHolder(tracker_, r[i], stipend);
        }
    }

    /// @dev The per-address stipend for this tracker: its OWN published `balanceSyncGas`, clamped to the
    /// platform cap. Zero means "do not sync at all" -- a tracker that has no code, does not answer, or reports
    /// zero is skipped rather than allowed to revert the launch.
    function _trackerStipend(address tracker_) private view returns (uint256) {
        if (tracker_ == address(0) || tracker_.code.length == 0) return 0;
        (bool ok, bytes memory ret) =
            tracker_.staticcall{gas: 50_000}(abi.encodeWithSelector(IDividendTrackerSync.balanceSyncGas.selector));
        if (!ok || ret.length < 32) return 0;
        uint256 stipend = abi.decode(ret, (uint256));
        if (stipend > RealmAnyPairsGasLib.MAX_TRACKER_STIPEND) stipend = RealmAnyPairsGasLib.MAX_TRACKER_STIPEND;
        return stipend;
    }

    /// @dev One gas-capped, isolated repair. See {_syncLaunchVaults} for why neither leg may revert.
    function _syncOneHolder(address tracker_, address account, uint256 stipend) private {
        if (account == address(0)) return;
        // Do not start a repair that cannot receive its whole stipend after EIP-150's 63/64 rule.
        if (gasleft() < stipend + stipend / 63 + 10_000) return;
        try IDividendTrackerSync(tracker_).syncBalance{gas: stipend}(account) {} catch {}
    }

    /// @dev A dev-buy split, carried as ONE memory value so the launch paths use a single stack slot.
    struct DevBuySplit {
        address[] recipients;
        uint16[] bps;
    }

    function _devBuySplit(address[] calldata recipients, uint16[] calldata bps) internal pure returns (DevBuySplit memory s) {
        s.recipients = recipients;
        s.bps = bps;
    }

    /// @dev Calls the locker's split `launch` when a split was given, its original form otherwise.
    function _lockerLaunch(
        uint256 value, PoolKey memory key, uint128 liquidity, int24 tickLower, int24 tickUpper, address creator,
        bool quoteIsC0, uint256 devBuyQuote, uint256 coinAmountIn, DevBuySplit memory split
    ) internal returns (uint256) {
        if (split.recipients.length == 0 && split.bps.length == 0) {
            return pairLpLocker.launch{value: value}(
                key, liquidity, tickLower, tickUpper, creator, quoteIsC0, devBuyQuote, coinAmountIn
            );
        }
        return pairLpLocker.launch{value: value}(
            key, liquidity, tickLower, tickUpper, creator, quoteIsC0, devBuyQuote, coinAmountIn, split.recipients, split.bps
        );
    }

    /// @dev The scalar half of a launch, in one place.
    ///
    /// AUDIT ROUND 12, BUILD FIX. {_finishLaunch} took nine parameters, six of them scalars, and every one of them
    /// stayed live across the whole body -- through `initialize`, `configurePool`, the orientation cross-check, the
    /// dev-buy zap and the frozen events. Under via-IR that frame sat exactly ONE slot inside the limit: it built at
    /// `optimizer_runs = 200` against one set of library sources and failed to build at `runs >= 1000`, or at 200
    /// against slightly different ones, with `Variable _25 is 1 too deep in the stack`. A build that depends on which
    /// copy of v4-core happens to be on disk is not a build. Packing the scalars into one memory struct takes five
    /// slots out of the frame at every call site and inside the function, which fixes it with margin rather than by
    /// one slot. The line above {_pairRewardsBasket}'s scoped block records the same problem being patched locally in
    /// an earlier round; this is the general version of that fix.
    ///
    /// NOT fixed by raising `optimizer_runs` or turning off via-IR: the frame would still be one slot from the edge,
    /// so the next parameter anyone adds re-breaks it, and the settings that hid it are not the settings we deploy.
    struct FinishParams {
        address token;
        address quote;
        uint256 totalSupply;
        uint256 minQuoteOut;
        int24 launchTick;
    }

    function _finishLaunch(
        FinishParams memory f,
        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory cp,
        bytes calldata ethQuotePath,
        DevBuySplit memory split
    ) internal {
        address token = f.token;
        address quote = f.quote;
        if (token == quote) revert TokenEqualsQuote();
        _requireSaneParty(cp.creator);

        // One path for native and ERC20 quotes. `native` only decides whether the quote sanity checks run, whether
        // the dev buy is zapped, and which frozen event pair is emitted.
        bool native = quote == address(0);
        // Quote sanity checks apply to ERC20 quotes only; see {_requireSaneQuote}.
        if (!native) _requireSaneQuote(quote);
        // `address(0)` is the smallest address, so a native quote always sorts as currency0 with no special case.
        bool coinIsC0 = token < quote;
        PoolKey memory key = _keyForPair(token, quote, coinIsC0, address(pairTaxHook));

        // `launchTick` is quote-per-coin; {_launchGeometry} validates it and negates it into the pool tick when the
        // coin sorts as currency1.
        // Seed what this launcher still holds (total supply minus vesting vaults); events report the real `totalSupply`.
        uint256 seedSupply = IERC20(token).balanceOf(address(this));
        LaunchGeometry memory g = _launchGeometry(token, quote, f.launchTick, seedSupply);
        int24 launchTick_ = g.poolTick;
        int24 tickLower = g.tickLower;
        int24 tickUpper = g.tickUpper;

        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(launchTick_));
        pairTaxHook.configurePool(key, cp);

        // Cross-check the hook's stored orientation against address ordering; a mismatch would tax buys as sells for
        // the life of the pool.
        (
            , , , , , ,
            bool storedQuoteIsC0,
            address storedQuote,
            , ,
        ) = pairTaxHook.config(key.toId());
        if (storedQuote != quote || storedQuoteIsC0 != !coinIsC0) revert QuoteOrientationMismatch();

        // Computed and bounds-checked in {_launchGeometry}, before any state was written.
        uint128 liquidity = g.liquidity;

        // Dev buy: for an ERC20 quote `msg.value` is zapped into the quote and transferred to the locker; for native,
        // `msg.value` already is the quote and is sent as the value of the locker's `launch` call.
        uint256 devBuyQuote = 0;
        if (msg.value > 0) {
            if (native) {
                devBuyQuote = msg.value;
            } else {
                if (ethQuotePath.length < 43) revert BadDevBuyPath();
                devBuyQuote = _zapEthToQuote(quote, msg.value, ethQuotePath, f.minQuoteOut);
                // Re-measured at the locker so a fee-on-transfer quote reports what actually arrived.
                uint256 lockerBefore = IERC20(quote).balanceOf(address(pairLpLocker));
                IERC20(quote).safeTransfer(address(pairLpLocker), devBuyQuote);
                devBuyQuote = IERC20(quote).balanceOf(address(pairLpLocker)) - lockerBefore;
                // The ETH is already spent; if nothing arrived, unwind. See {DevBuyProducedNothing}.
                if (devBuyQuote == 0) revert DevBuyProducedNothing();
            }
        }

        // Price pin: nothing may move the price between `initialize` and the seed, which the locker's single-sided
        // seed relies on. A tautology on the native path, but cheap.
        (uint160 sqrtNow,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (sqrtNow != TickMath.getSqrtPriceAtTick(launchTick_)) revert LaunchPriceMoved();

        bool ok = IERC20(token).transfer(address(pairLpLocker), seedSupply);
        if (!ok) revert SeedTransferFailed();
        uint256 quoteSpent = _lockerLaunch(
            native ? devBuyQuote : 0, key, liquidity, tickLower, tickUpper, cp.creator, !coinIsC0, devBuyQuote, seedSupply, split
        );

        // Frozen events, branched on the quote: indexers derive a coin's type from WHICH event fired, so do not merge
        // these into one PairLaunch with a zero quote.
        if (native) {
            emit TaxLaunch(token, cp.creator, f.totalSupply, launchTick_, msg.value);
            emit DevBuySettled(token, msg.value, quoteSpent);
        } else {
            emit PairLaunch(token, cp.creator, quote, f.totalSupply, launchTick_, msg.value);
            emit PairDevBuySettled(token, quote, msg.value, quoteSpent);
        }
    }

    // ─────────────────────────── multi-pair launch ─────────────────────────────────────────────────────

    function launchMultiPair(MultiLaunchParams calldata p) external payable nonReentrant returns (address token, address tracker) {
        return _launchMultiPair(p);
    }

    /// @notice {launchMultiPair}, carrying the coin's profile (logo/banner/socials) in the launch
    /// transaction so its art is on chain with no follow-up signature.
    function launchMultiPairWithMeta(MultiLaunchParams calldata p, Meta calldata meta)
        external payable nonReentrant returns (address token, address tracker)
    {
        (token, tracker) = _launchMultiPair(p);
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }

    function _launchMultiPair(MultiLaunchParams calldata p) internal returns (address token, address tracker) {
        if (p.totalSupply == 0) revert SupplyZero();
        if (p.totalSupply > uint256(uint128(type(int128).max))) revert SupplyTooLarge();
        uint256 pairCount = p.pairs.length;
        if (pairCount == 0) revert NoPairs();

        // Pool/denomination ceiling, applied to every multi-pair launch.
        if (pairCount > defaultMaxDenominations) revert TooManyDenominationsForDefault();
        // Pools x (per-pool units + recipients + whitelist units + rewards dev-buy units) must fit {LAUNCH_UNIT_BUDGET}.
        if (
            pairCount
                    * ((p.rewardBaskets.length != 0 ? LAUNCH_UNITS_PER_REWARDS_POOL : LAUNCH_UNITS_PER_POOL) + p.recipients.length
                        + (p.whitelist.length * 3 + 3) / 4
                        + (p.rewardBaskets.length != 0 && msg.value != 0 ? LAUNCH_UNITS_REWARDS_DEV_BUY : 0))
                > LAUNCH_UNIT_BUDGET
        ) revert LaunchTooLarge();

        // Validate reward baskets against the caller's own input before anything is deployed. Zero baskets means
        // "not a rewards launch"; otherwise there must be exactly one basket per pair.
        if (p.rewardBaskets.length != 0 && p.rewardBaskets.length != pairCount) {
            revert RewardBasketsLengthMismatch(p.rewardBaskets.length, pairCount);
        }
        // `rewardsBps` without baskets would silently launch a reward-less coin. See {RewardsBpsWithoutBaskets}.
        if (p.rewardBaskets.length == 0 && p.rewardsBps != 0) revert RewardsBpsWithoutBaskets();
        // Cheap and unconditional now that the length is pinned: `rewardBaskets` is empty on a non-rewards
        // launch (the loop does not run), and at most `defaultMaxDenominations` calldata length reads
        // otherwise.
        {
            uint256 totalLegs;
            for (uint256 i; i < p.rewardBaskets.length; ++i) {
                // Per-basket bounds, mirrored from the tracker so the caller gets a named error before any deploy.
                uint256 n = p.rewardBaskets[i].length;
                if (n == 0) revert EmptyRewardBasket(i);
                if (n > MAX_LEGS_PER_BASKET) revert TooManyLegsInBasket(i, n, MAX_LEGS_PER_BASKET);
                totalLegs += n;
            }
            if (totalLegs > MAX_TOTAL_LEGS) revert TooManyTotalLegs();
        }

        bool rewards = p.rewardBaskets.length != 0;
        _validateMultiPairs(p.pairs, rewards);

        address creator = msg.sender;
        _requireSaneParty(creator);
        (uint256 mwCap, uint32 mwSecs) = _maxWalletOf(p.totalSupply, p.maxWalletBps, p.maxWalletMins, p.tradingDelaySecs);

        if (rewards) {
            if (p.totalSupply < MIN_REWARDS_TOTAL_SUPPLY) revert SupplyTooSmallForRewards();
            token = RealmAnyPairsV4TokenDeployer.deployDividend(
                p.name, p.symbol, p.totalSupply, address(this), creator, mwCap, mwSecs, p.whitelist, p.salt
            );
            address[] memory vaults = _createVaults(token, p.vaults, p.totalSupply, p.maxWalletMins);
            tracker = _deployMultiTracker(token, p, vaults);
            IDividendTokenInit(token).initTracker(tracker);
            _syncLaunchVaults(tracker, vaults);
        } else {
            token = RealmAnyPairsV4TokenDeployer.deployPlain(
                p.name, p.symbol, p.totalSupply, address(this), creator, mwCap, mwSecs, p.whitelist, p.salt
            );
            _createVaults(token, p.vaults, p.totalSupply, p.maxWalletMins);
        }

        // {MaxWalletSet} is the only event carrying the max wallet (the headline events are frozen).
        if (mwCap != 0) emit MaxWalletSet(token, mwCap, uint40(block.timestamp + mwSecs));

        // Announce the multi-pool shape before pool 0 emits the headline event, so indexers know the coin is
        // multi-pool from the start. `devBuyEth` is what pool 0 is offered.
        emit MultiPairLaunch(token, creator, pairCount, p.totalSupply, msg.value);

        uint256 distributedSupply;
        // Split what is left after the vaults, not the whole supply.
        uint256 seedSupply = IERC20(token).balanceOf(address(this));
        for (uint256 i; i < pairCount; ++i) {
            uint256 poolSupply = i + 1 == pairCount ? seedSupply - distributedSupply : (seedSupply * p.pairs[i].weightBps) / 10_000;
            distributedSupply += poolSupply;
            _seedMultiPool(token, creator, p, i, poolSupply, tracker, rewards, i == 0 ? msg.value : 0, _devBuySplit(p.devBuyRecipients, p.devBuyBps));
        }

        // Announced after the loop, so it follows pool 0's headline event that creates the coin downstream.
        // Guarded: a non-rewards launch has no tracker and must not announce a zero one.
        if (rewards) {
            emit RewardsLaunch(token, tracker, p.rewardsBps);
            _syncLaunchHolders(tracker, _devBuySplit(p.devBuyRecipients, p.devBuyBps), creator);
        }
    }

    /// @dev `rewards` is passed in because a NATIVE quote is legal here only on a non-rewards launch --
    /// see the branch below.
    function _validateMultiPairs(PairSpec[] calldata pairs, bool rewards) internal view {
        uint256 n = pairs.length;
        uint256 sumBps;
        for (uint256 i; i < n; ++i) {
            PairSpec calldata pair = pairs[i];
            bool native = pair.quoteToken == address(0);
            // Native is a legal multi-pair quote, but not on a rewards launch: the basket tracker needs ERC20 inputs.
            if (native && rewards) revert ZeroAddress();
            // ERC20 sanity checks only; see {_requireSaneQuote}.
            if (!native) _requireSaneQuote(pair.quoteToken);
            if (pair.weightBps == 0) revert ZeroWeight();
            sumBps += pair.weightBps;
            // Validate every pool's tick up front, before anything is deployed.
            _checkedTick(pair.launchTick);
            for (uint256 j; j < i; ++j) {
                if (pairs[j].quoteToken == pair.quoteToken) revert DuplicateQuote();
            }
        }
        if (sumBps != 10_000) revert WeightsNotOneHundredPercent();
    }

    function _deployMultiTracker(address token, MultiLaunchParams calldata p, address[] memory vaults) internal returns (address tracker) {
        uint256 pairCount = p.pairs.length;
        // Unreachable from the single call site, which already checks this; kept as a backstop for future callers.
        if (p.rewardBaskets.length != pairCount) revert RewardBasketsLengthMismatch(p.rewardBaskets.length, pairCount);
        // One auto-converting tracker fed in every pair's quote, each with its own basket. Its denominations are the
        // reward assets plus the quotes (for the fallback), capped at 25 by the tracker itself.
        // AUDIT ROUND 12 (L-1): the OUTER array is one entry per PAIR, and the tracker cannot see that dimension, so
        // check it here. Each inner array is length-checked against its own basket by the tracker's constructor.
        if (p.basketRoutes.length != 0 && p.basketRoutes.length != pairCount) {
            revert RewardBasketsLengthMismatch(p.basketRoutes.length, pairCount);
        }
        RealmAnyPairsDividendTrackerAutoBasket.InputBasket[] memory ins =
            new RealmAnyPairsDividendTrackerAutoBasket.InputBasket[](pairCount);
        for (uint256 i; i < pairCount; ++i) {
            // Round 12/13 build fix: the per-pair body is its own frame AND fills in place, so neither this loop
            // nor the helper carries a struct return across two calldata-to-memory copies. See {_oneInputBasket}.
            _oneInputBasket(ins[i], p, i);
        }
        tracker = _deployAutoTracker(token, p.totalSupply, ins, vaults);
    }

    /// @dev One pair's input basket: its quote, its legs, and its launch routes.
    /// @dev Fills `one` IN PLACE rather than returning a struct by value.
    /// @dev RENAMED in audit round 17 from `_oneMultiBasket`, which read as a reference to the deleted
    /// {RealmAnyPairsDividendTrackerMultiBasket}. It fills ONE {RealmAnyPairsDividendTrackerAutoBasket.InputBasket};
    /// the name now says that.
    ///
    /// AUDIT ROUND 13, BUILD FIX. Returning the struct meant the caller's frame held the returned pointer, the loop
    /// index, the array and the params pointer while the ABI copy ran, and that frame sat exactly ONE slot inside the
    /// via-IR limit: `Variable size_66 is 1 too deep in the stack [ ... expr_address_18 ... srcEnd src ... dst_1 ]`
    /// -- two calldata-to-memory array copies plus an address expression, which is the shape round 12 identified and
    /// only partly fixed. It was NOT reproducible from the source alone: the same commit, the same pinned
    /// dependencies and the same `foundry.toml` compiled in one checkout and failed in another, because solc's stack
    /// allocation depends on how Foundry groups sources into compilation units, and that grouping varies. An
    /// incremental build could therefore pass while a cold build of the same tree failed, which is exactly how this
    /// slipped past a green suite.
    ///
    /// Writing through the storage-free memory pointer the caller already allocated removes the return copy, which is
    /// two slots, so the frame now has margin rather than being one unlucky grouping away from breaking.
    function _oneInputBasket(
        RealmAnyPairsDividendTrackerAutoBasket.InputBasket memory one,
        MultiLaunchParams calldata p,
        uint256 i
    ) private pure {
        RealmAnyPairsDividendTrackerAutoBasket.Leg[] calldata b = p.rewardBaskets[i];
        one.input = p.pairs[i].quoteToken;
        RealmAnyPairsDividendTrackerAutoBasket.Leg[] memory legs =
            new RealmAnyPairsDividendTrackerAutoBasket.Leg[](b.length);
        for (uint256 j; j < b.length; ++j) {
            legs[j] = RealmAnyPairsDividendTrackerAutoBasket.Leg(b[j].asset, b[j].bps);
        }
        one.legs = legs;
        // Either absent for every pair, or present for every pair (checked by the caller).
        if (i < p.basketRoutes.length) one.routes = p.basketRoutes[i];
    }

    function _seedMultiPool(
        address token, address creator, MultiLaunchParams calldata p, uint256 pairIndex, uint256 poolSupply,
        address tracker, bool rewards, uint256 devEthWei, DevBuySplit memory split
    ) internal {
        PairSpec calldata pair = p.pairs[pairIndex];
        address quote = pair.quoteToken;
        if (token == quote) revert TokenEqualsQuote();
        _requireSaneParty(creator);

        bool coinIsC0 = token < quote;
        PoolKey memory key = _keyForPair(token, quote, coinIsC0, address(pairTaxHook));

        // Re-checked here (already validated up front) because this is the value that reaches `initialize`.
        LaunchGeometry memory g = _launchGeometry(token, quote, pair.launchTick, poolSupply);
        int24 launchTick_ = g.poolTick;
        int24 tickLower = g.tickLower;
        int24 tickUpper = g.tickUpper;

        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(launchTick_));

        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory cp = RealmAnyPairsTaxHookPairImmutable.ConfigParams({
            creator: creator, buyBps: p.buyBps, sellBps: p.sellBps,
            recipients: p.recipients, splitBps: p.splitBps,
            rewardsTracker: rewards ? tracker : address(0), rewardsBps: rewards ? p.rewardsBps : 0,
            autoSend: p.autoSend, autoThreshold: p.autoThreshold,
            maxBuyBps: p.maxBuyBps, launchTaxBps: p.launchTaxBps,
            launchTaxSecs: p.launchTaxSecs, tradingDelaySecs: p.tradingDelaySecs,
            buybackBps: p.buybackBps, lpBps: p.lpBps,
            whitelist: p.whitelist
        });
        pairTaxHook.configurePool(key, cp);

        (
            , , , , , ,
            bool storedQuoteIsC0,
            address storedQuote,
            , ,
        ) = pairTaxHook.config(key.toId());
        if (storedQuote != quote || storedQuoteIsC0 != !coinIsC0) revert QuoteOrientationMismatch();

        // Same native/ERC20 dev-buy split as {_finishLaunch}: native needs no zap and no pre-transfer,
        // because `devEthWei` already IS this pool's quote.
        uint256 devBuyQuote = 0;
        if (devEthWei > 0) {
            if (quote == address(0)) {
                devBuyQuote = devEthWei;
            } else {
                if (pair.ethQuotePath.length < 43) revert BadDevBuyPath();
                devBuyQuote = _zapEthToQuote(quote, devEthWei, pair.ethQuotePath, p.minQuoteOutFirstPair);
                uint256 lockerBefore = IERC20(quote).balanceOf(address(pairLpLocker));
                IERC20(quote).safeTransfer(address(pairLpLocker), devBuyQuote);
                devBuyQuote = IERC20(quote).balanceOf(address(pairLpLocker)) - lockerBefore;
                // The ETH is already spent; if nothing arrived, unwind. Only pool 0 carries a dev buy.
                if (devBuyQuote == 0) revert DevBuyProducedNothing();
            }
        }

        (uint160 sqrtNow,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (sqrtNow != TickMath.getSqrtPriceAtTick(launchTick_)) revert LaunchPriceMoved();

        // Computed and bounds-checked in {_launchGeometry}, before any state was written.
        uint128 liquidity = g.liquidity;

        bool ok = IERC20(token).transfer(address(pairLpLocker), poolSupply);
        if (!ok) revert SeedTransferFailed();
        // How much of the offered quote the dev buy actually spent, reported in the settlement event.
        uint256 quoteSpent = _lockerLaunch(
            quote == address(0) ? devBuyQuote : 0, key, liquidity, tickLower, tickUpper, creator, !coinIsC0, devBuyQuote, poolSupply, split
        );

        emit PoolSeeded(token, quote, PoolId.unwrap(key.toId()), pair.weightBps, launchTick_, poolSupply);
        // Pool 0 also emits the frozen headline and settlement events, branched on the quote as in {_finishLaunch}.
        // Only pool 0 can carry a dev buy.
        if (pairIndex == 0) {
            if (quote == address(0)) {
                emit TaxLaunch(token, creator, p.totalSupply, launchTick_, devEthWei);
                emit DevBuySettled(token, devEthWei, quoteSpent);
            } else {
                emit PairLaunch(token, creator, quote, p.totalSupply, launchTick_, devEthWei);
                emit PairDevBuySettled(token, quote, devEthWei, quoteSpent);
            }
        }
    }

    // ── DEV-BUY QUOTE HELPERS (view-only) ─────────────────────────────────────────────────────────────────────────

    /// @dev The seeded pool, as the launch transaction's dev buy will find it.
    function _devBuySeed(address token, address quote, uint256 totalSupply, int24 launchTick)
        internal
        pure
        returns (RealmAnyPairsDevBuyQuote.Seed memory s)
    {
        if (token == quote) revert TokenEqualsQuote();
        LaunchGeometry memory g = _launchGeometry(token, quote, launchTick, totalSupply);
        s = RealmAnyPairsDevBuyQuote.Seed({
            zeroForOne: !g.coinIsC0,
            tick: g.poolTick,
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(g.poolTick),
            tickLower: g.tickLower,
            tickUpper: g.tickUpper,
            liquidity: g.liquidity,
            tickSpacing: TICK_SPACING,
            lpFee: LP_FEE
        });
    }

    /// @notice What a launch's dev buy of `quoteIn` QUOTE delivers, before the pool exists.
    /// @param token the coin's address; its sort order against `quote` changes the liquidity formula and swap
    /// direction. Native launches pass `quote = address(0)`.
    /// @param totalSupply the SEEDED supply: the coin's total supply minus any vesting-vault amounts.
    /// @param quoteIn quote reaching the pool: after the ETH->quote zap, and after any transfer fee.
    /// @return tokensOut coin delivered to the creator
    /// @return quoteSpent quote actually charged (the hook's fee plus what the pool consumed); any remainder of
    /// `quoteIn` would be queued as a refund.
    /// @dev Exact: uses the hook's {RealmAnyPairsTaxHookPairImmutable.launchBuyFee} and {RealmAnyPairsDevBuyQuote},
    /// a port of v4's swap step loop. Reverts wherever the launch would.
    function quoteDevBuy(
        address token, address quote, uint256 totalSupply, int24 launchTick,
        uint16 buyBps, uint16 launchTaxBps, uint16 launchTaxSecs, uint256 quoteIn
    ) external view returns (uint256 tokensOut, uint256 quoteSpent) {
        if (quoteIn > uint256(uint128(type(int128).max))) revert DevBuyTooLarge();
        RealmAnyPairsDevBuyQuote.Seed memory s = _devBuySeed(token, quote, totalSupply, launchTick);
        (uint256 fee, uint256 ceilBps) = pairTaxHook.launchBuyFee(buyBps, launchTaxBps, launchTaxSecs, quoteIn);
        uint256 consumed;
        (tokensOut, consumed) = RealmAnyPairsDevBuyQuote.simulate(s, quoteIn - fee);
        // afterSwap's partial-fill guard: `taken * BPS > (filled + taken) * ceil` reverts the real swap.
        if (fee != 0 && fee * BPS_DENOM > (consumed + fee) * ceilBps) revert RealmAnyPairsTaxHookPairImmutable.FillTooSmallForTax();
        quoteSpent = fee + consumed;
    }

    /// @notice The most quote a dev buy can spend with every unit consumed (no refund) and the launch still
    /// representable.
    /// @dev The seeded range runs to the usable price bound, so fully exhausting it needs on the order of 1e40 wei --
    /// far past v4's int128 delta. For any realistic launch this therefore returns `type(int128).max`; the capacity
    /// branch exists so the function stays correct for any geometry, not because it is expected to bind.
    function maxDevBuy(
        address token, address quote, uint256 totalSupply, int24 launchTick,
        uint16 buyBps, uint16 launchTaxBps, uint16 launchTaxSecs
    ) external view returns (uint256 maxQuoteIn) {
        RealmAnyPairsDevBuyQuote.Seed memory s = _devBuySeed(token, quote, totalSupply, launchTick);
        uint256 ceiling = uint256(uint128(type(int128).max));
        (, uint256 capacity) = RealmAnyPairsDevBuyQuote.simulate(s, ceiling);
        if (capacity == ceiling) {
            pairTaxHook.launchBuyFee(buyBps, launchTaxBps, launchTaxSecs, 0); // validate the parameters regardless
            return ceiling;
        }
        // Largest q with q - fee(q) <= capacity. fee(1e6) is the rate in pips, which gives an estimate within a few
        // wei; the two loops settle it exactly against the hook's own fee.
        (uint256 pips,) = pairTaxHook.launchBuyFee(buyBps, launchTaxBps, launchTaxSecs, 1e6);
        uint256 q = capacity * 1e6 / (1e6 - pips);
        while (q > 0 && q - _launchFee(buyBps, launchTaxBps, launchTaxSecs, q) > capacity) --q;
        while (q < ceiling && (q + 1) - _launchFee(buyBps, launchTaxBps, launchTaxSecs, q + 1) <= capacity) ++q;
        maxQuoteIn = q;
    }

    function _launchFee(uint16 buyBps, uint16 launchTaxBps, uint16 launchTaxSecs, uint256 amount)
        private
        view
        returns (uint256 fee)
    {
        (fee,) = pairTaxHook.launchBuyFee(buyBps, launchTaxBps, launchTaxSecs, amount);
    }
    // ── BRANDED ADDRESS HELPERS ─────────────────────────────────────────────────────────────────────────

    /// @notice Every Realm AnyPairs token address ends in these two bytes (0x1110).
    function tokenSuffix() external pure returns (uint16) {
        return RealmAnyPairsV4TokenDeployer.TOKEN_SUFFIX;
    }

    /// @notice The init code hash a launch with these inputs deploys, computed through the SAME max-wallet derivation the
    /// launch uses. Mine the salt against this LAST, after every launch setting is final: name, symbol, supply, creator,
    /// max wallet and whitelist are all part of the init code, so changing any of them invalidates a mined salt.
    /// @param creator the coin's creator -- the launch caller for every entrypoint on this launcher.
    function tokenInitCodeHash(
        bool dividend, string calldata name, string calldata symbol, uint256 totalSupply, address creator,
        uint16 maxWalletBps, uint16 maxWalletMins, uint8 tradingDelaySecs, address[] calldata whitelist
    ) external view returns (bytes32) {
        (uint256 cap, uint32 secs) = _maxWalletOf(totalSupply, maxWalletBps, maxWalletMins, tradingDelaySecs);
        return dividend
            ? RealmAnyPairsV4TokenDeployer.initCodeHashDividend(name, symbol, totalSupply, address(this), creator, cap, secs, whitelist)
            : RealmAnyPairsV4TokenDeployer.initCodeHashPlain(name, symbol, totalSupply, address(this), creator, cap, secs, whitelist);
    }

    /// @notice The address a launch through this launcher by `caller`, with `userSalt`, deploys to. Must end in
    /// {tokenSuffix} or the launch reverts `InvalidTokenAddress`.
    function predictTokenAddress(address caller, bytes32 initCodeHash, bytes32 userSalt) external view returns (address) {
        return RealmAnyPairsV4TokenDeployer._create2Address(
            address(this), RealmAnyPairsV4TokenDeployer._saltFor(caller, userSalt), initCodeHash
        );
    }
    /// @notice The address of the linked {RealmAnyPairsV4TokenDeployer} this launcher deploys every coin through. Call its
    /// `initCodeHashPlain/initCodeHashDividend` and `predict*` functions directly to mine or verify an address.
    function tokenDeployer() external view returns (address) {
        return address(RealmAnyPairsV4TokenDeployer);
    }

    /// @notice Send a stray balance to `to`. OWNER OR ADMIN. A launcher holds nothing between transactions,
    /// so any balance here is stray. `nonReentrant` keeps it from running inside a launch.
    function rescue(address token, address to, uint256 amount) external onlyOwnerOrAdmin nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert RescueFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }
}
