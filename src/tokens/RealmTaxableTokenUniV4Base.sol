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

    error NothingToBurn();

    /// @notice The buy-back router call reverted — a missed `minTokensOut`, or an unswappable pool.
    error BuyBackFailed();
    error NothingToAdd();
    error ProcessCooldown();

    /// @dev The burn and liquidity buffers are committed ETH, not stray, and neither is the dividend
    ///      money the base already accounts for.
    function _reservedNative() internal view override returns (uint256) {
        return super._reservedNative() + burnPendingEth + liquidityPendingEth;
    }

    //////////////////////// LIQUIDITY-WALL MEMORY //////////////////////

    /// @notice The single-sided ETH walls this token remembers, most-recently-used first: their
    ///         position-manager NFT ids and lower ticks. A zero id is an empty entry. Positions this token
    ///         minted but has since forgotten are still owned by it and still pool depth — only the two
    ///         entries here are candidates for a top-up.
    /// @dev One packed view rather than four generated getters: on this contract, which sits close to the
    ///      EIP-170 limit, the getters cost more bytecode than the reuse path they describe.
    function getLiquidityWalls() public view returns (uint256[2] memory ids, int24[2] memory tickLowers) {
        ids = [uint256(liquidityWall0Id), uint256(liquidityWall1Id)];
        tickLowers = [liquidityWall0TickLower, liquidityWall1TickLower];
    }

    /// @dev Moves the wall that just took the ETH to the front of the two-entry memory: a repeat of the
    ///      most recent one changes nothing, the second entry is promoted past the first, and anything
    ///      else is a fresh mint that evicts the older of the two. Most-recently-USED order is what keeps
    ///      a wall the price keeps returning to from being evicted by a mint it sat out.
    function _recordUsedWall(uint256 id, int24 tickLower) internal {
        (uint112 id0, int24 lower0) = (liquidityWall0Id, liquidityWall0TickLower);
        if (id == id0) return;

        // One shift covers both remaining cases: if `id` was the second entry this swaps the two, and if
        // it is a fresh mint this evicts the older one.
        (liquidityWall1Id, liquidityWall1TickLower) = (id0, lower0);
        // Safe: the position manager's id is a counter incremented once per mint, from 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        (liquidityWall0Id, liquidityWall0TickLower) = (uint112(id), tickLower);
    }
}
