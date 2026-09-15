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

    /// @notice Uniswap V4 pool manager. Also the `pair` every direct-launched token records, so the
    ///         token's own pre-graduation transfer guard points at the same place the curve venue's does.
    IPoolManager public immutable UNIV4_POOL_MANAGER;

    /// @notice Hook every pool this graduator creates is bound to. `RealmHook` for native-quoted pools.
    address public immutable HOOK_ADDRESS;

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

    /// @dev Set by `prepare`, cleared by nothing — the transient slot clears itself at end of tx.
    bool transient _prepared;

    /// @dev The token `initialize` was called for. `graduateToken` requires the same one, so a factory
    ///      that staged one launch cannot seed a different token with it.
    address transient _initializedToken;

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
    /// @notice Thrown when a dev buy is requested on a pair whose quote is not native. The settle leg
    ///         below pays in native; an ERC20 quote needs a `sync` + transfer + `settle` instead, which
    ///         lands with the rest of the ERC20-quote work. Unreachable today — the factory refuses an
    ///         ERC20 quote outright — and here so it stays a revert rather than a wrong-currency settle.
    error NativeDevBuyOnly();

    /////////////////////// Events ///////////////////////

    /// @notice Mirrors `RealmGraduatorUniswapV4`: lets an indexer map a token to its V4 pool id and the
    ///         hook mediating its swaps without reconstructing the key.
    event PoolIdRegistered(address indexed token, bytes32 poolId, address swapHookAddress);

    /// @notice Emitted once per pool seeded at launch, carrying everything an indexer needs to price the
    ///         pool before a single swap has happened.
    /// @param token      The launched token.
    /// @param quote      The currency it trades against; `address(0)` for native.
    /// @param poolId     `PoolId` of the pool, the universal V4 join key.
    /// @param weightBps  Share of the seeded supply this pool received, in bps. Always 10,000 while a
    ///                   launch has exactly one pair; carried from the start so the multi-pair rollout
    ///                   does not change the event signature.
    /// @param tick       Launch price as QUOTE PER COIN, in ticks — the caller-supplied value, not the
    ///                   pool's internal orientation.
    /// @param liquidity  Uniswap V4 liquidity units the seed band minted.
    event PoolSeeded(
        address indexed token, address indexed quote, bytes32 poolId, uint16 weightBps, int24 tick, uint128 liquidity
    );

    //////////////////////////////////////////////////////

    constructor(address poolManager, address hook, address liquidityAdder) {
        UNIV4_POOL_MANAGER = IPoolManager(poolManager);
        HOOK_ADDRESS = hook;
        LIQUIDITY_ADDER = liquidityAdder;
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
    function prepare(address quote, int24 launchTick) external {
        _validateLaunchTick(launchTick);
        _pendingQuote = quote;
        _pendingLaunchTick = launchTick;
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

        PoolKey memory key = UniswapV4PoolConstants.realmPoolKey(tokenAddress, quote, HOOK_ADDRESS);
        UNIV4_POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(_poolTick(tokenAddress, quote)));
        _initializedToken = tokenAddress;

        emit PairInitialized(tokenAddress, address(UNIV4_POOL_MANAGER));
        emit PoolIdRegistered(tokenAddress, PoolId.unwrap(key.toId()), HOOK_ADDRESS);
        return address(UNIV4_POOL_MANAGER);
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
        // "the caller is the factory mid-`createToken`" needs no separate check to be true. Consumed
        // here so a second call cannot re-enter the same launch.
        require(tokenAddress == _initializedToken, LaunchNotPrepared());
        _initializedToken = address(0);
        require(tokenAmount > 0, NoTokensToGraduate());

        address quote = _pendingQuote;
        int24 launchTick = _pendingLaunchTick;
        PoolKey memory key = UniswapV4PoolConstants.realmPoolKey(tokenAddress, quote, HOOK_ADDRESS);

        // Opens the gate on transfers to the pool manager, which the seed below is the first to use.
        IRealmToken(tokenAddress).markGraduated();

        uint128 liquidity = _seed(key, tokenAddress, quote, tokenAmount, launchTick);

        // The band is the only liquidity in the pool, so the dev buy is a pure function of the launch
        // tick and the supply seeded — the pool did not exist a few frames ago and nobody else can have
        // traded it. That is why no slippage bound is taken for this leg.
        if (msg.value > 0) {
            require(quote == address(0), NativeDevBuyOnly());
            _devBuy(key, tokenAddress, quote, msg.sender);
        }

        // Rounding remainder the band could not absorb. Burned rather than held, for the reason the
        // `DEAD_ADDRESS` comment gives.
        uint256 dust = IERC20(tokenAddress).balanceOf(address(this));
        if (dust > 0) IERC20(tokenAddress).safeTransfer(DEAD_ADDRESS, dust);

        emit TokenGraduated(tokenAddress, tokenAmount, msg.value, liquidity);
    }

    /// @notice The pool manager's re-entry into this contract for the dev buy. Does nothing a caller
    ///         could steer: the only path that opens the lock is `graduateToken`, which encodes its own
    ///         key and amount, and the callback refuses anyone but the manager.
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
        UNIV4_POOL_MANAGER.settle{value: amountIn}();
        // forge-lint: disable-next-line(unsafe-typecast)
        UNIV4_POOL_MANAGER.take(quoteIsC0 ? key.currency1 : key.currency0, address(this), uint256(uint128(coinDelta)));
        return "";
    }

    ////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////////

    /// @dev Deposits the whole seed as a single-sided COIN band through the shared adder. The band spans
    ///      from the launch price to the far end of the usable range on the side that holds only the
    ///      coin — above the current tick when the coin is `currency1`'s counterpart, below it otherwise
    ///      — so every buy walks into it and no quote is ever needed to open the pool. The NFT stays
    ///      here, permanently: that is the liquidity lock.
    function _seed(PoolKey memory key, address token, address quote, uint256 amount, int24 launchTick)
        internal
        returns (uint128 liquidity)
    {
        int24 poolTick = _poolTick(token, quote);
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

        emit PoolSeeded(token, quote, PoolId.unwrap(key.toId()), 10_000, launchTick, liquidity);
    }

    /// @dev Spends the forwarded `msg.value` on the coin and hands the result to the factory, which owns
    ///      the recipient split. Runs inside this contract's OWN `unlock`, not through a router: the
    ///      launch and its first buy are one transaction, and a router would need an approval, a
    ///      deadline and a second trust boundary to do the same swap.
    function _devBuy(PoolKey memory key, address token, address quote, address recipient) internal {
        bool quoteIsC0 = Currency.unwrap(key.currency0) == quote;
        UNIV4_POOL_MANAGER.unlock(abi.encode(key, msg.value, quoteIsC0));
        IERC20(token).safeTransfer(recipient, IERC20(token).balanceOf(address(this)));
    }

    /// @dev The launch tick in the POOL's orientation. `launchTick` is quote-per-coin; a V4 tick is
    ///      currency1-per-currency0, which is the same thing when the coin is `currency0` and its
    ///      reciprocal otherwise. Negation is exact because the usable band is symmetric and the tick is
    ///      already spacing-aligned.
    function _poolTick(address token, address quote) internal view returns (int24) {
        int24 launchTick = _pendingLaunchTick;
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
