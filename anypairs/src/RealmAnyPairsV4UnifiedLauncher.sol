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
import {RealmAnyPairsDividendTrackerEthBasket} from "./RealmAnyPairsDividendTrackerEthBasket.sol";
import {RealmAnyPairsV4MultiPairTrackerDeployer} from "./RealmAnyPairsV4MultiPairTrackerDeployer.sol";
import {RealmAnyPairsDividendTrackerQuote} from "./RealmAnyPairsDividendTrackerQuote.sol";
import {RealmAnyPairsDividendTrackerBasket} from "./RealmAnyPairsDividendTrackerBasket.sol";
import {RealmAnyPairsDividendTrackerMultiBasket} from "./RealmAnyPairsDividendTrackerMultiBasket.sol";
import {RealmAnyPairsDividendTrackerAutoBasket} from "./RealmAnyPairsDividendTrackerAutoBasket.sol";

/// @notice The subset of {RealmAnyPairsTokenDividend} the launcher calls after deploying it through
/// {RealmAnyPairsV4TokenDeployer} (which returns a plain `address`).
interface IDividendTokenInit {
    function initTracker(address tracker) external;
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
    uint24 public constant LP_FEE = 3000; // 0.30%; compounded into locked LP by the locker
    int24 public constant TICK_SPACING = 200;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant REF_NAME_GAS = 200_000;
    uint256 internal constant BPS_DENOM = 10_000;

    /// @dev Low 14 bits of a V4 hook address are its permission flags; the hook must carry exactly this set
    /// (beforeInitialize / beforeSwap / afterSwap / both returnDelta bits).
    uint160 internal constant HOOK_FLAG_MASK = 0x3FFF;
    uint160 internal constant HOOK_FLAGS = 0x20CC;

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

    /// @notice The Uniswap V3 factory, handed to basket trackers so they can discover swap routes.
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
    /// @dev Must equal {RealmAnyPairsDividendTrackerMultiBasket.MAX_TOTAL_LEGS}. Mirrored by hand because the
    /// tracker does not exist yet when this check runs.
    uint256 internal constant MAX_TOTAL_LEGS = 60;

    /// @notice Ceiling on the legs a SINGLE denomination's basket may hold.
    /// @dev Must equal {RealmAnyPairsDividendTrackerMultiBasket.MAX_LEGS}; mirrored for the same reason as {MAX_TOTAL_LEGS}.
    uint256 internal constant MAX_LEGS_PER_BASKET = 10;

    // ─────────────────────────── events ───────────────────────────
    /// @dev SIGNATURE IS FROZEN: indexers match launches by topic0 across launcher addresses. Do NOT change
    /// field order/types.
    event TaxLaunch(address indexed token, address indexed creator, uint256 supply, int24 launchTick, uint256 devBuyEth);
    event DevBuySettled(address indexed token, uint256 offered, uint256 spent);
    event RewardsLaunch(address indexed token, address indexed tracker, uint16 rewardsBps);
    /// @notice A referrer was supplied but naming it failed. The launch still succeeds.
    event ReferralNamingFailed(address indexed token, address indexed referrer);
    /// @notice The hook's one-shot `markReferred` snapshot failed, so this pool's platform cut is never shared
    /// with the referrer.
    event PoolReferralMarkFailed(address indexed token, address indexed referrer);
    /// @notice Multi-pair variant of {PoolReferralMarkFailed}, identifying the pool.
    event PoolReferralMarkFailedForPool(
        address indexed token, address indexed referrer, bytes32 indexed poolId, uint256 pairIndex
    );

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
        RealmAnyPairsDividendTrackerEthBasket.Leg[] basket;
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
        address referrer;
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
        bytes ethQuotePath; uint256 minQuoteOut; address referrer;
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
        bytes ethQuotePath; uint256 minQuoteOut; address referrer;
        bytes32 salt;
        bool autoSend;
        uint80 autoThreshold;
        uint16 maxBuyBps; uint16 launchTaxBps; uint16 launchTaxSecs; uint8 tradingDelaySecs; uint16 buybackBps; uint16 lpBps;
        RealmAnyPairsDividendTrackerBasket.Leg[] basket;
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
        address referrer;
        bytes32 salt;
        bool autoSend;
        uint80 autoThreshold;
        uint16 maxBuyBps; uint16 launchTaxBps; uint16 launchTaxSecs; uint8 tradingDelaySecs; uint16 buybackBps; uint16 lpBps;
        uint16 maxWalletBps; uint16 maxWalletMins;
        RealmAnyPairsDividendTrackerMultiBasket.Leg[][] rewardBaskets;
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
        if (address(RealmAnyPairsV4TokenDeployer).code.length == 0 || address(RealmAnyPairsV4PairTrackerDeployer).code.length == 0
            || address(RealmAnyPairsV4MultiPairTrackerDeployer).code.length == 0) revert DeployerLibraryMissing();
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
    function setAdmin(address admin_) external onlyOwnerOrAdmin {
        if (admin_ == address(this)) revert SelfAddress();
        admin = admin_;
        emit AdminSet(admin_);
    }

