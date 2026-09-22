// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {RealmUniv4BuyBacks} from "src/tokens/RealmUniv4BuyBacks.sol";
// Self-aliased so the `chain-*` recipes can import-swap it for the target chain's pool constants.
import {UniswapV4PoolConstants as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode) - see the justfile `_taxtoken` recipe.
import {DeploymentAddressesRobinhoodTestnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @notice Minimal view onto the V4 graduator: the hook it paired the token's pool with (to rebuild the
///         pool key) and the shared liquidity adder it uses (to mint the single-sided ETH wall).
interface IRealmV4Graduator {
    function HOOK_ADDRESS() external view returns (address);
    function LIQUIDITY_ADDER() external view returns (address);

    /// @notice The hook mediating the pool this token shares with `quote`. Native pools keep
    ///         `RealmHook`, which Uniswap whitelisted; an ERC20-quoted pool is served by
    ///         `RealmHookAnyPair`.
    function hookFor(address quote) external view returns (address);
}

/// @title RealmTaxableTokenUniV4Base
/// @notice Everything the Uniswap-V4 taxable token and its dividend extension must AGREE on: the token's
///         own storage, the buy-back precursor events, and the small reads either side may perform.
/// @dev This exists so `RealmTaxableTokenUniV4` and `RealmDividendLogicUniV4` derive an IDENTICAL storage
///      layout from the same declarations — including the inheritance ORDER below, which is what places
///      them. The extension is `delegatecall`ed with the token's storage, so a layout that drifts would
///      have it writing the wrong slots; splitting the declarations out here makes that structurally
///      impossible rather than merely tested (it is tested too — see
///      `just check-dividend-layout`). Nothing behavioural belongs here: put a function in
///      this base only when BOTH sides need it, and everything else in the contract that uses it.
abstract contract RealmTaxableTokenUniV4Base is RealmTaxableToken, RealmUniv4BuyBacks {
    /////////////////////////// venue constants ///////////////////////
    // NB: hardcoded per target chain to save gas.

    /// @notice Pool manager for lock state checking
    address public constant UNIV4_POOL_MANAGER = DeploymentAddresses.UNIV4_POOL_MANAGER;

    /// @notice Position manager holding this token's liquidity walls. Only `processLiquidity`'s top-up
    ///         path calls it directly — minting still goes through the shared `RealmUniV4LiquidityAdder` —
    ///         because `PositionManager._increase` is `onlyIfApproved` and this token owns the NFTs.
    address public constant UNIV4_POSITION_MANAGER = DeploymentAddresses.UNIV4_POSITION_MANAGER;

    /// @notice Max ETH a single `processBurn` / `processLiquidity` call may spend. Combined with the
    ///         once-per-block cooldown, it caps what a price-manipulation sandwich can extract from the
    ///         buffers per block (the pump must be re-paid — or held, exposed to arbitrage — every
    ///         block), while honest keepers just drain in batches. The remainder stays buffered.
    uint256 public constant MAX_EARNINGS_PER_PROCESS = DeploymentAddresses.MAX_EARNINGS_PER_PROCESS;

    /// @notice Width, in TICKS, of the single-sided ETH liquidity wall minted by `processLiquidity`. The
    ///         wall spans from just below the current price down to roughly -75%: ticks are log-price
    ///         (price = 1.0001^tick), so 14000 ticks (70 * the current 200 spacing) is a price ratio of
    ///         1.0001^14000 ≈ 4.05, i.e. the far end of the range is ~1/4.05 ≈ 0.25 of the current price
    ///         (a ~-75% drop). A given % drop maps to a CONSTANT tick width regardless of the starting
    ///         price. Derived from TICK_SPACING so the range stays spacing-aligned (and mints cleanly)
    ///         even if the spacing is ever retargeted per chain.
    int24 internal constant LIQUIDITY_WALL_TICK_WIDTH = 70 * UniswapV4PoolConstants.TICK_SPACING;

    /// @notice Max distance, in TICKS, between the current tick and a remembered wall's lower tick for
    ///         `processLiquidity` to top that wall up instead of minting a new one. 2000 ticks is a ~22%
    ///         price rise since the wall was placed (1.0001^2000 ≈ 1.22), so a reused wall covers roughly
    ///         -18% to -79% of the current price where a fresh one covers 0% to -75%.
    /// @dev The bound is what stops the reuse path from degrading into "pile every future add into the
    ///      first wall ever minted". Deliberately far below `LIQUIDITY_WALL_TICK_WIDTH` (the widest value
    ///      that still leaves the old and the hypothetical fresh range overlapping): the dominant reason
    ///      to mint is a price DROP, which disqualifies the old wall outright, so tightening this costs
    ///      almost no reuse and buys a materially better-placed wall. It also caps how deep a
    ///      price-pumping manipulator can steer an add.
    int24 internal constant LIQUIDITY_WALL_REUSE_MAX_GAP = 10 * UniswapV4PoolConstants.TICK_SPACING;

    /// @notice Share of an ERC20 quote's buffer one `processBurn` / `processLiquidity` call may spend,
    ///         in bps. The unit-free counterpart of `MAX_EARNINGS_PER_PROCESS`, which is denominated in
    ///         the chain's native currency and therefore means nothing for a quote the creator picked.
    /// @dev 25% does the same job an absolute cap does: it forces a price-manipulation sandwich to
    ///      re-pay its pump every block for a geometrically shrinking prize, while an honest keeper just
    ///      drains in a handful of batches. It is the SECOND bound either way — the keeper gate is what
    ///      actually stops a caller choosing their own slippage floor around their own manipulation.
    uint256 internal constant MAX_QUOTE_SPEND_BPS = 2_500;

    /////////////////////////// pure storage ///////////////////////

    /// @notice Everything one QUOTE's out-of-band earnings machinery needs: what it has accrued, when
    ///         it last spent it, and which liquidity walls it has placed. One entry per entry of the
    ///         token's `quotes`, at the SAME index — so index 0 is always the chain's native currency
    ///         and a native-only token uses exactly this one, as it always has.
    /// @dev Per quote, not per token, because each quote has its OWN pool. A buy-back funded by fees
    ///      collected on the USDC pool has to be spent on the USDC pool; routing it through native
    ///      would pay two sets of pool fees to end up where it started.
    /// @dev FIVE SLOTS, packed so the two processors each touch two of them: the buffers in slot 0, and
    ///      the cooldown marker each one dirties anyway sharing slot 1 with the first wall — which is
    ///      why that wall costs no extra slot at all, and only the second takes one of its own.
    struct QuoteBuffers {
        // --- slot 0 ---
        /// @dev Accrued from the burn allocation, awaiting a `processBurn` buy-back-and-burn on this
        ///      quote's pool. Held in the token's own balance (native or ERC20); the rest of that
        ///      balance, minus this and `liquidityPending`, is stray and `sweepStrayEth` routes it back
        ///      into the earnings split.
        uint128 burnPending;
        /// @dev Accrued from the liquidity allocation, awaiting a `processLiquidity` single-sided add on
        ///      this quote's pool. Excluded from the stray sweep for the same reason.
        uint128 liquidityPending;
        // --- slot 1 ---
        /// @dev `block.number` of the last `processBurn` for this quote — its once-per-block cooldown.
        uint48 lastBurnBlock;
        /// @dev `block.number` of the last `processLiquidity` for this quote.
        uint48 lastLiquidityBlock;
        /// @dev Position-manager NFT id of the most recently USED single-sided wall on this quote's
        ///      pool. `processLiquidity` tops it up instead of minting a fresh one whenever its range
        ///      still sits entirely below the current price and close to it. Zero means "no wall yet".
        ///      `uint112` because the position manager's id is a sequential counter from 1.
        uint112 wall0Id;
        /// @dev Lower tick of `wall0Id`'s range — the wall's top price. The upper tick is not kept: it
        ///      decides nothing here, and the position manager sizes a top-up from the position's own
        ///      recorded range.
        int24 wall0TickLower;
        // --- slot 2 ---
        /// @dev Second-most recently used wall, same shape. Two entries, kept most-recently-used first,
        ///      because a price that dips and then recovers leaves the PREVIOUS wall as the only one
        ///      still below the price — a one-entry memory would mint on every such zigzag.
        uint112 wall1Id;
        /// @dev Lower tick of `wall1Id`'s range.
        int24 wall1TickLower;
        // --- slots 3-4 ---
        /// @dev Accrued from the dividends allocation on THIS quote, per payout asset (same index as
        ///      `dividendAssets`), awaiting a `processDividends(i, quote, …)` that turns it into that
        ///      asset — on this quote's own pool for a self-token payout, through the registry for
        ///      anything else, or as-is when the payout IS this quote. Unused at index 0: native
        ///      dividends live on `DivAsset.pendingNative`, the machine every venue shares.
        uint128[MAX_DIVIDEND_ASSETS] dividendPending;
    }

    /// @notice Per-quote earnings buffers and wall memory, indexed exactly as `quotes` is. Entries at or
    ///         beyond `quoteCount` are unused and must never be read.
    QuoteBuffers[MAX_QUOTES] internal quoteBuffers;

    // Reentrancy: `processBurn` and `processLiquidity` share the transient `nonReentrant` lock that
    // `RealmTaxableToken` inherits for `sweepStrayEth` (they make external calls that pass through
    // `RealmSwapHook`/the fee handler and could reenter). The hot-path `accrueFees` deliberately does
    // NOT take the lock, so fee accrual during a buy-back still works.

    //////////////////////// Events & errors //////////////////////

    /// @notice Emitted immediately BEFORE `processBurn`'s buy-back swap, as a precursor marker.
    /// @dev The buy-back is an ordinary pool swap, so `RealmSwapHook` emits a normal `RealmSwapBuy`
    ///      carrying `tx.origin` — the keeper that triggered the call, not a trader. Without a marker an
    ///      indexer credits that keeper with a buy it never made: the tokens go to this contract and are
    ///      burned in the same call. Emitting BEFORE the swap is what makes it usable — the indexer can
    ///      flag the buy as protocol-internal as it arrives, whereas `CreatorTaxBurn` lands after the
    ///      swap, once the PnL update has already been applied. Mirrors the V2 swap-back, which is
    ///      pre-flagged by the token's transfer to the pair.
    /// @param quote The pool the buy-back swaps on, and the currency `amountIn` is in: `address(0)` for
    ///        native (the precursor of a `RealmSwapBuy`), an ERC20 otherwise (of a `RealmQuoteSwapBuy`).
    event BuyBackInitiated(address indexed quote, uint256 amountIn);

    /// @notice Emitted immediately BEFORE the buy-back swap that funds a SELF-TOKEN dividend pot. Same
    ///         job as `BuyBackInitiated`, for the same reason: the swap is an ordinary pool swap, so
    ///         `RealmSwapHook` emits a `RealmSwapBuy` carrying `tx.origin` — the keeper that called
    ///         `processDividends` — and without a precursor marker an indexer credits that keeper with a
    ///         buy it never made. Kept as its own event rather than reusing `BuyBackInitiated` so the two
    ///         protocol buy-backs stay distinguishable off-chain (one shrinks supply, one pays holders).
    /// @param quote Same as `BuyBackInitiated`'s: the pool swapped on and the currency of `amountIn`.
    event DividendBuyBackInitiated(address indexed quote, uint256 amountIn);

    /// @notice A quote route was given, or found already registered, in a venue the registry cannot
    ///         walk backwards (only V4 routes can be), for a quote a dividends leg has to be bought
    ///         out of — or a route was given for a quote that uses none (see `_registerQuoteRoutes`).
    error QuoteRouteUnsupported();
    error NothingToBurn();

    /// @notice The buy-back router call reverted — a missed `minTokensOut`, or an unswappable pool.
    error BuyBackFailed();
    error NothingToAdd();
    error ProcessCooldown();

    //////////////////////// EXTENSIONS //////////////////////

    /// @notice The `RealmEarningsLogicUniV4` extension `processBurn` / `processLiquidity` execute in,
    ///         against this token's own storage.
    /// @dev A SECOND extension beside `dividendLogic()`, not a replacement: once every buffer is keyed
    ///      by quote the two halves no longer fit in one contract under EIP-170. They are peers — same
    ///      base, same layout, neither delegates to the other.
    function earningsLogic() public view virtual returns (address);

    //////////////////////// PER-QUOTE VIEWS //////////////////////

    /// @notice Native accrued from the burn allocation, awaiting a `processBurn`. The index-0 entry of
    ///         `quoteBuffers`; a token quoted only against native has no other.
    /// @dev A view over the array rather than a field of its own. It used to be a plain public variable
    ///      and the getter is kept because public view surfaces are append-only — deployed readers call
    ///      it — but there is now ONE representation of the buffer, not a native special case beside a
    ///      general one.
    function burnPendingEth() external view returns (uint256) {
        return quoteBuffers[0].burnPending;
    }

    /// @notice Native accrued from the liquidity allocation, awaiting a `processLiquidity`. See
    ///         `burnPendingEth`.
    function liquidityPendingEth() external view returns (uint256) {
        return quoteBuffers[0].liquidityPending;
    }

    /// @notice `block.number` of the last native `processBurn`. See `burnPendingEth`.
    function lastBurnProcessBlock() external view returns (uint48) {
        return quoteBuffers[0].lastBurnBlock;
    }

    /// @notice `block.number` of the last native `processLiquidity`. See `burnPendingEth`.
    function lastLiquidityProcessBlock() external view returns (uint48) {
        return quoteBuffers[0].lastLiquidityBlock;
    }

    /// @notice What this token has accrued and not yet spent on ONE quote: the burn buffer, the
    ///         liquidity buffer, and when each was last processed.
    function quoteBufferOf(address quote)
        external
        view
        returns (uint256 burnPending, uint256 liquidityPending, uint48 lastBurn, uint48 lastLiquidity)
    {
        QuoteBuffers storage b = quoteBuffers[_quoteIndex(quote)];
        return (b.burnPending, b.liquidityPending, b.lastBurnBlock, b.lastLiquidityBlock);
    }

    //////////////////////// COMMITTED FUNDS //////////////////////

    /// @dev The native burn and liquidity buffers are committed, not stray, and neither is the dividend
    ///      money the base already accounts for.
    function _reservedNative() internal view override returns (uint256) {
        QuoteBuffers storage b = quoteBuffers[0];
        return super._reservedNative() + b.burnPending + b.liquidityPending;
    }

    /// @dev The same, for an ERC20 quote: what this token holds of it on the protocol's behalf. Without
    ///      this the owner's `rescueTokens(quote)` would drain a quote's buy-back and liquidity buffers
    ///      — money already committed to the token's holders and its pool depth.
    function _reservedAsset(address asset) internal view override returns (uint256) {
        uint256 reserved = super._reservedAsset(asset);
        uint8 idx = _quoteIndexPlusOne[asset];
        if (idx == 0) return reserved;
        QuoteBuffers storage b = quoteBuffers[idx - 1];
        reserved += b.burnPending + b.liquidityPending;
        uint256 n = dividendAssetCount;
        for (uint256 i; i < n; ++i) {
            reserved += b.dividendPending[i];
        }
        return reserved;
    }

    /// @notice What of `quote` this token has accrued for holder dividends and not yet converted, per
    ///         payout asset (same index as `dividendAssets`). All zero for the native quote, whose
    ///         buffers are `dividendAssets(i).pendingNative`.
    function quoteDividendPending(address quote) external view returns (uint128[MAX_DIVIDEND_ASSETS] memory) {
        return quoteBuffers[_quoteIndex(quote)].dividendPending;
    }

    //////////////////////// LIQUIDITY-WALL MEMORY //////////////////////

    /// @notice The single-sided walls this token remembers on its NATIVE pool, most-recently-used first.
    ///         See `getLiquidityWalls(address)`.
    function getLiquidityWalls() public view returns (uint256[2] memory ids, int24[2] memory tickLowers) {
        return _walls(0);
    }

    /// @notice The single-sided walls this token remembers on ONE quote's pool, most-recently-used
    ///         first: their position-manager NFT ids and lower ticks. A zero id is an empty entry.
    ///         Positions this token minted but has since forgotten are still owned by it and still pool
    ///         depth — only the two entries here are candidates for a top-up.
    /// @dev One packed view rather than four generated getters: on this contract, which sits close to
    ///      the EIP-170 limit, the getters cost more bytecode than the reuse path they describe.
    function getLiquidityWalls(address quote) public view returns (uint256[2] memory ids, int24[2] memory tickLowers) {
        return _walls(_quoteIndex(quote));
    }

    /// @dev Shared body of the two `getLiquidityWalls` overloads.
    function _walls(uint256 quoteIndex) internal view returns (uint256[2] memory ids, int24[2] memory tickLowers) {
        QuoteBuffers storage b = quoteBuffers[quoteIndex];
        ids = [uint256(b.wall0Id), uint256(b.wall1Id)];
        tickLowers = [b.wall0TickLower, b.wall1TickLower];
    }

    /// @dev Moves the wall that just took the deposit to the front of that quote's two-entry memory: a
    ///      repeat of the most recent one changes nothing, the second entry is promoted past the first,
    ///      and anything else is a fresh mint that evicts the older of the two. Most-recently-USED order
    ///      is what keeps a wall the price keeps returning to from being evicted by a mint it sat out.
    function _recordUsedWall(uint256 quoteIndex, uint256 id, int24 tickLower) internal {
        QuoteBuffers storage b = quoteBuffers[quoteIndex];
        (uint112 id0, int24 lower0) = (b.wall0Id, b.wall0TickLower);
        if (id == id0) return;

        // One shift covers both remaining cases: if `id` was the second entry this swaps the two, and if
        // it is a fresh mint this evicts the older one.
        (b.wall1Id, b.wall1TickLower) = (id0, lower0);
        // Safe: the position manager's id is a counter incremented once per mint, from 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        (b.wall0Id, b.wall0TickLower) = (uint112(id), tickLower);
    }
}
