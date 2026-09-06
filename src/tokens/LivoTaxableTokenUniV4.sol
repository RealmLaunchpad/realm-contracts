// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableTokenUniV4Base, ILivoV4Graduator} from "src/tokens/LivoTaxableTokenUniV4Base.sol";
import {LivoDividendLogicUniV4} from "src/tokens/LivoDividendLogicUniV4.sol";
import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigs} from "src/interfaces/ILivoTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {ILivoUniV4LiquidityAdder} from "src/liquidity/LivoUniV4LiquidityAdder.sol";
// Self-aliased so the `chain-arc-*` recipes can import-swap it for the ARC pool constants.
import {UniswapV4PoolConstants as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet} (ARC native currency is USDC, 18-dec at msg.value).
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @title LivoTaxableTokenUniV4
/// @notice ERC20 token implementation with time-limited buy/sell taxes enforced via Uniswap V4 hooks.
/// @dev Extends `LivoTaxableTokenUniV4Base` (tax config + earnings split + the V4 buy-back primitive).
///      Tax accounting on swaps lives in `LivoSwapHook`; the token exposes the tax config via
///      `getTaxConfig()`. The earnings-allocation burn bucket is buffered here as ETH
///      (`burnPendingEth`) and processed out-of-band by `processBurn`, which buys back and burns tokens.
/// @dev The out-of-band dividend entry points (`processDividends`, `claimDividends`) are thin
///      `delegatecall` stubs into `DIVIDEND_LOGIC`; only their
///      bodies live elsewhere, and nothing on the swap hot path does. See `DividendDistributionLogic`.
contract LivoTaxableTokenUniV4 is LivoTaxableTokenUniV4Base {
    ///////////////////////////////// uniswap v4 related /////////////////////////////////////////
    // NB : THESE ARE HARDCODED FOR MAINNET TO SAVE GAS

    /// @notice Pool manager for lock state checking
    address public constant UNIV4_POOL_MANAGER = DeploymentAddresses.UNIV4_POOL_MANAGER;

    /// @notice Position manager holding this token's liquidity walls. Only `processLiquidity`'s top-up
    ///         path calls it directly — minting still goes through the shared `LivoUniV4LiquidityAdder` —
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

    /// @notice The `LivoDividendLogicUniV4` extension the dividend entry points `delegatecall` into.
    /// @dev Deployed by THIS constructor rather than passed in or read from a manifest: the two are
    ///      storage-layout-coupled, so pairing them at deploy time is one more thing that can be wired
    ///      wrong for no benefit. Deploying it here makes the pair atomic, keeps every deploy script and
    ///      test unchanged (`new LivoTaxableTokenUniV4()` still takes no arguments), and costs only
    ///      creation-code size on the implementation — which EIP-170 does not bound, and EIP-3860 bounds
    ///      far above what this needs. Immutable, so clones read it straight from the implementation.
    address public immutable DIVIDEND_LOGIC;

    error NothingToBurn();

    /// @notice The buy-back router call reverted — a missed `minTokensOut`, or an unswappable pool.
    error BuyBackFailed();
    error NothingToAdd();
    error ProcessCooldown();

    //////////////////////////////////////////////////////

    /// @notice Creates a new LivoTaxableTokenUniV4 instance which will be used as implementation for clones
    /// @dev Token configuration is set during initialization, not in constructor
    constructor() LivoToken() {
        // All token initialization happens in initialize() due to minimal proxy pattern; the only thing
        // the implementation itself owns is its dividend extension.
        require(block.chainid == DeploymentAddresses.BLOCKCHAIN_ID, "configuration for wrong chainId");
        DIVIDEND_LOGIC = address(new LivoDividendLogicUniV4());
    }

    /// @notice Initializes the token clone with its tax configuration. Anti-sniper protection is
    ///         enabled iff `antiSniperCfg` opts in (`protectionWindowSeconds != 0`); pass an all-zero
    ///         config for a tax-only token.
    /// @param params Shared token initialization parameters
    /// @param taxCfg Tax configuration (buy/sell bps, window, optional launch-tax decay)
    /// @param antiSniperCfg Anti-sniper caps + window config (validated upstream in the factory)
    function initialize(
        ILivoToken.InitializeParams memory params,
        TaxConfigs memory taxCfg,
        AntiSniperConfigs memory antiSniperCfg
    ) external virtual initializer {
        _initializeLivoTaxableToken(params, taxCfg);
        _initializeAntiSniper(antiSniperCfg);
    }

    /// @notice Buys back tokens with the accrued burn ETH and burns them, reducing total supply.
    ///         Permissionless: the accrued ETH is protocol-committed to burning, so any keeper may
    ///         trigger it (holders don't depend on the creator staying active). Batches many small
    ///         accruals into one swap, off the swap hot path. Spends at most
    ///         `MAX_EARNINGS_PER_PROCESS` per call, once per block (`ProcessCooldown`), so a
    ///         sandwiching manipulator's per-block take is capped; the remainder stays buffered.
    /// @param minTokensOut Slippage floor — the minimum tokens the buy-back must yield, or the swap
    ///        reverts. Callers should set this from the current price; a value of 0 invites sandwiching.
    /// @dev The buy-back is an ordinary pool swap, so `LivoSwapHook` charges its usual LP fee (and,
    ///      inside the launch tax window, tax — a fraction of which loops back into `burnPendingEth`
    ///      for the next call). This is accepted rather than special-casing the audited hook.
    function processBurn(uint256 minTokensOut) external nonReentrant {
        // Keeper-gated: the caller supplies the floor, so a permissionless caller could set it to zero
        // around their own price manipulation and keep almost the whole spend. See `LivoKeepersRegistry`.
        _requireKeeper();
        // Once per block + capped spend: bounds what a sandwich can extract per manipulated block once
        // the caller can no longer choose the floor. It is a second bound, not the first one.
        require(block.number > lastBurnProcessBlock, ProcessCooldown());
        lastBurnProcessBlock = uint48(block.number);

        uint256 ethIn = burnPendingEth;
        require(ethIn > 0, NothingToBurn());
        if (ethIn > MAX_EARNINGS_PER_PROCESS) ethIn = MAX_EARNINGS_PER_PROCESS;
        burnPendingEth -= ethIn;

        address hook = ILivoV4Graduator(graduator).HOOK_ADDRESS();
        uint256 balanceBefore = balanceOf(address(this));
        // Balance AND reserves, NOT the raw balance `processLiquidity` can use and NOT the clamped
        // `_sweepableNative()`: this one is a SWAP, so the hook's `accrueFees` lands native here
        // mid-call, raising the balance and the buffers by the same amount (the fund slice leaves
        // immediately). Tracking the two separately lets that accrual cancel while the router's spend
        // still shows. `burnPendingEth` was debited above, so `ethIn` is unreserved for the call.
        uint256 balanceBeforeEth = address(this).balance;
        uint256 reservedBefore = _reservedNative();
        // Precursor marker: must stay BEFORE the swap so indexers can classify the resulting
        // `LivoSwapHook.LivoSwapBuy` as a protocol buy-back rather than a trade by `tx.origin`.
        emit BuyBackInitiated(ethIn);
        require(_buyBackTokensWithEth(hook, ethIn, minTokensOut), BuyBackFailed());
        uint256 tokensBought = balanceOf(address(this)) - balanceBefore;

        // Whatever the pool did not take came back with the router's `SWEEP` and stays earmarked for
        // burning, mirroring `processLiquidity`: without this the unspent remainder rejoins the stray
        // pool and `sweepStrayEth` re-splits it into the fund / dividend / liquidity buckets, spending
        // an allocation meant for burning.
        // `spent = (balance drop) + (reserve growth)`, the same shape `LivoDividendLogicUniV4` uses and
        // for the same reason: `_sweepableNative()` CLAMPS AT ZERO, and a native dividend payout
        // reentering here mid-`claimDividends` (the balance already sent, `dividendsOwed` not yet
        // reduced) pins both readings to zero — reporting a spend of 0 and re-crediting the whole
        // `ethIn` that the swap really consumed. Arranged so neither side can underflow.
        uint256 lhs = balanceBeforeEth + _reservedNative();
        uint256 rhs = address(this).balance + reservedBefore;
        uint256 ethSpent = lhs > rhs ? lhs - rhs : 0;
        if (ethSpent < ethIn) burnPendingEth += ethIn - ethSpent;

        if (tokensBought > 0) _burn(address(this), tokensBought);
        // Reports the ETH the pool ACTUALLY took, as `processLiquidity` does with `ethAdded`.
        emit CreatorTaxBurn(ethSpent, tokensBought);
    }

    /// @notice Deposits the accrued liquidity ETH as a single-sided ETH position just below the current
    ///         price — a protective bid wall. Both placing and reusing run through the shared
    ///         `LivoUniV4LiquidityAdder`: this token only keeps the memory of the two walls it most
    ///         recently used and the policy (`LIQUIDITY_WALL_TICK_WIDTH`, `LIQUIDITY_WALL_REUSE_MAX_GAP`)
    ///         that decides between topping one of them up and minting a fresh one.
    ///         Permissionless and off the swap hot path, mirroring `processBurn`: the ETH is
    ///         protocol-committed to liquidity, so any keeper may trigger it. Positions are held by this
    ///         token and never withdrawn, so they are permanent pool depth. Spends at most
    ///         `MAX_EARNINGS_PER_PROCESS` per call, once per block (`ProcessCooldown`): a fresh wall is
    ///         placed at the LIVE tick, so a manipulator could pump the price and dump into a wall placed
    ///         at the inflated level — the cap+cooldown bounds that extraction per block (each block needs
    ///         a fresh, fee-paying pump).
    /// @dev Runs out-of-band because `modifyLiquidity` cannot execute inside the swap hook's pool lock.
    ///      Batches many small accruals into one add. Guarded by the shared `nonReentrant` lock (both
    ///      paths route through the position manager and the pool).
    function processLiquidity() external nonReentrant {
        // Keeper-gated, and this one has NO slippage parameter at all: the wall is placed at whatever
        // price the caller has arranged. See `LivoKeepersRegistry`.
        _requireKeeper();
        // Once per block + capped spend: bounds what a manipulated wall placement can extract per block.
        require(block.number > lastLiquidityProcessBlock, ProcessCooldown());
        lastLiquidityProcessBlock = uint48(block.number);

        uint256 ethIn = liquidityPendingEth;
        require(ethIn > 0, NothingToAdd());
        if (ethIn > MAX_EARNINGS_PER_PROCESS) ethIn = MAX_EARNINGS_PER_PROCESS;
        liquidityPendingEth -= ethIn;

        PoolKey memory key =
            UniswapV4PoolConstants.livoPoolKey(address(this), ILivoV4Graduator(graduator).HOOK_ADDRESS());
        address adder = ILivoV4Graduator(graduator).LIQUIDITY_ADDER();

        // The adder needs the position manager's `onlyIfApproved` to top up a wall this token owns. Set
        // unconditionally rather than once: it is a same-value SSTORE after the first call, and it
        // self-heals if the graduator ever points at a different adder — where a one-shot grant would
        // leave `processLiquidity` reverting on every reusable wall. The adder is already trusted with the
        // ETH handed to it, cannot decrease, burn or transfer a position, and comes from the same
        // graduator that names the hook mediating every swap.
        IERC721(UNIV4_POSITION_MANAGER).setApprovalForAll(adder, true);

        // NFT and leftover ETH both return to this token (permanent depth; the ETH stays earmarked). The
        // adder picks between topping up one of the remembered walls and minting a fresh one, and reports
        // back which position took the ETH so the memory below can be updated.
        uint256 balanceBefore = address(this).balance;
        (uint256[2] memory ids, int24[2] memory tickLowers) = getLiquidityWalls();
        (uint128 liquidity, uint256 usedId, int24 usedTickLower) = ILivoUniV4LiquidityAdder(adder)
        .addOrTopUpSingleSidedEth{value: ethIn}(
            key, LIQUIDITY_WALL_TICK_WIDTH, LIQUIDITY_WALL_REUSE_MAX_GAP, ids, tickLowers, address(this), address(this)
        );
        // A zero id means nothing was placed and the ETH came back — no wall to record.
        if (usedId != 0) _recordUsedWall(usedId, usedTickLower);

        // Whatever was not placed stays earmarked for liquidity, mirroring the V2 processor:
        // `liquidityPendingEth` was debited by the full `ethIn` above, so without this the unplaced
        // remainder silently rejoins the stray-ETH pool and `sweepStrayEth` re-splits it into the burn /
        // dividend / fund buckets. Ways to get one: `ethIn` sized to zero liquidity and was never spent,
        // or the add's `SWEEP` returned the rounding dust. Nothing can send ETH here mid-call — both paths
        // are `modifyLiquidities`, not swaps, so no hook fee can land in between.
        uint256 ethAdded = balanceBefore - address(this).balance;
        if (ethAdded < ethIn) liquidityPendingEth += ethIn - ethAdded;

        // Shared event signature; reports the ETH the pool ACTUALLY took, as the V2 processor does. The
        // token side is always 0 for the single-sided ETH wall.
        emit LiquidityAdded(ethAdded, 0, liquidity);
    }

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
    function _recordUsedWall(uint256 id, int24 tickLower) private {
        (uint112 id0, int24 lower0) = (liquidityWall0Id, liquidityWall0TickLower);
        if (id == id0) return;

        // One shift covers both remaining cases: if `id` was the second entry this swaps the two, and if
        // it is a fresh mint this evicts the older one.
        (liquidityWall1Id, liquidityWall1TickLower) = (id0, lower0);
        // Safe: the position manager's id is a counter incremented once per mint, from 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        (liquidityWall0Id, liquidityWall0TickLower) = (uint112(id), tickLower);
    }

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @inheritdoc LivoTaxableToken
    /// @dev Adds the V4 pool-manager pair check after shared init. The graduator is expected to
    ///      have set `pair == UNIV4_POOL_MANAGER` during `LivoToken._initializeLivoToken`; if not,
    ///      revert and roll back any earlier writes (storage updates already performed are
    ///      reverted with the rest of the tx, so ordering vs `_initializeTaxConfig` is irrelevant).
    function _initializeLivoTaxableToken(ILivoToken.InitializeParams memory params, TaxConfigs memory taxCfg)
        internal
        override
        onlyInitializing
    {
        super._initializeLivoTaxableToken(params, taxCfg);
        require(pair == UNIV4_POOL_MANAGER, "Invalid pair address");
    }

    /// @dev V4 burn accrues ETH (earnings are ETH-native); the buy-back-and-burn happens out-of-band
    ///      in `processBurn`, so this stays cheap (one SSTORE) and consumes the slice fully (returns 0,
    ///      nothing folds back to the fund wallets). Overrides the base fund-fallback in
    ///      `EarningsAllocation`.
    function _handleBurn(uint256 amount) internal override returns (uint256) {
        burnPendingEth += amount;
        return 0;
    }

    /// @dev V4 liquidity accrues ETH (earnings are ETH-native); the single-sided add happens out-of-band
    ///      in `processLiquidity`, so this stays cheap (one SSTORE) and consumes the slice fully (returns
    ///      0). Mirrors `_handleBurn`; overrides the base fund-fallback in `EarningsAllocation`.
    function _handleLiquidity(uint256 amount) internal override returns (uint256) {
        liquidityPendingEth += amount;
        return 0;
    }

    //////////////////////// DIVIDENDS (delegated) //////////////////////

    /// @notice Advances the dividend round by everything it is due for: freezes the pot once the buffer
    ///         has cleared its threshold, pushes payouts to `holders`, and rolls the round over once the
    ///         pot is drained. Permissionless, and the only entry point a keeper needs.
    /// @param minOut Slippage floor for the conversion, in the payout asset's own decimals. Ignored when
    ///        the payout asset is native or the token itself, and by any call that does not freeze.
    /// @param holders Addresses to push this round's payouts to. May be empty.
    function processDividends(uint256 minOut, address[] calldata holders) external {
        minOut;
        holders;
        _delegateToDividendLogic();
    }

    /// @notice Same, for one of the payout assets of a token that pays in several. `assetIndex` selects
    ///         which; each asset crosses its own threshold, prices its own floor and holds its own
    ///         per-block cooldown, so a keeper services them one call at a time.
    /// @param assetIndex Which configured payout asset to service, `0 .. dividendAssetCount() - 1`.
    /// @param minOut Slippage floor for that asset's conversion, in its own decimals.
    /// @param holders Addresses to push that asset's accrued payouts to. May be empty.
    function processDividends(uint8 assetIndex, uint256 minOut, address[] calldata holders) external {
        assetIndex;
        minOut;
        holders;
        _delegateToDividendLogic();
    }

    /// @notice Self-serve backstop for a holder the keeper missed. Same formula, same paid marker.
    function claimDividends() external {
        _delegateToDividendLogic();
    }

    /// @inheritdoc LivoTaxableToken
    function dividendLogic() public view override returns (address) {
        return DIVIDEND_LOGIC;
    }
}
