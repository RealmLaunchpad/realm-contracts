// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmTaxableTokenUniV4Base, IRealmV4Graduator} from "src/tokens/RealmTaxableTokenUniV4Base.sol";
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {IRealmDividendSwapRegistry} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
// Self-aliased so the `chain-*` recipes can import-swap it for the target chain's pool constants.
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {IRealmUniV4LiquidityAdder, WallParams} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesRobinhood{Mainnet,Testnet}.
import {DeploymentAddressesRobinhoodMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @title RealmTaxableTokenUniV4
/// @notice ERC20 token implementation with time-limited buy/sell taxes enforced via Uniswap V4 hooks.
/// @dev Extends `RealmTaxableTokenUniV4Base` (tax config + earnings split + the V4 buy-back primitive).
///      Tax accounting on swaps lives in `RealmSwapHook`; the token exposes the tax config via
///      `getTaxConfig()`. The earnings-allocation burn bucket is buffered here as ETH
///      (`burnPendingEth`) and processed out-of-band by `processBurn`.
/// @dev The out-of-band keeper entry points live here too: `processBurn` and `processLiquidity` below,
///      and the dividend ones inherited from `DividendDistributionLogic` plus the quote overload below.
///      Nothing on the swap hot path reaches them.
contract RealmTaxableTokenUniV4 is RealmTaxableTokenUniV4Base {
    using SafeERC20 for IERC20;

    //////////////////////////////////////////////////////

    /// @notice Creates a new RealmTaxableTokenUniV4 instance which will be used as implementation for clones
    /// @dev Token configuration is set during initialization, not in constructor.
    constructor() RealmToken() {
        require(block.chainid == DeploymentAddresses.BLOCKCHAIN_ID, "configuration for wrong chainId");
    }

    /// @notice Initializes the token clone with its tax configuration. Anti-sniper protection is
    ///         enabled iff `antiSniperCfg` opts in (`protectionWindowSeconds != 0`); pass an all-zero
    ///         config for a tax-only token.
    /// @param params Shared token initialization parameters
    /// @param taxCfg Tax configuration (buy/sell bps, window, optional launch-tax decay)
    /// @param antiSniperCfg Anti-sniper caps + window config (validated upstream in the factory)
    function initialize(
        IRealmToken.InitializeParams memory params,
        TaxConfigs memory taxCfg,
        AntiSniperConfigs memory antiSniperCfg
    ) external virtual initializer {
        _initializeRealmTaxableToken(params, taxCfg);
        _initializeAntiSniper(antiSniperCfg);
    }

    //////////////////////// BURN //////////////////////

    /// @notice Buys back tokens with `quote`'s accrued burn buffer and burns them, reducing total
    ///         supply. Keeper-gated, once per block PER QUOTE, spending at most `_maxSpend` of the
    ///         buffer; the remainder stays buffered.
    /// @param quote Which of the token's pools to buy back on — `address(0)` for the native one. The
    ///        buffer, the cooldown and the pool are all that quote's own: fees collected on one pool are
    ///        spent on that pool, never round-tripped through another.
    /// @param minTokensOut Slippage floor — the minimum tokens the buy-back must yield, or the swap
    ///        reverts. Callers should set this from the current price; a value of 0 invites sandwiching.
    /// @dev The buy-back is an ordinary pool swap, so the hook charges its usual LP fee (and, inside the
    ///      launch tax window, tax — a fraction of which loops back into this same buffer for the next
    ///      call). This is accepted rather than special-casing the audited hook.
    function processBurn(address quote, uint256 minTokensOut) public nonReentrant {
        uint256 qi = _quoteIndex(quote);
        QuoteBuffers storage buf = quoteBuffers[qi];

        // Keeper-gated: the caller supplies the floor, so a permissionless caller could set it to zero
        // around their own price manipulation and keep almost the whole spend. See `RealmKeepersRegistry`.
        _requireKeeper();
        // Once per block + capped spend: bounds what a sandwich can extract per manipulated block once
        // the caller can no longer choose the floor. It is a second bound, not the first one.
        require(block.number > buf.lastBurnBlock, ProcessCooldown());
        buf.lastBurnBlock = uint48(block.number);

        uint256 pending = buf.burnPending;
        require(pending > 0, NothingToBurn());
        uint256 amountIn = _maxSpend(quote, pending);
        // forge-lint: disable-next-line(unsafe-typecast)
        buf.burnPending = uint128(pending - amountIn);

        address hook = IRealmV4Graduator(graduator).hookFor(quote);
        uint256 balanceBefore = balanceOf(address(this));
        uint256 quoteBefore = _quoteHoldings(quote);
        uint256 reservedBefore = _quoteReserved(quote);
        // Precursor marker: must stay BEFORE the swap so indexers can classify the resulting
        // `RealmSwapHook.RealmSwapBuy` as a protocol buy-back rather than a trade by `tx.origin`.
        emit BuyBackInitiated(quote, amountIn);
        require(_buyBackTokens(hook, quote, amountIn, minTokensOut), BuyBackFailed());
        uint256 tokensBought = balanceOf(address(this)) - balanceBefore;

        // Whatever the pool did not take came back with the router's `SWEEP` and stays earmarked for
        // burning: without this the unspent remainder rejoins the stray pool and `sweepStrayEth`
        // re-splits it into the fund / dividend / liquidity buckets, spending an allocation meant for
        // burning. See `_spent` for why it is measured as balance AND reserves rather than either alone.
        uint256 spent = _spent(quote, quoteBefore, reservedBefore);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (spent < amountIn) buf.burnPending += uint128(amountIn - spent);

        if (tokensBought > 0) _burn(address(this), tokensBought);
        // Reports what the pool ACTUALLY took, as `processLiquidity` does with `added`.
        emit CreatorTaxBurn(quote, spent, tokensBought);
    }

    /// @notice The native-pool buy-back, for callers that predate quotes.
    function processBurn(uint256 minTokensOut) external {
        processBurn(address(0), minTokensOut);
    }

    //////////////////////// LIQUIDITY //////////////////////

    /// @notice Deposits `quote`'s accrued liquidity buffer as a single-sided position just below the
    ///         current price on that quote's pool — a protective bid wall. Both placing and reusing run
    ///         through the shared `RealmUniV4LiquidityAdder`: this token only keeps the memory of the
    ///         two walls it most recently used on that pool and the policy
    ///         (`LIQUIDITY_WALL_TICK_WIDTH`, `LIQUIDITY_WALL_REUSE_MAX_GAP`) that decides between
    ///         topping one up and minting a fresh one.
    ///         Keeper-gated and off the swap hot path, mirroring `processBurn`. Positions are held by
    ///         this token and never withdrawn, so they are permanent pool depth. Spends at most
    ///         `_maxSpend` of the buffer, once per block per quote: a fresh wall is placed at the LIVE
    ///         tick, so a manipulator could pump the price and dump into a wall placed at the inflated
    ///         level — the cap and cooldown bound that per block (each needs a fresh, fee-paying pump).
    /// @dev Runs out-of-band because `modifyLiquidity` cannot execute inside the swap hook's pool lock.
    ///      Batches many small accruals into one add. Guarded by the shared `nonReentrant` lock (both
    ///      paths route through the position manager and the pool).
    function processLiquidity(address quote) public nonReentrant {
        uint256 qi = _quoteIndex(quote);
        QuoteBuffers storage buf = quoteBuffers[qi];

        // Keeper-gated, and this one has NO slippage parameter at all: the wall is placed at whatever
        // price the caller has arranged. See `RealmKeepersRegistry`.
        _requireKeeper();
        require(block.number > buf.lastLiquidityBlock, ProcessCooldown());
        buf.lastLiquidityBlock = uint48(block.number);

        uint256 pending = buf.liquidityPending;
        require(pending > 0, NothingToAdd());
        uint256 amountIn = _maxSpend(quote, pending);
        // forge-lint: disable-next-line(unsafe-typecast)
        buf.liquidityPending = uint128(pending - amountIn);

        uint256 added = _addWall(qi, quote, amountIn);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (added < amountIn) buf.liquidityPending += uint128(amountIn - added);
    }

    /// @notice The native-pool wall, for callers that predate quotes.
    function processLiquidity() external {
        processLiquidity(address(0));
    }

    /// @dev Places or tops up `quote`'s wall with `amountIn` and reports what the pool actually took.
    ///      Its own function so `processLiquidity` stays inside the stack limit without `via_ir`.
    function _addWall(uint256 qi, address quote, uint256 amountIn) private returns (uint256 added) {
        address adder = IRealmV4Graduator(graduator).LIQUIDITY_ADDER();

        // The adder needs the position manager's `onlyIfApproved` to top up a wall this token owns.
        // Granted on demand rather than once: it self-heals if the graduator ever points at a different
        // adder — where a one-shot grant would leave `processLiquidity` reverting on every reusable
        // wall. The adder is already trusted with the funds handed to it, cannot decrease, burn or
        // transfer a position, and comes from the same graduator that names the hook mediating every
        // swap. Read-then-write rather than an unconditional `setApprovalForAll`: the SSTORE is
        // same-value after the first call but the `ApprovalForAll` LOG is not free, and re-emitting it
        // on every single `processLiquidity` is noise every indexer has to filter.
        if (!IERC721(UNIV4_POSITION_MANAGER).isApprovedForAll(address(this), adder)) {
            IERC721(UNIV4_POSITION_MANAGER).setApprovalForAll(adder, true);
        }
        // The ERC20 leg is PULLED by the adder, so it needs an allowance sized to this call.
        if (quote != address(0)) IERC20(quote).forceApprove(adder, amountIn);

        uint256 before = _quoteHoldings(quote);
        uint128 liquidity = _placeWall(qi, quote, amountIn, adder);

        // ⚠️ CLAMPED, not a plain subtraction. The balance can come back HIGHER than it went out: the
        // top-up path is `INCREASE_LIQUIDITY_FROM_DELTAS` + `TAKE_PAIR`, and v4 folds a position's
        // `feesAccrued` into those deltas, so a reused wall whose accrued fees exceed the principal
        // being added returns more than `amountIn`. Unreachable while `UniswapV4PoolConstants.LP_FEE`
        // is 0 (the hook charges the fee instead, so these positions accrue nothing), but a non-zero or
        // dynamic pool fee would turn a bare subtraction into a panic that bricks `processLiquidity` on
        // the reuse path until the price moved far enough to force a fresh mint. Clamping degrades that
        // into "nothing was placed": the full amount is re-earmarked and the surplus becomes stray —
        // which `sweepStrayEth` routes back into the split on the native pool, but which on an ERC20
        // quote only `rescueTokens` reaches (to the owner). Revisit if the pool fee ever becomes non-zero.
        uint256 after_ = _quoteHoldings(quote);
        added = before > after_ ? before - after_ : 0;

        // Shared event signature; reports what the pool ACTUALLY took, as the V2 processor does. The
        // token side is always 0 for a single-sided quote wall.
        emit LiquidityAdded(quote, added, 0, liquidity);
    }

    /// @dev The adder call itself, split out of `_addWall` purely to keep both inside the stack limit
    ///      without `via_ir`. The NFT and the remainder both return to this token — permanent depth, and
    ///      whatever was not placed stays earmarked — and the adder reports which position took the
    ///      deposit so the two-entry memory can be updated.
    function _placeWall(uint256 qi, address quote, uint256 amountIn, address adder)
        private
        returns (uint128 liquidity)
    {
        (uint256[2] memory ids, int24[2] memory tickLowers) = _walls(qi);
        uint256 usedId;
        int24 usedTickLower;
        (liquidity, usedId, usedTickLower) = IRealmUniV4LiquidityAdder(adder)
        .addOrTopUpSingleSided{value: quote == address(0) ? amountIn : 0}(
            UniswapV4PoolConstants.realmPoolKey(address(this), quote, IRealmV4Graduator(graduator).hookFor(quote)),
            WallParams({
                currency: Currency.wrap(quote),
                amount: amountIn,
                tickWidth: LIQUIDITY_WALL_TICK_WIDTH,
                reuseMaxGap: LIQUIDITY_WALL_REUSE_MAX_GAP,
                receiver: address(this)
            }),
            ids,
            tickLowers
        );
        // A zero id means nothing was placed and the deposit came back — no wall to record.
        if (usedId != 0) _recordUsedWall(qi, usedId, usedTickLower);
    }

    //////////////////////// QUOTE-DENOMINATED DIVIDENDS //////////////////////

    /// @notice `processDividends` for a buffer held in one of this token's QUOTES: converts what asset
    ///         `assetIndex` has accrued from earnings on `quote`'s pool into that asset, credits it to
    ///         the holders, and pushes `holders` their accruals. `quote == address(0)` is the shared
    ///         native machine, exactly `processDividends(uint8,true,uint256,address[])`.
    /// @dev What differs from the native path, and why:
    ///      - Like the native path, no funding floor: the keeper pays the gas and decides when a buffer
    ///        is worth converting, as it does for `processBurn(quote, …)`. This path never had one —
    ///        `DIVIDEND_THRESHOLD` is native-denominated and means nothing in a currency the creator
    ///        picked — and the native path has since dropped its own.
    ///      - The per-call cap is `_maxSpend`'s FRACTION of the buffer, for the same units reason, and
    ///        only on a leg that SWAPS. A payout that IS the quote has no swap: nothing to sandwich, the
    ///        whole buffer credits at once.
    ///      - A leg that swaps is keeper-only, ALWAYS — the staleness hatch never opens it, because
    ///        without a threshold there is nothing that evidences an absent keeper rather than a quiet
    ///        token, and a zero-floor conversion handed to anyone is the sandwich the gate exists for.
    ///        The passthrough keeps the hatch: it moves no money through a pool.
    ///      - NO treasury sweep for a dead pool: a quote pool nobody can swap on strands that quote's
    ///        buffer, as it strands `processBurn`'s. The registry legs pivot through native, whose
    ///        liquidity the payout asset's own route already vouches for.
    ///      - The once-per-block cooldown is the ASSET's, shared with the native leg and the other
    ///        quotes: one conversion of asset `i` per block, whichever buffer feeds it.
    /// @param minOut Slippage floor in the PAYOUT asset's units, checked on the final amount however
    ///        many pools the conversion crosses. Ignored by the passthrough.
    function processDividends(uint8 assetIndex, address quote, uint256 minOut, address[] calldata holders)
        external
        nonReentrant
        nonReentrantDividends
    {
        if (quote == address(0)) {
            _processDividends(assetIndex, true, minOut, holders);
            return;
        }
        _processQuoteDividends(assetIndex, quote, minOut, holders);
    }

    /// @dev The quote path's body. Mirrors `_processDividends`'s shape — gate, fund once per block,
    ///      credit, push, then the error that tells a keeper what to do next — over `quoteBuffers`.
    function _processQuoteDividends(uint8 assetIndex, address quote, uint256 minOut, address[] calldata holders)
        private
    {
        require(assetIndex < _dividendAssetCount(), DividendAssetOutOfRange());
        DivAsset storage asset = dividendAssets[assetIndex];
        require(asset.lastDistribution != 0, DividendsNotActive());
        address payout = asset.token;
        if (payout != quote || !dividendsStale(assetIndex)) _requireKeeper();

        bool cooldown = block.number <= asset.lastProcessBlock;
        uint256 spend;
        uint256 spent;
        uint256 out;
        if (!cooldown) (spend, spent, out) = _fundFromQuote(assetIndex, quote, payout, minOut);
        if (out != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            asset.lastProcessBlock = uint40(block.number);
            _creditDividends(assetIndex, out);
            emit DividendsFunded(quote, payout, spent, out);
        }

        if (holders.length != 0) {
            _pushDividends(assetIndex, holders);
        } else if (cooldown) {
            revert DividendProcessCooldown();
        } else if (spend == 0) {
            revert BelowDividendThreshold();
        } else if (out == 0) {
            revert DividendConversionFailed();
        }
    }

    /// @dev Debits asset `i`'s buffer on `quote` — the whole of it for a passthrough, `_maxSpend`'s
    ///      slice for a leg that swaps — converts it, and re-earmarks whatever the conversion did not
    ///      consume. Debit-first, so the reserve a mid-swap accrual is measured against already excludes
    ///      the spend; re-earmarked with `+=` on the live slot, so an accrual that landed during the swap
    ///      (`accrueFees` takes no lock) survives the write.
    /// @return spend what was attempted, 0 when nothing was buffered.
    /// @return spent what the conversion consumed; the rest is back on the buffer.
    /// @return out payout-asset units actually acquired, 0 when the conversion did not happen.
    function _fundFromQuote(uint256 i, address quote, address payout, uint256 minOut)
        private
        returns (uint256 spend, uint256 spent, uint256 out)
    {
        uint128[MAX_DIVIDEND_ASSETS] storage pending = quoteBuffers[_quoteIndex(quote)].dividendPending;
        uint256 buffered = pending[i];
        if (buffered == 0) return (0, 0, 0);
        spend = payout == quote ? buffered : _maxSpend(quote, buffered);
        // forge-lint: disable-next-line(unsafe-typecast)
        pending[i] = uint128(buffered - spend);
        (out, spent) = _acquireFromQuote(quote, payout, spend, minOut);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (spent < spend) pending[i] += uint128(spend - spent);
    }

    /// @dev Turns `amountIn` of `quote` into `payout`. Three shapes:
    ///      - `payout == quote`: nothing to do, the buffer already IS the payout.
    ///      - `payout == this token`: a buy-back on `quote`'s own pool, the `processBurn` primitive; a
    ///        partial fill reports what the pool actually took.
    ///      - anything else: the registry, which walks `quote`'s route backwards to native and the
    ///        payout's forward (or stops at native). A LOW-LEVEL call for the same reason the native leg
    ///        makes one: a registry revert must become "not converted", never a reverted distribution.
    ///        The registry consumes the whole `amountIn` or reverts, so `spent` is all or nothing.
    /// @return out payout units received, measured as a balance delta.
    /// @return spent quote units the conversion consumed.
    function _acquireFromQuote(address quote, address payout, uint256 amountIn, uint256 minOut)
        private
        returns (uint256 out, uint256 spent)
    {
        if (payout == quote) return (amountIn, amountIn);
        if (payout == address(this)) {
            uint256 balanceBefore = balanceOf(address(this));
            uint256 quoteBefore = _quoteHoldings(quote);
            uint256 reservedBefore = _quoteReserved(quote);
            // Precursor marker, BEFORE the swap: see the native override below.
            emit DividendBuyBackInitiated(quote, amountIn);
            if (!_buyBackTokens(IRealmV4Graduator(graduator).hookFor(quote), quote, amountIn, minOut)) return (0, 0);
            out = balanceOf(address(this)) - balanceBefore;
            if (out == 0) return (0, 0);
            return (out, _spent(quote, quoteBefore, reservedBefore));
        }
        // Fail CLOSED against a codeless registry, as `_swapNativeToDividendAsset` does.
        if (DIVIDEND_SWAP_REGISTRY.code.length == 0) return (0, 0);
        IERC20(quote).forceApprove(DIVIDEND_SWAP_REGISTRY, amountIn);
        uint256 before = payout == address(0) ? address(this).balance : IERC20(payout).balanceOf(address(this));
        (bool ok,) = DIVIDEND_SWAP_REGISTRY.call(
            abi.encodeCall(
                IRealmDividendSwapRegistry.swapAssetToAsset, (quote, payout, amountIn, minOut, address(this))
            )
        );
        if (!ok) {
            // No standing allowance to an upgradeable registry for a spend that never happened.
            IERC20(quote).forceApprove(DIVIDEND_SWAP_REGISTRY, 0);
            return (0, 0);
        }
        uint256 after_ = payout == address(0) ? address(this).balance : IERC20(payout).balanceOf(address(this));
        return (after_ - before, amountIn);
    }

    /// @dev Adds the SELF-TOKEN payout shape: a token paying dividends in itself buys itself back on its
    ///      own native pool — the same leg `_acquireFromQuote` runs for an ERC20 quote, with native as
    ///      the quote. Native and third-asset payouts fall through to the base.
    /// @dev Reports what the pool actually took: the base debits only that, so whatever a partial fill
    ///      handed back through the router's `SWEEP` stays on the dividend ledger instead of becoming
    ///      stray that `sweepStrayEth` would re-split into the burn / liquidity / fund buckets.
    function _acquireDividendAsset(address asset, uint256 nativeIn, uint256 minOut)
        internal
        override
        returns (uint256, uint256)
    {
        if (asset != address(this)) return super._acquireDividendAsset(asset, nativeIn, minOut);
        return _acquireFromQuote(address(0), address(this), nativeIn, minOut);
    }

    //////////////////////// CREATION-TIME CONFIGURATION //////////////////////

    /// @notice The multi-asset overload plus the routes of this token's ERC20 quotes. See
    ///         `RealmTaxableToken.initializeEarningsAllocation(uint16,uint16,uint16,address[],uint16[],bytes[],bytes[])`.
    function initializeEarningsAllocation(
        uint16 _burnBps,
        uint16 _dividendsBps,
        uint16 _liquidityBps,
        address[] calldata _dividendTokens,
        uint16[] calldata _dividendWeightsBps,
        bytes[] calldata _dividendRoutes,
        bytes[] calldata _quoteRoutes
    ) external override {
        require(msg.sender == tokenFactory, Unauthorized());
        _initializeEarningsAllocation(_burnBps, _dividendsBps, _liquidityBps);
        if (_dividendsBps != 0) {
            dividendAssetCount = _initializeDividends(_dividendTokens, _dividendWeightsBps, _dividendRoutes);
            hasDividends = true;
            _registerQuoteRoutes(_quoteRoutes);
        }
    }

    /// @dev Registers the route of every ERC20 quote a dividends leg has to be bought OUT of — one where
    ///      some payout asset is neither that quote itself nor this token. Only those: a route nobody
    ///      needs is a pool this token commits to for life for nothing. A quote that is itself a payout
    ///      asset already has its route from `_initializeDividends` (the registry holds ONE route per
    ///      asset, walked either way), so it is checked here but not registered again.
    /// @dev The registry can only walk a V4 route backwards, so anything else is refused HERE, at
    ///      creation, rather than failing every conversion out of that quote for the token's life.
    ///      `_quoteRoutes` is positional to `quotes` from index 1; a missing entry is empty, which the
    ///      registry reads as the permissionless V2 pair — and which therefore fails this venue check.
    ///      A non-empty entry for a quote that needs no route, or that is itself a payout asset, reverts
    ///      rather than being silently dropped.
    function _registerQuoteRoutes(bytes[] calldata routes) private {
        uint256 nq = quoteCount;
        uint256 na = dividendAssetCount;
        IRealmDividendSwapRegistry registry = IRealmDividendSwapRegistry(DIVIDEND_SWAP_REGISTRY);
        for (uint256 q = 1; q < nq; ++q) {
            address quote = quotes[q];
            bool needed;
            bool isPayout;
            for (uint256 i; i < na; ++i) {
                address a = dividendAssets[i].token;
                if (a == quote) isPayout = true;
                else if (a != address(this)) needed = true;
            }
            // A route this token would not register is one the creator believes is in use; refuse it.
            bool supplied = q - 1 < routes.length && routes[q - 1].length != 0;
            require(!supplied || (needed && !isPayout), QuoteRouteUnsupported());
            if (!needed) continue;
            bytes memory route =
                isPayout ? registry.routeOf(address(this), quote) : (supplied ? routes[q - 1] : bytes(""));
            require(DividendRouteLib.venue(route) == DividendRouteLib.VENUE_V4, QuoteRouteUnsupported());
            if (!isPayout) registry.registerRoute(quote, route);
        }
    }

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @inheritdoc RealmTaxableToken
    /// @dev Adds the V4 pool-manager pair check after shared init. The graduator is expected to
    ///      have set `pair == UNIV4_POOL_MANAGER` during `RealmToken._initializeRealmToken`; if not,
    ///      revert and roll back any earlier writes (storage updates already performed are
    ///      reverted with the rest of the tx, so ordering vs `_initializeTaxConfig` is irrelevant).
    function _initializeRealmTaxableToken(IRealmToken.InitializeParams memory params, TaxConfigs memory taxCfg)
        internal
        override
        onlyInitializing
    {
        super._initializeRealmTaxableToken(params, taxCfg);
        require(pair == UNIV4_POOL_MANAGER, "Invalid pair address");
    }

    /// @dev The burn slice accrues in whatever currency the pool that produced it is quoted in; the
    ///      buy-back-and-burn happens out-of-band in `processBurn`, on that same pool. Stays cheap (one
    ///      SSTORE into a slot the sibling slice shares) and consumes the slice fully — returns 0, so
    ///      nothing folds back to the fund wallets. Overrides the base fallback in `EarningsAllocation`.
    function _handleBurn(address asset, uint256 amount) internal override returns (uint256) {
        QuoteBuffers storage buf = quoteBuffers[_quoteIndex(asset)];
        uint256 updated = buf.burnPending + amount;
        require(updated <= type(uint128).max, DividendBufferOverflow());
        // forge-lint: disable-next-line(unsafe-typecast)
        buf.burnPending = uint128(updated);
        return 0;
    }

    /// @dev The liquidity slice, same shape: buffered per quote and deposited out-of-band by
    ///      `processLiquidity` as a single-sided wall on that quote's own pool.
    function _handleLiquidity(address asset, uint256 amount) internal override returns (uint256) {
        QuoteBuffers storage buf = quoteBuffers[_quoteIndex(asset)];
        uint256 updated = buf.liquidityPending + amount;
        require(updated <= type(uint128).max, DividendBufferOverflow());
        // forge-lint: disable-next-line(unsafe-typecast)
        buf.liquidityPending = uint128(updated);
        return 0;
    }

    /// @dev The dividends slice of ERC20-quoted earnings, buffered per quote AND per payout asset —
    ///      split by `dividendWeightsBps` here exactly as the native slice is split across
    ///      `pendingNative` — and converted out-of-band by `processDividends(i, quote, …)`. Two SSTOREs
    ///      at most (the three buffers pack into two slots), inside the router's gas budget.
    function _accrueQuoteDividends(address asset, uint256 amount) internal override returns (uint256) {
        uint256 n = dividendAssetCount;
        if (n == 0) return amount;
        uint128[MAX_DIVIDEND_ASSETS] storage pending = quoteBuffers[_quoteIndex(asset)].dividendPending;
        uint256 remaining = amount;
        for (uint256 i; i < n; ++i) {
            uint256 share = i + 1 == n ? remaining : amount * dividendWeightsBps[i] / DIVIDEND_BPS_TOTAL;
            remaining -= share;
            if (share == 0) continue;
            uint256 updated = uint256(pending[i]) + share;
            require(updated <= type(uint128).max, DividendBufferOverflow());
            // forge-lint: disable-next-line(unsafe-typecast)
            pending[i] = uint128(updated);
        }
        return 0;
    }

    //////////////////////// QUOTE HELPERS //////////////////////

    /// @dev Cap on what ONE call may spend out of a buffer.
    ///      - NATIVE keeps the absolute `MAX_EARNINGS_PER_PROCESS` it always had, per chain.
    ///      - An ERC20 quote gets a FRACTION of the buffer instead, because an absolute cap is
    ///        meaningless for a currency nobody calibrated it against: `MAX_EARNINGS_PER_PROCESS` is
    ///        denominated in the chain's native unit, and a creator picks their quote. A fraction needs
    ///        no calibration and does the same job — it bounds what a manipulated block can extract,
    ///        forcing a sandwich to re-pay its pump every block for a geometrically shrinking prize.
    /// @dev Either way this is the SECOND bound, not the first: the keeper gate is what actually stops a
    ///      caller choosing their own floor around their own manipulation.
    function _maxSpend(address quote, uint256 pending) internal pure returns (uint256) {
        if (quote != address(0)) {
            uint256 slice = pending * MAX_QUOTE_SPEND_BPS / 10_000;
            // A buffer too small to slice would otherwise never be spendable at all.
            return slice == 0 ? pending : slice;
        }
        return pending > MAX_EARNINGS_PER_PROCESS ? MAX_EARNINGS_PER_PROCESS : pending;
    }

    /// @dev This token's holdings of `quote`, native or ERC20.
    function _quoteHoldings(address quote) internal view returns (uint256) {
        return quote == address(0) ? address(this).balance : IERC20(quote).balanceOf(address(this));
    }

    /// @dev What of those holdings is committed to someone else.
    function _quoteReserved(address quote) internal view returns (uint256) {
        return quote == address(0) ? _reservedNative() : _reservedAsset(quote);
    }

    /// @dev What a swap actually consumed, measured as `(holdings drop) + (reserve growth)` rather than
    ///      either alone. A buy-back is a SWAP, so the hook's `accrueFees` lands earnings here mid-call:
    ///      that raises the holdings and the buffers together, and only the router's spend moves the two
    ///      apart. Arranged so neither side can underflow — reporting a spend of 0 merely re-earmarks
    ///      the whole amount, which is the safe direction.
    function _spent(address quote, uint256 holdingsBefore, uint256 reservedBefore) internal view returns (uint256) {
        uint256 lhs = holdingsBefore + _quoteReserved(quote);
        uint256 rhs = _quoteHoldings(quote) + reservedBefore;
        return lhs > rhs ? lhs - rhs : 0;
    }
}
