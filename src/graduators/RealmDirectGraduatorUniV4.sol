// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "lib/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {Pool} from "lib/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IRealmGraduator} from "src/interfaces/IRealmGraduator.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmUniV4LiquidityAdder} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {RealmLaunchPricing} from "src/libraries/RealmLaunchPricing.sol";
// Self-aliased so the `chain-*` recipes can import-swap it for the target chain's pool constants.
import {UniswapV4PoolConstants as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";

/// @title RealmDirectGraduatorUniV4
/// @notice The DIRECT-launch venue: a Realm token that never touches a bonding curve. The pool is
///         created at a price the creator picks, the whole circulating supply is seeded as a
///         SINGLE-SIDED token band, and the creator's own dev buy is the first trade — all inside the
///         one `createToken` transaction.
///
/// @dev Shape-compatible with `RealmGraduatorUniswapV4` (same `IRealmGraduator`, same
///      `HOOK_ADDRESS()` / `LIQUIDITY_ADDER()` views the taxable tokens read for their keeper paths),
///      so a direct-launched token is an ORDINARY graduated Realm token from every other contract's
///      point of view. What differs is only how it got there:
///      - There is no launchpad and no curve. The token's supply is minted straight here (its
///        `launchpad` is `address(0)`, so `RealmToken` falls back to the graduator as the mint target),
///        and `graduateToken` is called by the FACTORY rather than by a launchpad.
///      - There is no graduation fee. A curve graduation splits the ETH the curve accumulated; here the
///        only ETH in the transaction is the creator's own dev buy, and taking a cut of that would just
///        be a launch fee under another name. The protocol earns from the hook's LP fee, as always.
///      - The launch price is an INPUT (`launchTick`), not a per-tier constant, so the seed band is
///        whatever the creator's tick implies rather than a fixed geometry.
///
/// @dev Non-upgradeable and ownerless. It holds the seed position NFT forever — that is the liquidity
///      lock — and ends every transaction with no balance of anything, so there is nothing to rescue and
///      no admin needed to rescue it.
/// @dev It also names no factory. A launch is authorised by WHO CALLS `initialize` (the token, on
///      itself, from inside its own initializer) rather than by an address configured here, which keeps
///      the graduator and the factory from having to know each other's address at deploy time — they
///      would otherwise each need the other's, and neither exists first. Every other entry point hangs
///      off that one: `prepare` only writes transient storage, and `graduateToken` only works on the
///      token the same transaction just initialized. A second factory can reuse this same graduator.
contract RealmDirectGraduatorUniV4 is IRealmGraduator, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Sink for the token dust left over after the seed deposit. Never the graduator itself: a
    ///         graduator balance is a CONTINUOUS holder and would accrue dividends nobody can claim.
    address internal constant DEAD_ADDRESS = address(0xdEaD);

    /// @notice A pool's graduation target as a multiple of its opening market cap, reported in
    ///         `PoolSeeded`. On-chain a direct-launched token is graduated from birth; indexers show it
    ///         graduated once its largest pool (highest `weightBps`, the first seeded on a tie) trades
    ///         at this multiple. A display milestone only: nothing here enforces it.
    /// @dev 5x is the DEFAULT curve's own run, from its 2.25 ETH opening to its 12.25 ETH graduation.
    uint256 public constant GRADUATION_TARGET_MULTIPLE = 5;

    /// @notice Uniswap V4 pool manager. Also the `pair` every direct-launched token records, so the
    ///         token's own pre-graduation transfer guard points at the same place the curve venue's does.
    IPoolManager public immutable UNIV4_POOL_MANAGER;

    /// @notice Hook the NATIVE-quoted pool is bound to: `RealmHook`, the variant Uniswap whitelisted.
    address public immutable HOOK_ADDRESS;

    /// @notice Hook every ERC20-quoted pool is bound to: `RealmHookAnyPair`, which resolves which side
    ///         of the pair is the token and collects its fee in the quote. A second hook rather than a
    ///         change to the first, because `RealmHook`'s bytecode is whitelisted and must not move.
    address public immutable ANY_PAIR_HOOK;

    /// @notice The shared, permissionless `RealmUniV4LiquidityAdder` singleton. Used here for the seed
    ///         band and resolved through this same getter by the tokens' `processLiquidity`.
    address public immutable LIQUIDITY_ADDER;

    /////////////////////// Launch parameters (transient) ///////////////////////
    // `IRealmGraduator.initialize(token)` is called by the TOKEN from inside its own initializer and
    // takes nothing but the token address, so the launch price cannot be an argument. The factory
    // stages it here immediately before cloning the token and it is read back a few frames later, in
    // the same transaction. Transient storage is what makes that safe to do on a shared contract:
    // the slots are wiped at the end of the transaction, so a launch can never inherit a stale price,
    // and `prepare` is factory-only, so nobody else can stage one.

    /// @dev Quote currency of the pool being launched; `address(0)` is native. Ambiguous on its own
    ///      (native and "nothing staged" read the same), hence `_prepared`.
    address transient _pendingQuote;

    /// @dev Launch price as QUOTE PER COIN, in ticks. Converted to the pool's own orientation in
    ///      `_poolTick` — a V4 tick is currency1-per-currency0, which is the reciprocal whenever the
    ///      coin sorts as currency1.
    int24 transient _pendingLaunchTick;

    /// @dev Pair 0's share of the circulating supply, in bps. Staged with the rest of pair 0 because
    ///      `graduateToken` — whose signature is `IRealmGraduator`'s and cannot grow — reports it.
    uint16 transient _pendingWeightBps;

    /// @dev Set by `prepare`, cleared by `burnSeedDust` — the last call of every launch — so a batched
    ///      transaction can run another launch, and nothing later in it can drive this one.
    bool transient _prepared;

    /// @dev The token `initialize` was called for: the launch in flight. EVERY other entry point
    ///      requires the same one, so a factory that staged one launch cannot drive another with it, and
    ///      nothing outside the creating transaction can drive one at all.
    address transient _initializedToken;

    /// @dev Set by `graduateToken`, so a launch cannot be graduated (and pair 0 seeded) twice.
    bool transient _launched;

    /////////////////////// Errors ///////////////////////

    /// @notice Thrown when `initialize` runs with no launch staged, when it is called by anyone but
    ///         the token itself, or when `graduateToken` names a token other than the one `initialize`
    ///         created the pool for.
    error LaunchNotPrepared();
    /// @notice Thrown when `launchTick` is not a multiple of the tick spacing, or not STRICTLY inside
    ///         the usable band. Strictly, so the single-sided seed range is non-empty in both
    ///         orientations.
    error InvalidLaunchTick();
    /// @notice Thrown when the token's own address equals the quote, which would not be a pair.
    error TokenEqualsQuote();
    /// @notice Thrown when the supply to seed sizes to zero liquidity, or to more than a single tick of
    ///         this spacing can hold. Both are unmintable; failing here names the reason.
    error SeedLiquidityOutOfRange();
    /// @notice Thrown when the pool price moved between `initialize` and the seed. Unreachable today —
    ///         a pool with no liquidity cannot be swapped — and cheap insurance against a future path
    ///         that hands control away in between.
    error LaunchPriceMoved();
    /// @notice Thrown when the dev buy could not consume the whole `msg.value`, i.e. the swap hit the
    ///         end of the band. Reverting hands the creator their ETH back instead of stranding the
    ///         remainder here.
    error DevBuyNotFilled();
    /// @notice Thrown when `unlockCallback` is reached from anywhere but the pool manager.
    error OnlyPoolManager();

    /////////////////////// Events ///////////////////////

    /// @notice Mirrors `RealmGraduatorUniswapV4`: lets an indexer map a token to its V4 pool id and the
    ///         hook mediating its swaps without reconstructing the key.
    event PoolIdRegistered(address indexed token, bytes32 poolId, address swapHookAddress);

    /// @notice Emitted once per pool seeded at launch, carrying everything an indexer needs to price the
    ///         pool before a single swap has happened.
    /// @param token      The launched token.
    /// @param quote      The currency it trades against; `address(0)` for native.
    /// @param poolId     `PoolId` of the pool, the universal V4 join key.
    /// @param weightBps  Share of the seeded supply this pool received, in bps; the weights of a
    ///                   launch's pools sum to 10,000.
    /// @param tick       Launch price as QUOTE PER COIN, in ticks — the caller-supplied value, not the
    ///                   pool's internal orientation.
    /// @param liquidity  Uniswap V4 liquidity units the seed band minted.
    /// @param launchMarketCap Market cap `tick` implies across the whole supply, in the quote's RAW units
    ///                   (wei for native, no decimals applied).
    /// @param targetMarketCap `launchMarketCap * GRADUATION_TARGET_MULTIPLE`, same units.
    event PoolSeeded(
        address indexed token,
        address indexed quote,
        bytes32 poolId,
        uint16 weightBps,
        int24 tick,
        uint128 liquidity,
        uint256 launchMarketCap,
        uint256 targetMarketCap
    );

    //////////////////////////////////////////////////////

    constructor(address poolManager, address hook, address anyPairHook, address liquidityAdder) {
        UNIV4_POOL_MANAGER = IPoolManager(poolManager);
        HOOK_ADDRESS = hook;
        ANY_PAIR_HOOK = anyPairHook;
        LIQUIDITY_ADDER = liquidityAdder;
    }

    /// @notice The hook mediating the pool this token shares with `quote`. See the two immutables.
    function hookFor(address quote) public view returns (address) {
        return quote == address(0) ? HOOK_ADDRESS : ANY_PAIR_HOOK;
    }

    /// @notice Defensive. Nothing routes native here: the dev buy settles exactly what it owes and
    ///         reverts otherwise, and the seed is token-only. Accepting it anyway keeps a stray refund
    ///         from taking a launch down mid-flight.
    receive() external payable {}

    ////////////////////////////// EXTERNAL FUNCTIONS ///////////////////////////////////

    /// @notice Stages the pool `initialize` is about to create, for the rest of THIS transaction.
    ///         Deliberately open: it writes nothing but transient storage, and `initialize` will only
    ///         act on it for a caller that IS the token being launched.
    /// @param quote Currency the token trades against. `address(0)` is native.
    /// @param launchTick Opening price as QUOTE PER COIN (`price = 1.0001^launchTick`), so a higher tick
    ///        is always a more expensive coin whichever way the pair happens to sort. Must be a multiple
    ///        of the tick spacing and strictly inside the usable band; it is VALIDATED, never rounded, so
    ///        a creator always launches at exactly the price they asked for.
    /// @param weightBps Pair 0's share of the circulating supply, in bps. Carried for `PoolSeeded` only.
    function prepare(address quote, int24 launchTick, uint16 weightBps) external {
        _validateLaunchTick(launchTick);
        _pendingQuote = quote;
        _pendingLaunchTick = launchTick;
        _pendingWeightBps = weightBps;
        _prepared = true;
    }

    /// @notice Creates the token's pool at the staged launch price. Called by the token from inside its
    ///         own initializer, exactly as the curve venue's graduator is.
    /// @return The pool manager, which the token records as its `pair` — the address its transfer guard
    ///         blocks until graduation.
    function initialize(address tokenAddress) external override returns (address) {
        // The token, and only the token, calling this on itself from inside its own initializer. This
        // is what makes `prepare` safe to leave open: a pool key is `(currencies, fee, spacing, hook)`,
        // so anyone able to drive `initialize` for someone else's address could FRONT-RUN a pending
        // launch by creating that exact pool first, at a price of their choosing, and the real launch
        // would revert `PoolAlreadyInitialized`. Nobody can be an address that has no code yet.
        require(_prepared && msg.sender == tokenAddress, LaunchNotPrepared());
        address quote = _pendingQuote;
        require(tokenAddress != quote, TokenEqualsQuote());

        _initializedToken = tokenAddress;
        // Before `_openPool`'s `PoolIdRegistered`: the same order `RealmGraduatorUniswapV4` emits, which
        // indexers depend on.
        emit PairInitialized(tokenAddress, address(UNIV4_POOL_MANAGER));
        _openPool(tokenAddress, quote, _pendingLaunchTick);

        return address(UNIV4_POOL_MANAGER);
    }

    /// @notice Creates ANOTHER pool for the launch in flight, against a second quote. Driven by the
    ///         factory rather than the token, because only the FIRST pool has to be created from inside
    ///         the token's initializer — that is the one whose address the token records as its `pair`,
    ///         and the only call that cannot take arguments.
    /// @dev Authorised by the same thing every other entry point is: `token` must be the launch this
    ///      transaction's `initialize` opened, which transient storage makes unreachable from any later
    ///      one. Nothing else can be in flight, so no separate caller check is needed.
    function initializePool(address tokenAddress, address quote, int24 launchTick) external {
        require(tokenAddress == _initializedToken, LaunchNotPrepared());
        require(tokenAddress != quote, TokenEqualsQuote());
        _validateLaunchTick(launchTick);
        _openPool(tokenAddress, quote, launchTick);
    }

    /// @dev Creates one pool at `launchTick` and announces it. Shared by the two entry points above.
    function _openPool(address tokenAddress, address quote, int24 launchTick) internal {
        address hook = hookFor(quote);
        PoolKey memory key = UniswapV4PoolConstants.realmPoolKey(tokenAddress, quote, hook);
        UNIV4_POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(_poolTickFor(tokenAddress, quote, launchTick)));
        emit PoolIdRegistered(tokenAddress, PoolId.unwrap(key.toId()), hook);
    }

    /// @notice Opens the token for trading and seeds its pool: marks it graduated, deposits `tokenAmount`
    ///         as a single-sided band covering the whole usable range on the coin's side of the launch
    ///         price, and — if the factory forwarded any — spends `msg.value` on the creator's dev buy.
    ///         Whatever that buy acquires is handed to the factory, which splits it across the
    ///         creator's recipients.
    /// @dev Called by the FACTORY, not a launchpad: the direct venue has no pre-graduation phase, so
    ///      "graduation" and "launch" are the same instant. The name and signature are `IRealmGraduator`'s
    ///      so every other contract keeps seeing an ordinary graduated Realm token.
    /// @param tokenAmount Supply to seed. This contract holds it already — the token minted it here.
    function graduateToken(address tokenAddress, uint256 tokenAmount) external payable override {
        // Reachable only in the same transaction as the `initialize` that staged it — the marker lives
        // in transient storage — and `createToken` hands control to nothing untrusted in between, so
        // "the caller is the factory mid-`createToken`" needs no separate check to be true.
        require(tokenAddress == _initializedToken && !_launched, LaunchNotPrepared());
        _launched = true;
        require(tokenAmount > 0, NoTokensToGraduate());

        // Opens the gate on transfers to the pool manager, which the seed below is the first to use.
        IRealmToken(tokenAddress).markGraduated();

        uint128 liquidity = _seedPool(tokenAddress, _pendingQuote, _pendingLaunchTick, tokenAmount, _pendingWeightBps);
        emit TokenGraduated(tokenAddress, tokenAmount, msg.value, liquidity);
    }

    /// @notice Seeds ANOTHER of the launch's pools. Same authorisation as `initializePool`.
    /// @param weightBps This pool's share of the circulating supply, in bps — carried for `PoolSeeded`
    ///        only; the amount itself is `tokenAmount`, which the factory has already split.
    function seedPool(address tokenAddress, address quote, int24 launchTick, uint256 tokenAmount, uint16 weightBps)
        external
        returns (uint128 liquidity)
    {
        require(tokenAddress == _initializedToken && _launched, LaunchNotPrepared());
        require(tokenAmount > 0, NoTokensToGraduate());
        return _seedPool(tokenAddress, quote, launchTick, tokenAmount, weightBps);
    }

    /// @notice Spends everything this graduator holds of `quote` on the token, and hands the result to
    ///         the caller — the factory, which owns the recipient split.
    /// @dev A separate entry point from `graduateToken` so a launch with several pools can name WHICH
    ///      one the creator's buy executes on. The buy is a pure function of the launch tick and the
    ///      supply seeded — the pool did not exist a few frames ago and nobody else can have traded it —
    ///      which is why no slippage bound is taken for this leg.
    /// @dev Native arrives as `msg.value`; an ERC20 quote is transferred here by the factory first, and
    ///      the whole balance is spent. Either way nothing is left behind: a partial fill reverts.
    function devBuy(address tokenAddress, address quote) external payable {
        require(tokenAddress == _initializedToken && _launched, LaunchNotPrepared());
        uint256 amountIn = quote == address(0) ? msg.value : IERC20(quote).balanceOf(address(this));
        require(amountIn > 0, NoETHToGraduate());

        PoolKey memory key = UniswapV4PoolConstants.realmPoolKey(tokenAddress, quote, hookFor(quote));
        bool quoteIsC0 = Currency.unwrap(key.currency0) == quote;
        // Exactly what the swap delivered, not this contract's balance: the seed remainder is still
        // here, waiting for `burnSeedDust`.
        uint256 bought = abi.decode(UNIV4_POOL_MANAGER.unlock(abi.encode(key, amountIn, quoteIsC0)), (uint256));
        IERC20(tokenAddress).safeTransfer(msg.sender, bought);
    }

    /// @notice Burns whatever supply the seed bands could not absorb, once every pool of the launch has
    ///         been seeded and the dev buy has run, and CLOSES the launch. Same authorisation as the
    ///         other factory-driven entry points; the factory calls it last.
    /// @dev A SEPARATE call rather than something each seed does, because with several pools this
    ///      contract holds the later pools' share between seeds and "everything left over is dust" is
    ///      only true after the last one. Burned rather than held because a graduator balance is a
    ///      CONTINUOUS holder — see the `DEAD_ADDRESS` comment.
    /// @dev Closing clears the transient launch markers. They would otherwise live to the end of the
    ///      transaction, where a batched one (multicall, account-abstraction bundle) would find its next
    ///      launch refused and could still drive this finished one — a `devBuy` hands its tokens over
    ///      through the graduator's sniper-cap exemption.
    function burnSeedDust(address tokenAddress) external {
        require(tokenAddress == _initializedToken && _launched, LaunchNotPrepared());
        uint256 dust = IERC20(tokenAddress).balanceOf(address(this));
        if (dust > 0) IERC20(tokenAddress).safeTransfer(DEAD_ADDRESS, dust);
        _prepared = false;
        _initializedToken = address(0);
        _launched = false;
    }

    /// @dev Seeds ONE pool with `tokenAmount`.
    function _seedPool(address tokenAddress, address quote, int24 launchTick, uint256 tokenAmount, uint16 weightBps)
        internal
        returns (uint128 liquidity)
    {
        PoolKey memory key = UniswapV4PoolConstants.realmPoolKey(tokenAddress, quote, hookFor(quote));
        return _seed(key, tokenAddress, quote, tokenAmount, launchTick, weightBps);
    }

    /// @notice The pool manager's re-entry into this contract for the dev buy. Does nothing a caller
    ///         could steer: the only path that opens the lock is `devBuy`, which encodes its own key and
    ///         amount, and the callback refuses anyone but the manager. Returns the tokens bought.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(UNIV4_POOL_MANAGER), OnlyPoolManager());
        (PoolKey memory key, uint256 amountIn, bool quoteIsC0) = abi.decode(data, (PoolKey, uint256, bool));

        // Exact-input (negative `amountSpecified`) with the price limit at the far end of the band, so
        // the swap is bounded by the liquidity it finds rather than by a price we picked.
        BalanceDelta delta = UNIV4_POOL_MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: quoteIsC0,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: quoteIsC0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // `swap` returns THIS contract's own delta, hook deltas already folded in, so the two legs below
        // are the whole settlement: what we owe on the quote side, what we are owed on the coin side.
        (int128 quoteDelta, int128 coinDelta) =
            quoteIsC0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        // forge-lint: disable-next-line(unsafe-typecast)
        require(uint256(uint128(-quoteDelta)) == amountIn, DevBuyNotFilled());
        _settleQuote(quoteIsC0 ? key.currency0 : key.currency1, amountIn);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 bought = uint256(uint128(coinDelta));
        UNIV4_POOL_MANAGER.take(quoteIsC0 ? key.currency1 : key.currency0, address(this), bought);
        return abi.encode(bought);
    }

    /// @dev Pays the quote the swap owes. Native settles straight from the forwarded value; an ERC20
    ///      goes through v4's `sync` -> transfer -> `settle` handshake, which is how the manager
    ///      measures what actually arrived (and therefore the only shape that is honest about a
    ///      fee-on-transfer quote).
    function _settleQuote(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            UNIV4_POOL_MANAGER.settle{value: amount}();
            return;
        }
        UNIV4_POOL_MANAGER.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(UNIV4_POOL_MANAGER), amount);
        UNIV4_POOL_MANAGER.settle();
    }

    ////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////////

    /// @dev Deposits the whole seed as a single-sided COIN band through the shared adder. The band spans
    ///      from the launch price to the far end of the usable range on the side that holds only the
    ///      coin — above the current tick when the coin is `currency1`'s counterpart, below it otherwise
    ///      — so every buy walks into it and no quote is ever needed to open the pool. The NFT stays
    ///      here, permanently: that is the liquidity lock.
    function _seed(PoolKey memory key, address token, address quote, uint256 amount, int24 launchTick, uint16 weightBps)
        internal
        returns (uint128 liquidity)
    {
        int24 poolTick = _poolTickFor(token, quote, launchTick);
        // Nothing can have moved it (an empty pool cannot be swapped), but the seed is the last thing
        // that would notice if something ever could.
        (uint160 sqrtNow,,,) = UNIV4_POOL_MANAGER.getSlot0(key.toId());
        require(sqrtNow == TickMath.getSqrtPriceAtTick(poolTick), LaunchPriceMoved());

        bool coinIsC0 = token < quote;
        (int24 tickLower, int24 tickUpper) = coinIsC0 ? (poolTick, _maxUsableTick()) : (_minUsableTick(), poolTick);

        // Sized here as well as inside the adder so an unmintable band names its own reason. v4-core
        // rejects a zero delta (`CannotUpdateEmptyPosition`) and anything over the per-tick ceiling
        // with errors that say nothing about which input was wrong.
        liquidity = coinIsC0
            ? LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount
            )
            : LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount
            );
        require(
            liquidity > 0 && liquidity <= Pool.tickSpacingToMaxLiquidityPerTick(key.tickSpacing),
            SeedLiquidityOutOfRange()
        );

        IERC20(token).forceApprove(LIQUIDITY_ADDER, amount);
        liquidity = IRealmUniV4LiquidityAdder(LIQUIDITY_ADDER)
            .addSingleSided(key, Currency.wrap(token), amount, tickLower, tickUpper, address(this), address(this));

        _emitPoolSeeded(token, quote, PoolId.unwrap(key.toId()), weightBps, launchTick, liquidity);
    }

    /// @dev Split out of `_seed`, whose stack is already full.
    function _emitPoolSeeded(
        address token,
        address quote,
        bytes32 poolId,
        uint16 weightBps,
        int24 launchTick,
        uint128 liquidity
    ) internal {
        uint256 launchMarketCap = RealmLaunchPricing.rawMarketCapAtTick(launchTick);
        emit PoolSeeded(
            token,
            quote,
            poolId,
            weightBps,
            launchTick,
            liquidity,
            launchMarketCap,
            launchMarketCap * GRADUATION_TARGET_MULTIPLE
        );
    }

    /// @dev The launch tick in the POOL's orientation. `launchTick` is quote-per-coin; a V4 tick is
    ///      currency1-per-currency0, which is the same thing when the coin is `currency0` and its
    ///      reciprocal otherwise. Negation is exact because the usable band is symmetric and the tick is
    ///      already spacing-aligned.
    function _poolTickFor(address token, address quote, int24 launchTick) internal pure returns (int24) {
        return token < quote ? launchTick : -launchTick;
    }

    /// @dev Spacing-aligned and STRICTLY inside the usable band. Strictly, because the seed band runs
    ///      from the launch tick to whichever end of the band holds only the coin: at either extreme
    ///      that range would be empty and there would be nothing to buy.
    function _validateLaunchTick(int24 tick) internal pure {
        require(
            tick > _minUsableTick() && tick < _maxUsableTick() && tick % UniswapV4PoolConstants.TICK_SPACING == 0,
            InvalidLaunchTick()
        );
    }

    /// @dev Lowest spacing-aligned tick a position may use.
    function _minUsableTick() internal pure returns (int24) {
        // Snapping to the spacing grid is the intent here, not an accident of ordering.
        // forge-lint: disable-next-line(divide-before-multiply)
        return (TickMath.MIN_TICK / UniswapV4PoolConstants.TICK_SPACING) * UniswapV4PoolConstants.TICK_SPACING;
    }

    /// @dev Highest spacing-aligned tick a position may use.
    function _maxUsableTick() internal pure returns (int24) {
        // forge-lint: disable-next-line(divide-before-multiply)
        return (TickMath.MAX_TICK / UniswapV4PoolConstants.TICK_SPACING) * UniswapV4PoolConstants.TICK_SPACING;
    }
}