    function _requireRenounceReady() internal view override {
        if (!pairTaxHook.isLauncher(address(this))) revert LauncherNotAllowlisted();
        if (!pairLpLocker.isLauncher(address(this))) revert LauncherNotAllowlisted();
        // After renounce neither allowlist is repairable from here, and the admin is the only key left that can
        // change `baseTokenURI` and the rest of the config.
        if (admin == address(0)) revert AdminZero();
    }

    function setPairTaxHook(RealmAnyPairsTaxHookPairImmutable newHook) external onlyOwnerOrAdmin {
        if (address(newHook) == address(0)) revert ZeroAddress();
        if (uint160(address(newHook)) & HOOK_FLAG_MASK != HOOK_FLAGS) revert BadHookFlags();
        if (!newHook.isLauncher(address(this))) revert LauncherNotAllowlisted();
        emit TaxHookSet(address(pairTaxHook), address(newHook));
        pairTaxHook = newHook;
    }

    function setPairLpLocker(RealmAnyPairsV4PairLpLockerImmutable newLocker) external onlyOwnerOrAdmin {
        if (address(newLocker) == address(0)) revert ZeroAddress();
        if (!newLocker.isLauncher(address(this))) revert LauncherNotAllowlisted();
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
    /// @dev Capped at 25, matching {RealmAnyPairsDividendTrackerMultiBasket.ABSOLUTE_MAX_DENOMINATIONS}, so this gate
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
        return _launch(p, address(0));
    }

    function launchWithMeta(LaunchParams calldata p, Meta calldata meta) external payable nonReentrant returns (address token) {
        token = _launch(p, address(0));
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }

    function launchRef(LaunchParams calldata p, address referrer) external payable nonReentrant returns (address token) {
        token = _launch(p, referrer);
    }

    function launchWithMetaRef(LaunchParams calldata p, Meta calldata meta, address referrer) external payable nonReentrant returns (address token) {
        token = _launch(p, referrer);
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }

    function _launch(LaunchParams calldata p, address referrer) internal returns (address token) {
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
        _finishLaunch(token, address(0), p.totalSupply, cp, msg.data[:0], 0, referrer, p.launchTick, _devBuySplit(p.devBuyRecipients, p.devBuyBps));
    }

    // ─────────────────────────── ETH-native rewards launch ─────────────────────────────────────────────

    function launchRewards(RewardsLaunchParams calldata p) external payable nonReentrant returns (address token, address tracker) {
        return _launchRewards(p, address(0));
    }

    function launchRewardsWithMeta(RewardsLaunchParams calldata p, Meta calldata meta) external payable nonReentrant returns (address token, address tracker) {
        (token, tracker) = _launchRewards(p, address(0));
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }

    function launchRewardsRef(RewardsLaunchParams calldata p, address referrer) external payable nonReentrant returns (address token, address tracker) {
        (token, tracker) = _launchRewards(p, referrer);
    }

    function launchRewardsWithMetaRef(RewardsLaunchParams calldata p, Meta calldata meta, address referrer) external payable nonReentrant returns (address token, address tracker) {
        (token, tracker) = _launchRewards(p, referrer);
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }

    function _launchRewards(RewardsLaunchParams calldata p, address referrer) internal returns (address token, address tracker) {
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

        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory cp = p.tax;
        cp.creator = msg.sender;
        cp.rewardsTracker = tracker;
        _finishLaunch(token, address(0), p.totalSupply, cp, msg.data[:0], 0, referrer, p.launchTick, _devBuySplit(p.devBuyRecipients, p.devBuyBps));
        // AFTER the TaxLaunch/DevBuySettled pair {_finishLaunch} emits, preserving the exact event ORDER
        // an ETH rewards launch has always produced: TaxLaunch, DevBuySettled, RewardsLaunch.
        emit RewardsLaunch(token, tracker, cp.rewardsBps);
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
        return _launchNativeRewardsBasket(p, address(0));
    }

    function launchRewardsBasketWithMeta(RewardsBasketLaunchParams calldata p, Meta calldata meta) external payable nonReentrant returns (address token, address tracker) {
        (token, tracker) = _launchNativeRewardsBasket(p, address(0));
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }

    function launchRewardsBasketRef(RewardsBasketLaunchParams calldata p, address referrer) external payable nonReentrant returns (address token, address tracker) {
        (token, tracker) = _launchNativeRewardsBasket(p, referrer);
    }

    function launchRewardsBasketWithMetaRef(RewardsBasketLaunchParams calldata p, Meta calldata meta, address referrer) external payable nonReentrant returns (address token, address tracker) {
        (token, tracker) = _launchNativeRewardsBasket(p, referrer);
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }

