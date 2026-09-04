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
import {PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

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
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

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
        // Once per block + capped spend: bounds what a sandwich can extract per manipulated block.
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
    ///         price — a protective bid wall. Tops up a wall this token already owns when one is still
    ///         usable, and otherwise mints a fresh one via the shared `LivoUniV4LiquidityAdder`.
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
        // Once per block + capped spend: bounds what a manipulated wall placement can extract per block.
        require(block.number > lastLiquidityProcessBlock, ProcessCooldown());
        lastLiquidityProcessBlock = uint48(block.number);

        uint256 ethIn = liquidityPendingEth;
        require(ethIn > 0, NothingToAdd());
        if (ethIn > MAX_EARNINGS_PER_PROCESS) ethIn = MAX_EARNINGS_PER_PROCESS;
        liquidityPendingEth -= ethIn;

        PoolKey memory key =
            UniswapV4PoolConstants.livoPoolKey(address(this), ILivoV4Graduator(graduator).HOOK_ADDRESS());
        (, int24 currentTick,,) = IPoolManager(UNIV4_POOL_MANAGER).getSlot0(key.toId());

        // NFT and leftover ETH both return to this token (permanent depth; the ETH stays earmarked).
        uint256 balanceBefore = address(this).balance;
        uint128 liquidity;

        (uint112 wallId, bool fromSlot1) = _reusableWall(currentTick);
        if (wallId != 0) {
            liquidity = _topUpWall(key, wallId, ethIn);
            // Keep the memory most-recently-used first, so the wall we just proved good survives the next
            // mint's eviction. Only slot 1 needs moving; a slot-0 hit is already in place.
            if (fromSlot1) _swapRememberedWalls();
        } else {
            address adder = ILivoV4Graduator(graduator).LIQUIDITY_ADDER();
            liquidity = ILivoUniV4LiquidityAdder(adder).addSingleSidedEthBelowPrice{value: ethIn}(
                key, LIQUIDITY_WALL_TICK_WIDTH, address(this), address(this)
            );
            // Zero liquidity means the adder placed nothing and refunded, so no id was consumed and there
            // is no wall to remember. The lower tick is read back from the position manager rather than
            // recomputed here: a second copy of the adder's tick math could drift from it, and this way a
            // wrong entry is impossible rather than merely unlikely.
            if (liquidity != 0) {
                uint256 mintedId = IPositionManager(UNIV4_POSITION_MANAGER).nextTokenId() - 1;
                // Safe: the position manager's id is a counter incremented once per mint, from 1.
                // forge-lint: disable-next-line(unsafe-typecast)
                _rememberWall(
                    uint112(mintedId), IPositionManager(UNIV4_POSITION_MANAGER).positionInfo(mintedId).tickLower()
                );
            }
        }

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
    function getLiquidityWalls() external view returns (uint256[2] memory ids, int24[2] memory tickLowers) {
        ids = [uint256(liquidityWall0Id), uint256(liquidityWall1Id)];
        tickLowers = [liquidityWall0TickLower, liquidityWall1TickLower];
    }

    /// @notice The remembered wall `processLiquidity` should top up at `currentTick`, or a zero id when
    ///         it should mint a fresh one instead.
    /// @dev Picks the CLOSEST eligible wall, not the first: a price that zigzags can leave the older of
    ///      the two nearer the current price, and topping up the deeper of two candidates is exactly what
    ///      `LIQUIDITY_WALL_REUSE_MAX_GAP` exists to prevent.
    function _reusableWall(int24 currentTick) private view returns (uint112 id, bool fromSlot1) {
        int24 tickLower;
        (uint112 id0, int24 lower0) = (liquidityWall0Id, liquidityWall0TickLower);
        if (_wallIsReusable(id0, lower0, currentTick)) (id, tickLower) = (id0, lower0);

        (uint112 id1, int24 lower1) = (liquidityWall1Id, liquidityWall1TickLower);
        if (_wallIsReusable(id1, lower1, currentTick) && (id == 0 || lower1 < tickLower)) {
            (id, fromSlot1) = (id1, true);
        }
    }

    /// @dev A wall can take more ETH only while its whole range sits STRICTLY above the current tick —
    ///      that is what keeps it ETH-only. At or below it the position already holds token, and the
    ///      increase would demand a token1 settlement this call never makes. The gap bound is the second
    ///      half: a range far above the tick is a wall the price has long left behind, and thickening it
    ///      would park the ETH as deep depth instead of the protective bid it is meant to be.
    function _wallIsReusable(uint112 id, int24 tickLower, int24 currentTick) private pure returns (bool) {
        return id != 0 && currentTick < tickLower && tickLower - currentTick <= LIQUIDITY_WALL_REUSE_MAX_GAP;
    }

    /// @dev Adds `ethIn` to an existing wall and returns the liquidity the position gained.
    /// @dev No zero-liquidity guard, unlike the mint path: a wall's range sits entirely above the current
    ///      tick, and liquidity per ETH grows with that distance, so across a Livo pool's whole tick range
    ///      even 1 wei sizes to at least 1 unit of liquidity. `ethIn` is non-zero by the caller's
    ///      `NothingToAdd` check, so v4-core's `CannotUpdateEmptyPosition` is unreachable here.
    /// @dev Called from the token rather than the shared adder because `PositionManager._increase` is
    ///      `onlyIfApproved`: this token owns the NFT, and the alternative — approving a permissionless
    ///      contract for all of its positions — buys nothing.
    function _topUpWall(PoolKey memory key, uint112 tokenId, uint256 ethIn) private returns (uint128 liquidity) {
        IPositionManager posm = IPositionManager(UNIV4_POSITION_MANAGER);
        uint128 liquidityBefore = posm.getPositionLiquidity(tokenId);

        // SETTLE the ETH in, then let the position manager size the add from the resulting credit and the
        // position's own recorded range. Sizing it here instead would pull `TickMath` and
        // `LiquidityAmounts` into a contract with barely any EIP-170 headroom, to compute a number the
        // position manager already computes.
        // CLOSE_CURRENCY twice rather than SETTLE_PAIR/TAKE_PAIR: an increase folds the position's accrued
        // fees into the deltas, and either paired action reverts as soon as one side is a credit and the
        // other a debt. The pool's LP fee is zero and the hook holds no add-liquidity permissions, so no
        // fee can accrue today — but bricking `processLiquidity` if that ever changes is not worth the two
        // bytes. Anything closed out comes back to this contract, which the ETH re-earmarking below and
        // the stray-token accounting already handle.
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SETTLE),
            uint8(Actions.INCREASE_LIQUIDITY_FROM_DELTAS),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](5);
        // `payerIsUser` is irrelevant for native: the settle draws on the `msg.value` sent below.
        params[0] = abi.encode(key.currency0, ethIn, false);
        // amount0Max = ethIn (slippage cap), amount1Max = 0 (ETH-only, checked on the principal delta).
        // Safe: `ethIn` is clamped to `MAX_EARNINGS_PER_PROCESS` by the caller. The cast is not cosmetic —
        // the position manager decodes these fields with a raw `calldataload`, so an over-wide value would
        // be read back dirty rather than truncated.
        // forge-lint: disable-next-line(unsafe-typecast)
        params[1] = abi.encode(uint256(tokenId), uint128(ethIn), uint128(0), bytes(""));
        params[2] = abi.encode(key.currency0);
        params[3] = abi.encode(key.currency1);
        params[4] = abi.encode(key.currency0, address(this)); // SWEEP native ETH dust

        posm.modifyLiquidities{value: ethIn}(abi.encode(actions, params), block.timestamp);
        liquidity = posm.getPositionLiquidity(tokenId) - liquidityBefore;
    }

    /// @dev Records a freshly minted wall as the most recent one, evicting the older of the two.
    function _rememberWall(uint112 id, int24 tickLower) private {
        (liquidityWall1Id, liquidityWall1TickLower) = (liquidityWall0Id, liquidityWall0TickLower);
        (liquidityWall0Id, liquidityWall0TickLower) = (id, tickLower);
    }

    /// @dev Moves the slot-1 wall to slot 0 after topping it up, so the memory stays most-recently-used
    ///      first.
    function _swapRememberedWalls() private {
        (uint112 id0, int24 lower0) = (liquidityWall0Id, liquidityWall0TickLower);
        (liquidityWall0Id, liquidityWall0TickLower) = (liquidityWall1Id, liquidityWall1TickLower);
        (liquidityWall1Id, liquidityWall1TickLower) = (id0, lower0);
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

    /// @notice Self-serve backstop for a holder the keeper missed. Same formula, same paid marker.
    function claimDividends() external {
        _delegateToDividendLogic();
    }

    /// @inheritdoc LivoTaxableToken
    function dividendLogic() public view override returns (address) {
        return DIVIDEND_LOGIC;
    }
}
