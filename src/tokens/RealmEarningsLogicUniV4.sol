// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmV4ExtensionBase} from "src/tokens/RealmV4ExtensionBase.sol";
import {IRealmV4Graduator} from "src/tokens/RealmTaxableTokenUniV4Base.sol";
// Self-aliased so the `chain-*` recipes can import-swap it for the target chain's pool constants.
import {UniswapV4PoolConstants as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {IRealmUniV4LiquidityAdder, WallParams} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {ERC20Burnable} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";

/// @title RealmEarningsLogicUniV4
/// @notice The extension `RealmTaxableTokenUniV4` `delegatecall`s its BUY-BACK and LIQUIDITY entry
///         points into: `processBurn` and `processLiquidity`, for any one of the token's quotes.
/// @dev Split from `RealmDividendLogicUniV4` because the two together no longer fit under EIP-170 once
///      every buffer is keyed by quote. They are peers, not a hierarchy: both share
///      `RealmV4ExtensionBase`, both add no storage, and `just check-dividend-layout` pins each one's
///      layout against the token's.
contract RealmEarningsLogicUniV4 is RealmV4ExtensionBase {
    using SafeERC20 for IERC20;

    //////////////////////// BURN (delegated from the token) //////////////////////

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

        address hook = IRealmV4Graduator(graduator).HOOK_ADDRESS();
        uint256 balanceBefore = balanceOf(address(this));
        uint256 quoteBefore = _quoteHoldings(quote);
        uint256 reservedBefore = _quoteReserved(quote);
        // Precursor marker: must stay BEFORE the swap so indexers can classify the resulting
        // `RealmSwapHook.RealmSwapBuy` as a protocol buy-back rather than a trade by `tx.origin`.
        emit BuyBackInitiated(amountIn);
        require(_buyBackTokens(hook, quote, amountIn, minTokensOut), BuyBackFailed());
        uint256 tokensBought = balanceOf(address(this)) - balanceBefore;

        // Whatever the pool did not take came back with the router's `SWEEP` and stays earmarked for
        // burning: without this the unspent remainder rejoins the stray pool and `sweepStrayEth`
        // re-splits it into the fund / dividend / liquidity buckets, spending an allocation meant for
        // burning. See `_spent` for why it is measured as balance AND reserves rather than either alone.
        uint256 spent = _spent(quote, quoteBefore, reservedBefore);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (spent < amountIn) buf.burnPending += uint128(amountIn - spent);

        // An EXTERNAL self-call, not `_burn`. `_burn` would drag `RealmToken._update` — the anti-sniper
        // caps and the dividend share tracking — into this extension's bytecode, and at ~7.4 KB that is
        // room it does not have under EIP-170 (the whole reason the cold half lives here). Routing
        // through the token's own `burn()` keeps the identical `Transfer(token, 0, amount)` semantics
        // with the code on the side that already carries it: under `delegatecall` `address(this)` IS the
        // token, so `msg.sender` is the token and `ERC20Burnable.burn` burns exactly this balance.
        if (tokensBought > 0) ERC20Burnable(address(this)).burn(tokensBought);
        // Reports what the pool ACTUALLY took, as `processLiquidity` does with `added`.
        emit CreatorTaxBurn(spent, tokensBought);
    }

    /// @notice The native-pool buy-back, for callers that predate quotes.
    function processBurn(uint256 minTokensOut) external {
        processBurn(address(0), minTokensOut);
    }

    //////////////////////// LIQUIDITY (delegated from the token) //////////////////////

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
        // into "nothing was placed": the full amount is re-earmarked and the surplus becomes stray,
        // which the sweep routes correctly.
        uint256 after_ = _quoteHoldings(quote);
        added = before > after_ ? before - after_ : 0;

        // Shared event signature; reports what the pool ACTUALLY took, as the V2 processor does. The
        // token side is always 0 for a single-sided quote wall.
        emit LiquidityAdded(added, 0, liquidity);
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
            UniswapV4PoolConstants.realmPoolKey(address(this), quote, IRealmV4Graduator(graduator).HOOK_ADDRESS()),
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