    function _launchNativeRewardsBasket(RewardsBasketLaunchParams calldata p, address referrer) internal returns (address token, address tracker) {
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

        tracker = _deployEthBasketTracker(
            token, p.totalSupply, p.basket, _createVaults(token, p.vaults, p.totalSupply, p.maxWalletMins)
        );
        IDividendTokenInit(token).initTracker(tracker);

        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory cp = p.tax;
        cp.creator = msg.sender;
        cp.rewardsTracker = tracker;
        _finishLaunch(token, address(0), p.totalSupply, cp, msg.data[:0], 0, referrer, p.launchTick, _devBuySplit(p.devBuyRecipients, p.devBuyBps));
        emit RewardsLaunch(token, tracker, cp.rewardsBps);
    }

    /// @dev Builds a single WETH-input basket and deploys the auto-converting tracker. `swapRouter` is read at
    /// launch and frozen into the tracker.
    function _deployEthBasketTracker(
        address token, uint256 totalSupply, RealmAnyPairsDividendTrackerEthBasket.Leg[] calldata basket, address[] memory vaults
    ) internal returns (address) {
        // Native fees are wrapped to WETH and converted from there; a WETH leg is paid as WETH.
        RealmAnyPairsDividendTrackerAutoBasket.InputBasket[] memory ins = new RealmAnyPairsDividendTrackerAutoBasket.InputBasket[](1);
        ins[0].input = weth;
        ins[0].legs = new RealmAnyPairsDividendTrackerAutoBasket.Leg[](basket.length);
        for (uint256 i; i < basket.length; ++i) {
            ins[0].legs[i] = RealmAnyPairsDividendTrackerAutoBasket.Leg(basket[i].asset, basket[i].bps);
        }
        return _deployAutoTracker(token, totalSupply, ins, vaults);
    }

    /// @dev Every basket launch (pair, native, multi-pair) deploys {RealmAnyPairsDividendTrackerAutoBasket}.
    function _deployAutoTracker(
        address token, uint256 totalSupply, RealmAnyPairsDividendTrackerAutoBasket.InputBasket[] memory ins,
        address[] memory vaults
    ) internal returns (address) {
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
        _finishLaunch(token, p.pairToken, p.totalSupply, cp, p.ethQuotePath, p.minQuoteOut, p.referrer, p.launchTick, _devBuySplit(p.devBuyRecipients, p.devBuyBps));
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
        address[] memory ex = _trackerExcluded(_createVaults(token, p.vaults, p.totalSupply, p.maxWalletMins));
        tracker = RealmAnyPairsV4PairTrackerDeployer.deployQuoteTracker(RealmAnyPairsDividendTrackerQuote.Config({
            token: token, feeder: address(pairTaxHook),
            // The one field that makes a coin a reflections coin.
            quote: p.rewardsInCoin ? token : p.pairToken,
            poolManager: address(poolManager),
            minEligible: p.totalSupply / 1e4, excluded: ex
        }));
        IDividendTokenInit(token).initTracker(tracker);

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
        _finishLaunch(token, p.pairToken, p.totalSupply, cp, p.ethQuotePath, p.minQuoteOut, p.referrer, p.launchTick, _devBuySplit(p.devBuyRecipients, p.devBuyBps));
        // Emitted after {_finishLaunch} to keep the event order TaxLaunch, DevBuySettled, RewardsLaunch.
        emit RewardsLaunch(token, tracker, p.rewardsBps);
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
        tracker = _deployBasketTracker(token, p.pairToken, p.totalSupply, p.basket, vaults);
        IDividendTokenInit(token).initTracker(tracker);

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
        _finishLaunch(token, p.pairToken, p.totalSupply, cp, p.ethQuotePath, p.minQuoteOut, p.referrer, p.launchTick, _devBuySplit(p.devBuyRecipients, p.devBuyBps));
        // Emitted after {_finishLaunch} to keep the event order TaxLaunch, DevBuySettled, RewardsLaunch.
        emit RewardsLaunch(token, tracker, p.rewardsBps);
    }

