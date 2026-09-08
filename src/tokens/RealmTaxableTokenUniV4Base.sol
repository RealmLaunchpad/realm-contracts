// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {RealmUniv4BuyBacks} from "src/tokens/RealmUniv4BuyBacks.sol";

/// @notice Minimal view onto the V4 graduator: the hook it paired the token's pool with (to rebuild the
///         pool key) and the shared liquidity adder it deployed (to mint the single-sided ETH wall).
interface IRealmV4Graduator {
    function HOOK_ADDRESS() external view returns (address);
    function LIQUIDITY_ADDER() external view returns (address);
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
    /////////////////////////// pure storage ///////////////////////

    /// @notice ETH accrued from the burn allocation, awaiting a `processBurn` buy-back-and-burn. Held in
    ///         the token's own balance; the rest of the balance (minus this and `liquidityPendingEth`) is
    ///         stray ETH that `sweepStrayEth` routes back into the earnings split.
    uint256 public burnPendingEth;

    /// @notice ETH accrued from the liquidity allocation, awaiting a `processLiquidity` single-sided add.
    ///         Held in the token's own balance and, like `burnPendingEth`, excluded from the stray sweep.
    uint256 public liquidityPendingEth;

    /// @notice `block.number` of the last `processBurn` — enforces its once-per-block cooldown
    ///         (see `MAX_EARNINGS_PER_PROCESS`). Packed with `lastLiquidityProcessBlock`.
    uint48 public lastBurnProcessBlock;

    /// @notice `block.number` of the last `processLiquidity` — enforces its once-per-block cooldown.
    uint48 public lastLiquidityProcessBlock;

    /// @notice Position-manager NFT id of the most recently USED single-sided ETH wall.
    ///         `processLiquidity` tops this position up instead of minting a fresh one whenever its range
    ///         still sits entirely below the current price and close to it. Zero id means "no wall yet".
    /// @dev `uint112` so this and its lower tick fill out the tail of the block-marker slot, which
    ///      `processLiquidity` already dirties on every call — the first entry therefore costs no extra
    ///      slot at all, and only the second one below takes a slot of its own. The position manager's id
    ///      is a sequential counter, so 2^112 is not a bound anything can reach.
    uint112 internal liquidityWall0Id;

    /// @notice Lower tick of `liquidityWall0Id`'s range (the wall's top price — ETH-only positions live
    ///         at ticks ABOVE the current one, since the pair is `(ETH, token)`). The upper tick is not
    ///         kept: it decides nothing here, and the position manager sizes the top-up from the
    ///         position's own recorded range.
    int24 internal liquidityWall0TickLower;

    /// @notice Second-most recently used wall, same shape as `liquidityWall0Id`. Two entries, kept
    ///         most-recently-used first, because a price that dips and then recovers leaves the PREVIOUS
    ///         wall as the only one still below the price — a one-entry memory would mint a fresh
    ///         position on every such zigzag.
    uint112 internal liquidityWall1Id;

    /// @notice Lower tick of `liquidityWall1Id`'s range.
    int24 internal liquidityWall1TickLower;

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
    event BuyBackInitiated(uint256 ethIn);

    /// @notice Emitted immediately BEFORE the buy-back swap that funds a SELF-TOKEN dividend pot. Same
    ///         job as `BuyBackInitiated`, for the same reason: the swap is an ordinary pool swap, so
    ///         `RealmSwapHook` emits a `RealmSwapBuy` carrying `tx.origin` — the keeper that called
    ///         `processDividends` — and without a precursor marker an indexer credits that keeper with a
    ///         buy it never made. Kept as its own event rather than reusing `BuyBackInitiated` so the two
    ///         protocol buy-backs stay distinguishable off-chain (one shrinks supply, one pays holders).
    event DividendBuyBackInitiated(uint256 ethIn);

    /// @dev The burn and liquidity buffers are committed ETH, not stray, and neither is the dividend
    ///      money the base already accounts for.
    function _reservedNative() internal view override returns (uint256) {
        return super._reservedNative() + burnPendingEth + liquidityPendingEth;
    }
}
