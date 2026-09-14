// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Test harness only: exercises the pair hook, pair LP locker and pricing libraries. Not deployed.

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
import {RealmAnyPairsV4TokenDeployer} from "./RealmAnyPairsV4TokenDeployer.sol";
import {RealmAnyPairsV4PairTrackerDeployer} from "./RealmAnyPairsV4PairTrackerDeployer.sol";
import {RealmAnyPairsV4PairLpLockerImmutable} from "./RealmAnyPairsV4PairLpLockerImmutable.sol";
import {RealmAnyPairsDividendTrackerQuote} from "./RealmAnyPairsDividendTrackerQuote.sol";
import {RealmAnyPairsDividendTrackerBasket} from "./RealmAnyPairsDividendTrackerBasket.sol";

/// @dev Minimal reader for the coin duck-type the pair hook uses. Consulted through try/catch so a quote
/// that does not implement it simply fails the check.
interface ICoinLauncher {
    function launcher() external view returns (address);
}

interface IDividendTokenInit {
    function initTracker(address tracker) external;
}

interface ISwapRouter02 {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH9 {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

/**
 * @title RealmAnyPairsV4PairLauncherImmutable
 * @notice Non-upgradeable launcher for quote-paired V4 coins (plain, quote-rewards and basket-rewards).
 * @dev Test harness, not deployed; production launches go through {RealmAnyPairsV4UnifiedLauncher}. Its guards
 *      are kept in parity with that launcher so tests against this contract reflect production behaviour.
 *      This launcher has no native-ETH pair path, so a zero quote is rejected.
 */
contract RealmAnyPairsV4PairLauncherImmutable is RealmAnyPairsImmutableBase {
    using SafeERC20 for IERC20;

    uint256 private constant Q96 = 0x1000000000000000000000000;
    uint24 public constant LP_FEE = 3000;
    int24 public constant TICK_SPACING = 200;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant REF_NAME_GAS = 200_000;

    IPoolManager public immutable poolManager;
    /// @notice Hook used for FUTURE launches; changing it does not affect existing pools.
    RealmAnyPairsTaxHookPairImmutable public taxHook;

    uint160 internal constant HOOK_FLAG_MASK = 0x3FFF;
    uint160 internal constant HOOK_FLAGS = 0x20CC;
    address public immutable weth;
    /// @notice The {RealmAnyPairsCreatorVault} implementation every launch's vaults are minimal clones of.
    address public immutable vaultImplementation;
    /// @notice Router for the ETH->quote dev-buy zap. Mutable so a deprecated router can be replaced.
    address public swapRouter;

    /// @notice The chain's Uniswap V3 factory, handed to basket trackers to derive each leg's swap route.
    /// @dev Immutable with no setter: it names where pools live, never which tokens are acceptable.
    address public immutable v3Factory;
    RealmAnyPairsV4PairLpLockerImmutable public lpLocker;

    string public baseTokenURI;

    /// @notice Secondary config key that survives {renounceOwnership}.
    /// @dev Exists so `baseTokenURI` (read by every deployed token forever) stays settable after renounce.
    /// Appended at the end of mutable storage.
    address public admin;


    // No quote curation and no derived pricing: any quote is accepted subject to {_requireSaneQuote}, and the
    // caller supplies the opening tick (see {_checkedTick}).

    /// @dev Signature is frozen: indexers match it by topic0, so do not add fields. `devBuyEth` is the ETH
    /// offered; see {PairDevBuySettled} for what the buy actually consumed.
    event PairLaunch(address indexed token, address indexed creator, address indexed quote, uint256 supply, int24 launchTick, uint256 devBuyEth);

    /// @notice What the dev buy actually consumed, emitted alongside {PairLaunch}.
    /// @param ethIn the ETH the creator sent, which is zapped into the quote first.
    /// @param quoteSpent what the buy really took, in QUOTE units.
    event PairDevBuySettled(address indexed token, address indexed quote, uint256 ethIn, uint256 quoteSpent);
    event V4TokenMeta(address indexed token, address indexed creator, string image, string banner, string description, string website, string twitter, string telegram);
    event BaseTokenURISet(string base);
    /// @dev Emitted by {setAdmin}, including the disabling `address(0)` case.
    event AdminSet(address indexed admin);
    event TaxHookSet(address indexed from, address indexed to);
    event LpLockerSet(address indexed from, address indexed to);
    event SwapRouterSet(address indexed from, address indexed to);

    error SupplyZero();
    error SupplyTooLarge();
    error SupplyTooSmallForRewards();
    /// @dev The caller-supplied launch tick is not a multiple of {TICK_SPACING} or not strictly inside the
    /// usable band.
    error BadLaunchTick();
    error BadLiquidity();
    error SeedTransferFailed();
    /// @dev The pool price moved between `initialize` and the seed. Retryable, unlike {BadLiquidity}.
    error LaunchPriceMoved();
    uint256 internal constant BPS_DENOM = 10_000;

    error ZeroAddress();
    error TokenEqualsQuote();
    error BadDevBuyPath();
    /// @dev A funded dev buy delivered zero quote to the locker (e.g. a 100% fee-on-transfer quote).
    error DevBuyProducedNothing();
    error QuoteSupplyTooLarge();
    error QuoteImpersonatesCoin();
    error QuoteIsWeth();
    /// @dev The creator is this launcher, the hook or the PoolManager, where pushed value would be unrecoverable.
    error SelfParty();
    /// @dev The hook's stored orientation for the pool disagrees with the launcher's address-ordering one.
    error QuoteOrientationMismatch();
    error DeployerLibraryMissing();
    error BadHookFlags();
    error LauncherNotAllowlisted();
    /// @dev A config setter was called by neither the owner nor the admin.
    error NotOwnerOrAdmin();
    /// @dev Renounce attempted while `admin == address(0)`. See {_requireRenounceReady}.
    error AdminZero();
    /// @dev {setAdmin}(address(this)): this contract can never act as its own admin.
    error SelfAddress();
    /// @notice The native transfer of a rescue failed.
    error RescueFailed();
    /// @notice `amount` of `token` (address(0) = native ETH) that no one was owed was sent to `to`.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // Minimum total supply for rewards launches: keeps the tracker's dust floor (totalSupply / 1e4) meaningful.
    uint256 internal constant MIN_REWARDS_TOTAL_SUPPLY = 1e9;

    // Cap on a quote's raw total supply. A single tracker book can never exceed the quote's supply, so this
    // bounds the magnified-share arithmetic in quote/basket trackers the same way ETH's real supply does.
    // At 18 decimals it admits up to 120M whole tokens. Checked per launch in {_requireSaneQuote}.
    uint256 internal constant MAX_QUOTE_TOTAL_SUPPLY = 1.2e26;

    struct Meta { string image; string banner; string description; string website; string twitter; string telegram; }

    struct LaunchParams {
        /// @dev Creator vesting vaults: up to 5, together <= 20% of supply. Empty = none. See {VaultParams}.
        VaultParams[] vaults;
        /// @dev Split the dev buy's coin across up to 10 wallets (bps summing to 10,000; the last takes the
        /// rounding remainder). Leave both empty to send it all to the creator. Validated by the locker.
        address[] devBuyRecipients;
        uint16[] devBuyBps;
        /// @dev Anti-sniper whitelist (<= 50): skips max buy (hook, on tx.origin) and max wallet (token).
        /// Never skips the trading delay or the launch tax. Part of the token's init code, so part of its address.
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
        /// @dev Required CREATE2 salt. The coin deploys at a caller-bound address that must end in 0x1110 or the
        /// launch reverts `InvalidTokenAddress`. Mine it last with {tokenInitCodeHash} + {predictTokenAddress}:
        /// every constructor argument (name, symbol, supply, creator, max wallet, whitelist) is part of the hash.
        bytes32 salt;
        bool autoSend;          // true = hook PUSHES the creator share to its recipients in-swap
        /// @dev Auto-send threshold in the quote's own units; ZERO = use the default.
        uint80 autoThreshold;
        /// @dev Optional launch guards; 0 = OFF. See RealmAnyPairsTaxHookPairImmutable for semantics.
        uint16 maxBuyBps; uint16 launchTaxBps; uint16 launchTaxSecs; uint8 tradingDelaySecs; uint16 buybackBps; uint16 lpBps;
        /// @dev Optional max wallet: no EOA may hold more than `maxWalletBps` of supply until `maxWalletMins`
        /// minutes after launch. Both zero = off. Enforced by the token; contracts are exempt.
        uint16 maxWalletBps;
        uint16 maxWalletMins;
        /// @dev Opening price as QUOTE PER COIN on raw units (`price = 1.0001^launchTick`); higher is always a
        /// more expensive coin. The launcher negates it when the coin sorts as currency1, so callers never
        /// need to know the pool orientation.
        int24 launchTick;
    }

    /// @notice Floor on an opt-in max wallet, in bps of supply; a tiny cap would make the coin unsellable.
    uint16 public constant MIN_MAX_WALLET_BPS = 10;      // 0.1% of supply

    /// @notice Ceiling on how long a max wallet may run, so a "temporary" cap cannot be permanent.
    uint16 public constant MAX_MAX_WALLET_MINS = 10080;  // 7 days

    error BadMaxWallet();

    /// @notice A coin launched with an opt-in max wallet. Emitted only when one is set.
    /// @dev Separate event because {PairLaunch} is frozen for indexers.
    event MaxWalletSet(address indexed token, uint256 maxWallet, uint40 maxWalletUntil);

    /// @dev Resolve the creator's (bps, minutes) into an absolute token cap and a duration. Both or neither.
    /// Returns a duration, not a deadline: constructor args feed the CREATE2 hash, so a timestamp would
    /// break mined salts.
    /// @param delaySecs the pool's `tradingDelaySecs`; the cap window must outlive it.
    function _maxWalletOf(uint256 totalSupply_, uint16 bps, uint16 mins, uint8 delaySecs)
        internal
        pure
        returns (uint256 cap, uint32 secs)
    {
        if (bps == 0 && mins == 0) return (0, 0);
        if (bps < MIN_MAX_WALLET_BPS || bps > BPS_DENOM) revert BadMaxWallet();
        if (mins == 0 || mins > MAX_MAX_WALLET_MINS) revert BadMaxWallet();
        cap = (totalSupply_ * bps) / BPS_DENOM;
        // A zero cap would revert every transfer.
        if (cap == 0) revert BadMaxWallet();
        secs = uint32(mins) * 60;
        // The cap clock starts at launch but trading may open up to `tradingDelaySecs` later, so the cap must
        // last strictly longer than the delay.
        if (secs <= uint32(delaySecs)) revert BadMaxWallet();
    }

    constructor(
        IPoolManager pm,
        RealmAnyPairsTaxHookPairImmutable hook,
        address weth_,
        address router_,
        address v3Factory_,
        RealmAnyPairsV4PairLpLockerImmutable lpLocker_,
        string memory base,
        address owner_
    ) RealmAnyPairsImmutableBase(owner_) {
        if (address(lpLocker_) == address(0)) revert ZeroAddress();
        if (address(pm) == address(0) || address(hook) == address(0)
            || weth_ == address(0) || router_ == address(0) || v3Factory_ == address(0)) revert ZeroAddress();
        // Token/tracker creation runs through linked libraries; fail at deploy if either has no code,
        // rather than failing every launch later.
        if (address(RealmAnyPairsV4TokenDeployer).code.length == 0
            || address(RealmAnyPairsV4PairTrackerDeployer).code.length == 0) revert DeployerLibraryMissing();
        // In V4 the low 14 bits of a hook's address are its permission flags. The hook's launcher allowlist
        // can only be checked later, in {_requireRenounceReady}.
        if (uint160(address(hook)) & HOOK_FLAG_MASK != HOOK_FLAGS) revert BadHookFlags();
        poolManager = pm;
        v3Factory = v3Factory_;
        taxHook = hook;
        weth = weth_;
        swapRouter = router_;
        lpLocker = lpLocker_;
        baseTokenURI = base;
        // The deployer is the first admin, so a deploy that never calls {setAdmin} is still renounce-ready.
        vaultImplementation = address(new RealmAnyPairsCreatorVault());
        admin = owner_;
    }

    // ─────────────────────────── admin ───────────────────────────

    /// @notice Point FUTURE launches at a different hook. It must have valid flags and allowlist this launcher.
    function setTaxHook(RealmAnyPairsTaxHookPairImmutable newHook) external onlyOwnerOrAdmin {
        if (address(newHook) == address(0)) revert ZeroAddress();
        if (uint160(address(newHook)) & HOOK_FLAG_MASK != HOOK_FLAGS) revert BadHookFlags();
        if (!newHook.isLauncher(address(this))) revert LauncherNotAllowlisted();
        emit TaxHookSet(address(taxHook), address(newHook));
        taxHook = newHook;
    }

    /// @notice Point FUTURE launches at a different LP locker. Existing locked LP stays where it is.
    function setLpLocker(RealmAnyPairsV4PairLpLockerImmutable newLocker) external onlyOwnerOrAdmin {
        if (address(newLocker) == address(0)) revert ZeroAddress();
        if (!newLocker.isLauncher(address(this))) revert LauncherNotAllowlisted();
        emit LpLockerSet(address(lpLocker), address(newLocker));
        lpLocker = newLocker;
    }

    /// @notice Repoint the dev-buy zap router.
    /// @dev Affects future launches only: basket trackers snapshot the router immutably at deploy.
    function setSwapRouter(address newRouter) external onlyOwnerOrAdmin {
        if (newRouter == address(0)) revert ZeroAddress();
        emit SwapRouterSet(swapRouter, newRouter);
        swapRouter = newRouter;
    }

    function setBaseTokenURI(string calldata base) external onlyOwnerOrAdmin { baseTokenURI = base; emit BaseTokenURISet(base); }

    /// @dev Arithmetic sanity checks on every quote (not a quality judgement): not WETH (collides with the
    /// dev-buy zap), supply within {MAX_QUOTE_TOTAL_SUPPLY} (tracker math), and not a coin from this launcher
    /// (would break the hook's orientation detection).
    function _requireSaneQuote(address quote) internal view {
        if (quote == weth) revert QuoteIsWeth();
        if (IERC20(quote).totalSupply() > MAX_QUOTE_TOTAL_SUPPLY) revert QuoteSupplyTooLarge();
        try ICoinLauncher(quote).launcher() returns (address l) {
            if (l == address(this)) revert QuoteImpersonatesCoin();
        } catch {}
    }

    /// @dev Rejects this launcher, the hook and the PoolManager as a party: a push to them succeeds but the
    /// value can never be retrieved.
    function _requireSaneParty(address party) internal view {
        if (party == address(this) || party == address(taxHook) || party == address(poolManager)) {
            revert SelfParty();
        }
    }

    /// @dev Owner or admin may use this contract's config surface. `admin == 0` disables the admin path and
    /// must not let `msg.sender == 0` through. Ownership transfer/renounce stay owner-only.
    modifier onlyOwnerOrAdmin() {
        if (msg.sender != owner && (msg.sender != admin || admin == address(0))) revert NotOwnerOrAdmin();
        _;
    }

    /// @notice Hand the surviving config key to `admin_`. Owner OR admin -- the admin may rotate itself.
    /// @dev `address(0)` is allowed (disables the admin path) and blocks renounce via {_requireRenounceReady}.
    function setAdmin(address admin_) external onlyOwnerOrAdmin {
        if (admin_ == address(this)) revert SelfAddress();
        admin = admin_;
        emit AdminSet(admin_);
    }

    /// @dev Blocks {renounceOwnership} until the launcher is usable: the hook and locker must allowlist it,
    /// and an admin must remain to manage config.
    function _requireRenounceReady() internal view override {
        if (!taxHook.isLauncher(address(this))) revert LauncherNotAllowlisted();
        if (!lpLocker.isLauncher(address(this))) revert LauncherNotAllowlisted();
        if (admin == address(0)) revert AdminZero();
    }

    // ─────────────────────────── launch ───────────────────────────

    function launchPair(LaunchParams calldata p) external payable nonReentrant returns (address token) {
        return _launch(p, msg.sender);
    }

    function launchPairWithMeta(LaunchParams calldata p, Meta calldata meta)
        external payable nonReentrant returns (address token)
    {
        token = _launch(p, msg.sender);
        emit V4TokenMeta(token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram);
    }

    function _minUsable() internal pure returns (int24) { return (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING; }
    function _maxUsable() internal pure returns (int24) { return (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING; }

    /// @notice Validate a caller-supplied launch tick; identical to {RealmAnyPairsV4UnifiedLauncher._checkedTick}.
    /// @dev Strictly inside (_minUsable, _maxUsable), so the single-sided seed range is non-empty in both
    /// orientations, and already aligned to {TICK_SPACING} (validated, never rounded). The range check runs
    /// before {_align} so an extreme tick reverts {BadLaunchTick} instead of an int24 underflow panic.
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

    struct RewardsLaunchParams {
        /// @dev Creator vesting vaults: up to 5, together <= 20% of supply. Empty = none. See {VaultParams}.
        VaultParams[] vaults;
        /// @dev Dev-buy split across up to 10 wallets. See {LaunchParams.devBuyRecipients}.
        address[] devBuyRecipients;
        uint16[] devBuyBps;
        /// @dev Anti-sniper whitelist (<= 50). See {LaunchParams.whitelist}.
        address[] whitelist;
        string name; string symbol; uint256 totalSupply; address pairToken;
        uint16 buyBps; uint16 sellBps; address[] recipients; uint16[] splitBps;
        uint16 rewardsBps;
        /// @dev Pay holder rewards in the coin itself instead of the pair token ("reflections").
        bool rewardsInCoin;
        bytes ethQuotePath; uint256 minQuoteOut; address referrer;
        bytes32 salt;   // see {LaunchParams.salt}
        bool autoSend;          // true = hook PUSHES the creator share to its recipients in-swap
        /// @dev Auto-send threshold in the quote's own units; ZERO = use the default.
        uint80 autoThreshold;
        /// @dev Optional launch guards; 0 = OFF. See RealmAnyPairsTaxHookPairImmutable for semantics.
        uint16 maxBuyBps; uint16 launchTaxBps; uint16 launchTaxSecs; uint8 tradingDelaySecs; uint16 buybackBps; uint16 lpBps;
        /// @dev Optional max wallet. See {LaunchParams.maxWalletBps}.
        uint16 maxWalletBps;
        uint16 maxWalletMins;
        /// @dev Opening price as quote per coin. See {LaunchParams.launchTick}.
        int24 launchTick;
    }

    /// @notice Launch a quote-paired coin that pays holders in the quote token.
    /// @return token the coin.
    /// @return tracker its dividend tracker.
    function launchPairRewards(RewardsLaunchParams calldata p)
        external
        payable
        nonReentrant
        returns (address token, address tracker)
    {
        return _launchRewards(p, msg.sender);
    }

    /// @notice Same as {launchPairRewards}, also emitting the coin's profile metadata in the launch transaction.
    function launchPairRewardsWithMeta(RewardsLaunchParams calldata p, Meta calldata meta)
        external
        payable
        nonReentrant
        returns (address token, address tracker)
    {
        (token, tracker) = _launchRewards(p, msg.sender);
        emit V4TokenMeta(
            token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram
        );
    }

    function _launchRewards(RewardsLaunchParams calldata p, address creator_)
        internal
        returns (address token, address tracker)
    {
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
            token: token, feeder: address(taxHook),
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
        _finishLaunch(token, p.pairToken, p.totalSupply, p.launchTick, cp, p.ethQuotePath, p.minQuoteOut, p.referrer, _devBuySplit(p.devBuyRecipients, p.devBuyBps));
    }

    struct RewardsBasketLaunchParams {
        /// @dev Creator vesting vaults: up to 5, together <= 20% of supply. Empty = none. See {VaultParams}.
        VaultParams[] vaults;
        /// @dev Dev-buy split across up to 10 wallets. See {LaunchParams.devBuyRecipients}.
        address[] devBuyRecipients;
        uint16[] devBuyBps;
        /// @dev Anti-sniper whitelist (<= 50). See {LaunchParams.whitelist}.
        address[] whitelist;
        string name; string symbol; uint256 totalSupply; address pairToken;
        uint16 buyBps; uint16 sellBps; address[] recipients; uint16[] splitBps;
        uint16 rewardsBps;
        /// @dev Reflections flag. Only the quote-tracker path honours it.
        bool rewardsInCoin;
        bytes ethQuotePath; uint256 minQuoteOut; address referrer;
        bytes32 salt;   // see {LaunchParams.salt}
        bool autoSend;          // true = hook PUSHES the creator share to its recipients in-swap
        /// @dev Auto-send threshold in the quote's own units; ZERO = use the default.
        uint80 autoThreshold;
        /// @dev Optional launch guards; 0 = OFF. See RealmAnyPairsTaxHookPairImmutable for semantics.
        uint16 maxBuyBps; uint16 launchTaxBps; uint16 launchTaxSecs; uint8 tradingDelaySecs; uint16 buybackBps; uint16 lpBps;
        RealmAnyPairsDividendTrackerBasket.Leg[] basket;
        /// @dev Optional max wallet. See {LaunchParams.maxWalletBps}.
        uint16 maxWalletBps;
        uint16 maxWalletMins;
        /// @dev Opening price as quote per coin. See {LaunchParams.launchTick}.
        int24 launchTick;
    }

    /// @notice Launch a quote-paired coin that pays holders a basket of assets bought with the quote.
    /// @return token the coin.
    /// @return tracker its basket tracker.
    function launchPairRewardsBasket(RewardsBasketLaunchParams calldata p)
        external
        payable
        nonReentrant
        returns (address token, address tracker)
    {
        return _launchRewardsBasket(p, msg.sender);
    }

    /// @notice Same, carrying the profile in the launch transaction. See {launchPairRewardsWithMeta}.
    function launchPairRewardsBasketWithMeta(RewardsBasketLaunchParams calldata p, Meta calldata meta)
        external
        payable
        nonReentrant
        returns (address token, address tracker)
    {
        (token, tracker) = _launchRewardsBasket(p, msg.sender);
        emit V4TokenMeta(
            token, msg.sender, meta.image, meta.banner, meta.description, meta.website, meta.twitter, meta.telegram
        );
    }

    function _launchRewardsBasket(RewardsBasketLaunchParams calldata p, address creator_)
        internal
        returns (address token, address tracker)
    {
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
        _finishLaunch(token, p.pairToken, p.totalSupply, p.launchTick, cp, p.ethQuotePath, p.minQuoteOut, p.referrer, _devBuySplit(p.devBuyRecipients, p.devBuyBps));
    }

    /// @dev Builds the basket tracker config field by field in its own frame; inlining it into the launch
    /// function overflows the via-IR stack.
    function _deployBasketTracker(
        address token, address quote, uint256 totalSupply, RealmAnyPairsDividendTrackerBasket.Leg[] calldata basket,
        address[] memory vaults
    ) internal returns (address) {
        address[] memory ex = _trackerExcluded(vaults);

        RealmAnyPairsDividendTrackerBasket.Config memory bc;
        bc.token = token;
        bc.feeder = address(taxHook);
        bc.quote = quote;
        bc.swapRouter = swapRouter;
        bc.poolManager = address(poolManager);
        bc.v3Factory = v3Factory;
        // Dust-booking floor: bounds the magnified-share arithmetic and stops one holder capturing the first reward.
        bc.minEligible = totalSupply / 1e4;
        bc.excluded = ex;
        bc.basket = basket;
        return RealmAnyPairsV4PairTrackerDeployer.deployBasketTracker(bc);
    }

    function _launch(LaunchParams calldata p, address creator) internal returns (address token) {
        if (p.totalSupply == 0) revert SupplyZero();
        if (p.totalSupply > uint256(uint128(type(int128).max))) revert SupplyTooLarge();
        // Scoped so the max-wallet locals die before the deep call below (via-IR stack limit).
        {
            (uint256 _mwCap, uint32 _mwSecs) = _maxWalletOf(p.totalSupply, p.maxWalletBps, p.maxWalletMins, p.tradingDelaySecs);
            token = RealmAnyPairsV4TokenDeployer.deployPlain(
                p.name, p.symbol, p.totalSupply, address(this), creator,
                _mwCap, _mwSecs, p.whitelist, p.salt
            );
            if (_mwCap != 0) emit MaxWalletSet(token, _mwCap, uint40(block.timestamp + _mwSecs));
        }
        _createVaults(token, p.vaults, p.totalSupply, p.maxWalletMins);
        _finishLaunch(
            token, p.pairToken, p.totalSupply, p.launchTick, _plainConfig(p, creator),
            p.ethQuotePath, p.minQuoteOut, p.referrer, _devBuySplit(p.devBuyRecipients, p.devBuyBps)
        );
    }

    /// @dev Extracted so the struct's calldata reads don't stay live across {_finishLaunch} (via-IR stack limit).
    function _plainConfig(LaunchParams calldata p, address creator)
        internal pure returns (RealmAnyPairsTaxHookPairImmutable.ConfigParams memory)
    {
        return RealmAnyPairsTaxHookPairImmutable.ConfigParams({
            creator: creator, buyBps: p.buyBps, sellBps: p.sellBps,
            recipients: p.recipients, splitBps: p.splitBps, rewardsTracker: address(0), rewardsBps: 0,
            autoSend: p.autoSend, autoThreshold: p.autoThreshold,
            maxBuyBps: p.maxBuyBps, launchTaxBps: p.launchTaxBps,
            launchTaxSecs: p.launchTaxSecs, tradingDelaySecs: p.tradingDelaySecs,
            buybackBps: p.buybackBps, lpBps: p.lpBps,
            whitelist: p.whitelist
        });
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

    /// @dev Validate, clone, initialise and fund every vault. Called right after the coin is deployed and before
    /// any tracker, so the vault addresses can be excluded from rewards. The max-wallet window is
    /// `maxWalletMins * 60` seconds, as in {_maxWalletOf}.
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
            if (b == address(0) || b == address(this) || b == address(lpLocker) || b == address(poolManager) || b == token) {
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

    /// @dev Every rewards tracker's exclusion list: the locker, the PoolManager, this launcher, the burn address,
    /// and this launch's vaults.
    function _trackerExcluded(address[] memory vaults) internal view returns (address[] memory ex) {
        uint256 n = vaults.length;
        ex = new address[](4 + n);
        ex[0] = address(lpLocker);
        ex[1] = address(poolManager);
        ex[2] = address(this);
        ex[3] = DEAD;
        for (uint256 i; i < n; ++i) ex[4 + i] = vaults[i];
    }

    /// @dev A dev-buy split, carried as one memory value so the launch paths use a single stack slot.
    struct DevBuySplit {
        address[] recipients;
        uint16[] bps;
    }

    function _devBuySplit(address[] calldata recipients, uint16[] calldata bps) internal pure returns (DevBuySplit memory s) {
        s.recipients = recipients;
        s.bps = bps;
    }

    /// @dev Calls the locker's split `launch` when a split was given, its plain form otherwise.
    function _lockerLaunch(
        uint256 value, PoolKey memory key, uint128 liquidity, int24 tickLower, int24 tickUpper, address creator,
        bool quoteIsC0, uint256 devBuyQuote, uint256 coinAmountIn, DevBuySplit memory split
    ) internal returns (uint256) {
        if (split.recipients.length == 0 && split.bps.length == 0) {
            return lpLocker.launch{value: value}(
                key, liquidity, tickLower, tickUpper, creator, quoteIsC0, devBuyQuote, coinAmountIn
            );
        }
        return lpLocker.launch{value: value}(
            key, liquidity, tickLower, tickUpper, creator, quoteIsC0, devBuyQuote, coinAmountIn, split.recipients, split.bps
        );
    }

    /// @dev Seed range bounds, computed inline rather than held in locals (via-IR stack limit).
    function _seedTickLower(bool coinIsC0, int24 poolTick) internal pure returns (int24) {
        return coinIsC0 ? poolTick : _minUsable();
    }

    function _seedTickUpper(bool coinIsC0, int24 poolTick) internal pure returns (int24) {
        return coinIsC0 ? _maxUsable() : poolTick;
    }

    function _finishLaunch(
        address token, address quote, uint256 totalSupply, int24 launchTick,
        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory cp, bytes calldata ethQuotePath, uint256 minQuoteOut, address referrer,
        DevBuySplit memory split
    ) internal {
        if (token == quote) revert TokenEqualsQuote();
        // No native path here, so a zero quote is malformed rather than a mode.
        if (quote == address(0)) revert ZeroAddress();
        _requireSaneParty(cp.creator);
        _requireSaneQuote(quote);

        bool coinIsC0 = token < quote;
        PoolKey memory key = _keyFor(token, quote, coinIsC0);

        // `launchTick` is quote-per-coin; a V4 tick is currency1-per-currency0, so negate it when the coin is
        // currency1. Negation is exact because the usable band is symmetric and the tick is already aligned.
        launchTick = _checkedTick(launchTick);
        if (!coinIsC0) launchTick = -launchTick;

        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(launchTick));
        taxHook.configurePool(key, cp);

        // Orientation cross-check: the hook detects orientation by duck-typing, this launcher by address
        // ordering. Read back the hook's stored answer (the one swaps will use) and require agreement.
        (
            , , , , , ,
            bool storedQuoteIsC0,
            address storedQuote,
            , ,
        ) = taxHook.config(key.toId());
        if (storedQuote != quote || storedQuoteIsC0 != !coinIsC0) revert QuoteOrientationMismatch();

        // Referral screening lives in the hook's {markReferred}; these launcher immutables are screened here
        // because the hook cannot see them. A referral failure must never brick a launch, hence try/catch.
        if (
            referrer != address(0) && referrer != address(lpLocker)
            && referrer != weth && referrer != swapRouter
        ) {
            try taxHook.markReferred{gas: REF_NAME_GAS}(key, referrer) {} catch {}
        }

        uint160 sLo = TickMath.getSqrtPriceAtTick(_seedTickLower(coinIsC0, launchTick));
        uint160 sHi = TickMath.getSqrtPriceAtTick(_seedTickUpper(coinIsC0, launchTick));
        // Seed what this launcher still holds (`totalSupply` minus any vesting vaults). Events keep the total.
        uint256 seedSupply = IERC20(token).balanceOf(address(this));
        uint128 liquidity = coinIsC0
            ? _liquidityForAmount0(sLo, sHi, seedSupply)
            : _liquidityForAmount1(sLo, sHi, seedSupply);
        if (liquidity == 0 || liquidity > Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING)) revert BadLiquidity();

        uint256 devBuyQuote = 0;
        if (msg.value > 0) {
            if (ethQuotePath.length < 43) revert BadDevBuyPath();
            devBuyQuote = _zapEthToQuote(quote, msg.value, ethQuotePath, minQuoteOut);
        }

        if (devBuyQuote > 0) {
            // Re-measure what the locker actually received (fee-on-transfer/rebasing quotes). This block must
            // stay above the price pin below, because the quote's calls hand it control of the frame.
            uint256 lockerBefore = IERC20(quote).balanceOf(address(lpLocker));
            IERC20(quote).safeTransfer(address(lpLocker), devBuyQuote);
            devBuyQuote = IERC20(quote).balanceOf(address(lpLocker)) - lockerBefore;
            // The ETH is already spent; unwind rather than complete a launch whose dev buy bought nothing.
            if (devBuyQuote == 0) revert DevBuyProducedNothing();
        }

        // Pin the launch price. Must sit below every untrusted call (the zap and the quote transfers) and
        // directly above the seed: until seeded, anyone with control could swap the empty pool to any price.
        (uint160 sqrtNow,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (sqrtNow != TickMath.getSqrtPriceAtTick(launchTick)) revert LaunchPriceMoved();

        bool ok = IERC20(token).transfer(address(lpLocker), seedSupply);
        if (!ok) revert SeedTransferFailed();
        uint256 quoteSpent =
            _lockerLaunch(0, key, liquidity, _seedTickLower(coinIsC0, launchTick), _seedTickUpper(coinIsC0, launchTick), cp.creator, !coinIsC0, devBuyQuote, seedSupply, split);

        emit PairLaunch(token, cp.creator, quote, totalSupply, launchTick, msg.value);
        emit PairDevBuySettled(token, quote, msg.value, quoteSpent);
    }

    function _keyFor(address token, address quote, bool coinIsC0) internal view returns (PoolKey memory) {
        (address c0, address c1) = coinIsC0 ? (token, quote) : (quote, token);
        return PoolKey({
            currency0: Currency.wrap(c0), currency1: Currency.wrap(c1),
            fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(taxHook))
        });
    }

    function _zapEthToQuote(address quote, uint256 ethIn, bytes calldata path, uint256 minOut) internal returns (uint256 got) {
        // Validate structure as well as endpoints: a V3 path is 20 bytes + N hops of (3 fee + 20 token).
        require((path.length >= 20 ? path.length - 20 : 20) % 23 == 0, "path malformed");
        require(path.length >= 20 && address(bytes20(path[path.length - 20:])) == quote, "path not to quote");
        require(address(bytes20(path[0:20])) == weth, "path not from WETH");
        IWETH9(weth).deposit{value: ethIn}();
        // forceApprove so the allowance reset below cannot silently no-op.
        IERC20(weth).forceApprove(swapRouter, ethIn);
        uint256 before = IERC20(quote).balanceOf(address(this));
        try ISwapRouter02(swapRouter).exactInput(
            ISwapRouter02.ExactInputParams({path: path, recipient: address(this), amountIn: ethIn, amountOutMinimum: minOut})
        ) returns (uint256) {} catch {
            revert("dev-buy zap failed: check ethQuotePath and minQuoteOut, or use a smaller amount");
        }
        IERC20(weth).forceApprove(swapRouter, 0);
        got = IERC20(quote).balanceOf(address(this)) - before;
        // Check the measured delta against the caller's floor: a fee-on-transfer quote can land below the
        // router's own `amountOutMinimum` check.
        require(got > 0 && got >= minOut, "dev buy landed below minQuoteOut (or the pair is too illiquid)");
    }

    // ─────────────────── vendored LiquidityAmounts (subset) ───────────────────

    function _liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) private pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, Q96);
        uint256 l0 = FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA);
        // Saturate rather than truncate (a bare cast wraps silently); callers bound the result afterwards.
        return l0 > type(uint128).max ? type(uint128).max : uint128(l0);
    }

    function _liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) private pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 l1 = FullMath.mulDiv(amount1, Q96, sqrtB - sqrtA);
        return l1 > type(uint128).max ? type(uint128).max : uint128(l1);
    }
    // ── branded address helpers ──

    /// @notice Every Realm AnyPairs token address ends in these two bytes (0x1110).
    function tokenSuffix() external pure returns (uint16) {
        return RealmAnyPairsV4TokenDeployer.TOKEN_SUFFIX;
    }

    /// @notice The init code hash a launch with these inputs deploys, using the same max-wallet derivation as the
    /// launch. Mine the salt against it last: every argument here is part of the init code.
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
    /// @notice The linked {RealmAnyPairsV4TokenDeployer} every coin is deployed through. Call its
    /// `initCodeHashPlain/initCodeHashDividend` and `predict*` functions directly to mine or verify an address.
    function tokenDeployer() external view returns (address) {
        return address(RealmAnyPairsV4TokenDeployer);
    }

    /// @notice Send a stray balance to `to`. Owner or admin. The launcher holds nothing between transactions, so
    /// any balance here is stray. `nonReentrant` keeps this from running inside a launch.
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