    /// @dev Builds a single `quote`-input basket and deploys the auto-converting tracker. In its own frame to
    /// avoid stack too deep in the launch function.
    function _deployBasketTracker(
        address token, address quote, uint256 totalSupply, RealmAnyPairsDividendTrackerBasket.Leg[] calldata basket,
        address[] memory vaults
    ) internal returns (address) {
        RealmAnyPairsDividendTrackerAutoBasket.InputBasket[] memory ins = new RealmAnyPairsDividendTrackerAutoBasket.InputBasket[](1);
        ins[0].input = quote;
        ins[0].legs = new RealmAnyPairsDividendTrackerAutoBasket.Leg[](basket.length);
        for (uint256 i; i < basket.length; ++i) {
            ins[0].legs[i] = RealmAnyPairsDividendTrackerAutoBasket.Leg(basket[i].asset, basket[i].bps);
        }
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

    function _finishLaunch(
        address token, address quote, uint256 totalSupply,
        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory cp, bytes calldata ethQuotePath, uint256 minQuoteOut, address referrer,
        int24 launchTick, DevBuySplit memory split
    ) internal {
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
        LaunchGeometry memory g = _launchGeometry(token, quote, launchTick, seedSupply);
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

        // Referral screening lives in the hook's {markReferred}; the locker, WETH and router are screened here because
        // the hook cannot see them. A failed mark must never brick a launch.
        if (
            referrer != address(0) && referrer != address(pairLpLocker)
            && referrer != weth && referrer != swapRouter
        ) {
            try pairTaxHook.markReferred{gas: REF_NAME_GAS}(key, referrer) {} catch {}
        }

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
                devBuyQuote = _zapEthToQuote(quote, msg.value, ethQuotePath, minQuoteOut);
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
            emit TaxLaunch(token, cp.creator, totalSupply, launchTick_, msg.value);
            emit DevBuySettled(token, msg.value, quoteSpent);
        } else {
            emit PairLaunch(token, cp.creator, quote, totalSupply, launchTick_, msg.value);
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
            tracker = _deployMultiTracker(token, p, _createVaults(token, p.vaults, p.totalSupply, p.maxWalletMins));
            IDividendTokenInit(token).initTracker(tracker);
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
        bool referred;
        // Split what is left after the vaults, not the whole supply.
        uint256 seedSupply = IERC20(token).balanceOf(address(this));
        for (uint256 i; i < pairCount; ++i) {
            uint256 poolSupply = i + 1 == pairCount ? seedSupply - distributedSupply : (seedSupply * p.pairs[i].weightBps) / 10_000;
            distributedSupply += poolSupply;
            referred = _seedMultiPool(token, creator, p, i, poolSupply, tracker, rewards, i == 0 ? msg.value : 0, referred, _devBuySplit(p.devBuyRecipients, p.devBuyBps));
        }

        // Announced after the loop, so it follows pool 0's headline event that creates the coin downstream.
        // Guarded: a non-rewards launch has no tracker and must not announce a zero one.
        if (rewards) emit RewardsLaunch(token, tracker, p.rewardsBps);
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
        RealmAnyPairsDividendTrackerAutoBasket.InputBasket[] memory ins = new RealmAnyPairsDividendTrackerAutoBasket.InputBasket[](pairCount);
        for (uint256 i; i < pairCount; ++i) {
            RealmAnyPairsDividendTrackerMultiBasket.Leg[] calldata b = p.rewardBaskets[i];
            ins[i].input = p.pairs[i].quoteToken;
            ins[i].legs = new RealmAnyPairsDividendTrackerAutoBasket.Leg[](b.length);
            for (uint256 j; j < b.length; ++j) {
                ins[i].legs[j] = RealmAnyPairsDividendTrackerAutoBasket.Leg(b[j].asset, b[j].bps);
            }
        }
        tracker = _deployAutoTracker(token, p.totalSupply, ins, vaults);
    }

    /// @param referredIn whether the referrer passed screening, decided once at pool 0.
    /// @return referredOk the same flag, for the next pool in the loop.
    function _seedMultiPool(
        address token, address creator, MultiLaunchParams calldata p, uint256 pairIndex, uint256 poolSupply,
        address tracker, bool rewards, uint256 devEthWei, bool referredIn, DevBuySplit memory split
    ) internal returns (bool referredOk) {
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

        // Screening runs once at pool 0; the hook's referral snapshot is per pool, so every pool is marked.
        referredOk = pairIndex == 0 ? _tryNameReferrerMulti(token, p, tracker, creator) : referredIn;
        // A failed mark must not revert the launch.
        if (referredOk && p.referrer != address(0)) {
            try pairTaxHook.markReferred{gas: REF_NAME_GAS}(key, p.referrer) {} catch {}
        }

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

    /// @return named true if the referrer passed this launch's screening.
    /// @dev Refuses any of this launch's quote tokens (a token can never claim a referral cut), plus the locker,
    /// WETH and router. All other screening lives in the hook's {markReferred}.
    function _tryNameReferrerMulti(address, MultiLaunchParams calldata p, address, address)
        internal view returns (bool named)
    {
        address referrer = p.referrer;
        if (referrer == address(0)) return false;
        // Launcher-side addresses the hook cannot see.
        if (referrer == address(pairLpLocker) || referrer == weth || referrer == swapRouter) return false;
        for (uint256 i; i < p.pairs.length; ++i) {
            if (referrer == p.pairs[i].quoteToken) return false;
        }
        named = true;
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
