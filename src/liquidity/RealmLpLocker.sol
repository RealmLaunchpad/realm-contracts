// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
// The position manager is v4-periphery's, so its pin of v4-core types every read and action below. The
// adder takes the canonical `lib/v4-core` key from `UniswapV4PoolConstants`, hence the alias.
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {PoolKey as CorePoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency as CoreCurrency} from "lib/v4-core/src/types/Currency.sol";

import {IRealmLpLocker} from "src/interfaces/IRealmLpLocker.sol";
import {IRealmPoolFee} from "src/interfaces/IRealmPoolFee.sol";
import {ISwapLpFeeRouter} from "src/interfaces/ISwapLpFeeRouter.sol";
import {ISwapLpFeeRouterTokenFees} from "src/interfaces/ISwapLpFeeRouterTokenFees.sol";
import {IRealmUniV4LiquidityAdder} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";

/// @notice The graduator's view the locker needs to key a wall's pool.
interface IRealmLpLockerGraduator {
    function hookFor(address quote) external view returns (address);
}

/// @title RealmLpLocker
/// @notice Holds every protocol-owned Realm V4 position — each launch's seed band (registered by the
///         graduator) and every bid wall a token places (`addWall`) — and pays out the native pool fees
///         they earn, never the liquidity: there is no path to decrease, burn or transfer a position.
///         Fees in the quote are split 30/70 treasury/creator by `SwapLpFeeRouter` on the spot; fees in
///         the token (Uniswap charges the fee on a swap's input, so sells pay it in the token) wait in
///         the router's pending bucket until a keeper sells them for the quote.
///
/// @dev Immutable and ownerless. Deployed by `RealmDirectGraduatorUniV4`'s constructor, which is how the
///      two learn each other's address without a predicted address or a setter: `GRADUATOR` is the
///      deployer, and the graduator records the address `new` returned.
/// @dev Approves the liquidity adder for every position (the adder's top-up needs `onlyIfApproved`).
///      Safe for the reason the adder documents: it is non-upgradeable, can only ever INCREASE a
///      position, and tops one up only for its owner as caller — this contract.
/// @dev Hostile callers. Positions are keyed by the address that registered them: the graduator for a
///      seed, `msg.sender` for a wall. A contract posing as a token can therefore only mint or top up
///      walls in ITS OWN pool, keyed under itself — so no caller can top up, or collect early, another
///      token's position. `collect` on a fake token only moves that fake's own pool fees. Every entry
///      point is `nonReentrant`, and the contract holds no balance between calls (each fee collection
///      and each refund is a measured delta forwarded in the same call), so nothing a reentering token
///      or router could do changes what another call measures.
/// @dev Walls live on a FIXED grid of `WALL_RANGE_TICKS`-wide ranges. Each add goes to the grid range
///      just below the one holding the current price (in the token's price), topping up the wall
///      already there or minting it. So a token has at most one wall per range its price has ever
///      visited, per quote: a 1000x run is ~10 ranges. `collect` is O(positions), and that bound is
///      what keeps it cheap; it skips positions with nothing owed and folds each pool's positions into
///      ONE position-manager call.
contract RealmLpLocker is IRealmLpLocker, ReentrancyGuardTransient {
    /// @notice Contract version.
    uint256 public constant VERSION = 1;

    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    /// @notice Width, in TICKS, of every grid range a wall can occupy: 1.0001^7000 ≈ 2.01, so each range
    ///         spans a ~50% price drop. Spacing-aligned, and ranges start at its multiples.
    int24 public constant WALL_RANGE_TICKS = 35 * UniswapV4PoolConstants.TICK_SPACING;

    IPoolManager public immutable POOL_MANAGER;
    IPositionManager public immutable POSITION_MANAGER;
    address public immutable LIQUIDITY_ADDER;
    /// @notice `SwapLpFeeRouter` proxy every collected fee goes to.
    address public immutable LP_FEE_ROUTER;
    /// @notice The only address allowed to register a seed band: the graduator that deployed this.
    address public immutable GRADUATOR;

    /// @notice What a registered position is.
    struct PositionMeta {
        address token;
        address quote;
        bool isWall;
    }

    /// @notice Registered position-manager ids, per token, in registration order.
    mapping(address token => uint256[]) internal _positionIds;
    /// @notice The quotes of the pools a token has positions in, in first-registration order.
    mapping(address token => address[]) internal _quotesOf;
    /// @notice Owner token, quote and kind of every registered position. Zero token: not registered.
    mapping(uint256 tokenId => PositionMeta) public positionMeta;
    /// @notice The wall `token` holds in its `quote` pool's grid range starting at tick `rangeStart` (a
    ///         multiple of `WALL_RANGE_TICKS`). Zero: no wall there yet.
    mapping(address token => mapping(address quote => mapping(int24 rangeStart => uint256))) public wallAt;

    error OnlyGraduator();
    error NotOwnedByLocker();
    error AlreadyRegistered();
    /// @notice The seed's pool does not contain the token it is registered under.
    error PoolMismatch();
    error ZeroAmount();
    /// @notice Native wall with `msg.value != amount`, or value sent with an ERC20 wall.
    error ValueMismatch();
    error NativeTransferFailed();
    /// @notice Native from anyone but the pool manager, the position manager or the adder.
    error UnexpectedNative();
    /// @notice The price sits at the edge of the usable tick band, with no range left below it.
    error WallOutOfRange();

    constructor(address poolManager, address positionManager, address liquidityAdder, address lpFeeRouter) {
        POOL_MANAGER = IPoolManager(poolManager);
        POSITION_MANAGER = IPositionManager(positionManager);
        LIQUIDITY_ADDER = liquidityAdder;
        LP_FEE_ROUTER = lpFeeRouter;
        GRADUATOR = msg.sender;
        IERC721(positionManager).setApprovalForAll(liquidityAdder, true);
    }

    /// @notice Native fee takes (paid by the pool manager) and principal refunds (the position manager's
    ///         sweep, or the adder's own return).
    receive() external payable {
        require(
            msg.sender == address(POOL_MANAGER) || msg.sender == address(POSITION_MANAGER)
                || msg.sender == LIQUIDITY_ADDER,
            UnexpectedNative()
        );
    }

    ////////////////////////////// REGISTRATION //////////////////////////////

    /// @inheritdoc IRealmLpLocker
    function registerSeed(address token, uint256 tokenId) external {
        require(msg.sender == GRADUATOR, OnlyGraduator());
        (PoolKey memory key,) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        require(c0 == token || c1 == token, PoolMismatch());
        _register(token, c0 == token ? c1 : c0, tokenId, false);
    }

    /// @dev Records a position this contract already owns under `token`.
    function _register(address token, address quote, uint256 tokenId, bool isWall) private {
        require(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId) == address(this), NotOwnedByLocker());
        require(positionMeta[tokenId].token == address(0), AlreadyRegistered());
        positionMeta[tokenId] = PositionMeta({token: token, quote: quote, isWall: isWall});
        _positionIds[token].push(tokenId);
        if (!_hasQuote(token, quote)) _quotesOf[token].push(quote);
        emit PositionRegistered(token, quote, tokenId, isWall);
    }

    function _hasQuote(address token, address quote) private view returns (bool) {
        address[] storage qs = _quotesOf[token];
        for (uint256 i; i < qs.length; ++i) {
            if (qs[i] == quote) return true;
        }
        return false;
    }

    ////////////////////////////// COLLECT //////////////////////////////

    /// @inheritdoc IRealmLpLocker
    function collect(address[] calldata tokens) external nonReentrant {
        for (uint256 t; t < tokens.length; ++t) {
            address token = tokens[t];
            address[] memory qs = _quotesOf[token];
            for (uint256 q; q < qs.length; ++q) {
                uint256[] memory ids = _owingIds(token, qs[q]);
                if (ids.length != 0) _collectIds(token, qs[q], ids);
            }
        }
    }

    /// @dev `token`'s positions in its `quote` pool that have fees to collect.
    function _owingIds(address token, address quote) private view returns (uint256[] memory ids) {
        uint256[] storage all = _positionIds[token];
        uint256 n = all.length;
        ids = new uint256[](n);
        uint256 m;
        for (uint256 i; i < n; ++i) {
            uint256 id = all[i];
            if (positionMeta[id].quote != quote) continue;
            (, uint256 owed0, uint256 owed1) = _owed(id);
            if (owed0 != 0 || owed1 != 0) ids[m++] = id;
        }
        assembly ("memory-safe") {
            mstore(ids, m)
        }
    }

    /// @dev Takes the fees of `ids` (all in `token`'s `quote` pool) in one position-manager call — a
    ///      zero-liquidity `DECREASE_LIQUIDITY` per position, then one `TAKE_PAIR` — and forwards them.
    function _collectIds(address token, address quote, uint256[] memory ids) private {
        uint256 n = ids.length;
        (PoolKey memory key,) = POSITION_MANAGER.getPoolAndPositionInfo(ids[0]);
        bytes memory actions = new bytes(n + 1);
        bytes[] memory params = new bytes[](n + 1);
        for (uint256 i; i < n; ++i) {
            actions[i] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
            params[i] = abi.encode(ids[i], uint256(0), uint128(0), uint128(0), bytes(""));
        }
        actions[n] = bytes1(uint8(Actions.TAKE_PAIR));
        params[n] = abi.encode(key.currency0, key.currency1, address(this));

        uint256 quoteBefore = _balance(quote);
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        uint256 quoteAmount = _balance(quote) - quoteBefore;
        uint256 tokenAmount = IERC20(token).balanceOf(address(this)) - tokenBefore;

        emit LpFeesCollected(token, quote, quoteAmount, tokenAmount);
        _forward(token, quote, quoteAmount, tokenAmount);
    }

    /// @dev Quote side into the router's split now; token side into its pending bucket for conversion.
    function _forward(address token, address quote, uint256 quoteAmount, uint256 tokenAmount) private {
        if (quoteAmount != 0) {
            if (quote == address(0)) {
                ISwapLpFeeRouter(LP_FEE_ROUTER).depositLpFees{value: quoteAmount}(token, 0, 0);
            } else {
                IERC20(quote).forceApprove(LP_FEE_ROUTER, quoteAmount);
                ISwapLpFeeRouter(LP_FEE_ROUTER).depositLpFees(token, quote, quoteAmount, 0, 0);
            }
        }
        if (tokenAmount != 0) {
            IERC20(token).forceApprove(LP_FEE_ROUTER, tokenAmount);
            ISwapLpFeeRouterTokenFees(LP_FEE_ROUTER).depositTokenFees(token, quote, tokenAmount);
        }
    }

    ////////////////////////////// WALLS //////////////////////////////

    /// @inheritdoc IRealmLpLocker
    /// @dev A top-up collects the wall's fees FIRST, because a v4 increase folds a position's accrued
    ///      fees into its deltas, where they would mix with the principal refund. After that collection
    ///      (same transaction, no swap in between) the top-up returns principal remainder only.
    function addWall(address quote, uint256 amount)
        external
        payable
        nonReentrant
        returns (uint128 liquidity, uint256 tokenId, uint256 spent)
    {
        require(amount != 0, ZeroAmount());
        address token = msg.sender;
        bool native = quote == address(0);
        require(msg.value == (native ? amount : 0), ValueMismatch());
        if (!native) IERC20(quote).safeTransferFrom(token, address(this), amount);

        CorePoolKey memory key = _wallKey(token, quote);
        (int24 rangeStart, int24 tickLower, int24 tickUpper) = _wallRange(key, quote);
        tokenId = wallAt[token][quote][rangeStart];
        if (tokenId != 0) {
            (, uint256 owed0, uint256 owed1) = _owed(tokenId);
            if (owed0 != 0 || owed1 != 0) {
                uint256[] memory ids = new uint256[](1);
                ids[0] = tokenId;
                _collectIds(token, quote, ids);
            }
        }

        if (!native) IERC20(quote).forceApprove(LIQUIDITY_ADDER, amount);
        uint256 balanceBefore = _balance(quote); // holds `amount`
        if (tokenId != 0) {
            liquidity = IRealmUniV4LiquidityAdder(LIQUIDITY_ADDER).topUpSingleSided{value: native ? amount : 0}(
                key, CoreCurrency.wrap(quote), amount, tokenId, address(this)
            );
        } else {
            // The id the mint is about to consume: `nextTokenId` is assigned before it is incremented.
            tokenId = POSITION_MANAGER.nextTokenId();
            liquidity = IRealmUniV4LiquidityAdder(LIQUIDITY_ADDER).addSingleSided{value: native ? amount : 0}(
                key, CoreCurrency.wrap(quote), amount, tickLower, tickUpper, address(this), address(this)
            );
            if (liquidity == 0) {
                tokenId = 0; // dust: nothing minted, all of it came back
            } else {
                wallAt[token][quote][rangeStart] = tokenId;
                _register(token, quote, tokenId, true);
            }
        }
        uint256 refund = _balance(quote) + amount - balanceBefore;
        spent = amount - refund;
        if (refund != 0) _send(quote, token, refund);
    }

    /// @dev The canonical key of `token`'s pool against `quote`, at the token's own fee tier.
    function _wallKey(address token, address quote) private view returns (CorePoolKey memory) {
        return UniswapV4PoolConstants.realmPoolKey(
            token, quote, IRealmLpLockerGraduator(GRADUATOR).hookFor(quote), IRealmPoolFee(token).poolFee()
        );
    }

    /// @dev The grid range just below the one holding the current price, in the TOKEN's price, clamped
    ///      to the usable tick band. A quote at `currency0` (native, always) holds alone ABOVE the
    ///      current tick, a quote at `currency1` BELOW it: a higher tick is a cheaper token in the first
    ///      case and a dearer one in the second. Either way the range clears the current tick, so the
    ///      wall stays quote-only: `tick < tickLower` for `currency0`, `tickUpper <= tick` for `currency1`.
    function _wallRange(CorePoolKey memory key, address quote)
        private
        view
        returns (int24 rangeStart, int24 tickLower, int24 tickUpper)
    {
        // The two v4-core copies share the key layout, so its id is the same hash `toId` takes.
        (, int24 tick,,) = POOL_MANAGER.getSlot0(PoolId.wrap(keccak256(abi.encode(key))));
        int24 w = WALL_RANGE_TICKS;
        int24 current = tick / w;
        if (tick % w < 0) --current; // floor, not truncation, for negative ticks
        bool quoteIs0 = CoreCurrency.unwrap(key.currency0) == quote;
        rangeStart = (quoteIs0 ? current + 1 : current - 1) * w;
        tickLower = rangeStart;
        tickUpper = rangeStart + w;
        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);
        if (tickLower < minTick) tickLower = minTick;
        if (tickUpper > maxTick) tickUpper = maxTick;
        require(tickLower < tickUpper, WallOutOfRange());
    }

    ////////////////////////////// VIEWS //////////////////////////////

    /// @inheritdoc IRealmLpLocker
    /// @dev Mirrors v4-core's own accounting (`Position.update`): `(feeGrowthInside - last) * liquidity /
    ///      2^128` per side, from the pool's live fee-growth counters, so it is exactly what a collect in
    ///      the same block would take.
    function pendingFees(address token)
        external
        view
        returns (address[] memory quotes, uint256[] memory quoteAmounts, uint256[] memory tokenAmounts)
    {
        quotes = _quotesOf[token];
        quoteAmounts = new uint256[](quotes.length);
        tokenAmounts = new uint256[](quotes.length);
        uint256[] storage ids = _positionIds[token];
        for (uint256 i; i < ids.length; ++i) {
            address quote = positionMeta[ids[i]].quote;
            uint256 q;
            while (quotes[q] != quote) ++q;
            (address c0, uint256 owed0, uint256 owed1) = _owed(ids[i]);
            (uint256 tokenSide, uint256 quoteSide) = c0 == token ? (owed0, owed1) : (owed1, owed0);
            quoteAmounts[q] += quoteSide;
            tokenAmounts[q] += tokenSide;
        }
    }

    /// @inheritdoc IRealmLpLocker
    function nextWall(address token, address quote)
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint256 tokenId)
    {
        int24 rangeStart;
        (rangeStart, tickLower, tickUpper) = _wallRange(_wallKey(token, quote), quote);
        tokenId = wallAt[token][quote][rangeStart];
    }

    /// @notice Every position registered under `token`, in registration order.
    function positionIds(address token) external view returns (uint256[] memory) {
        return _positionIds[token];
    }

    /// @dev Uncollected fees of position `id`, per pool side, and the pool's `currency0`.
    function _owed(uint256 id) private view returns (address c0, uint256 owed0, uint256 owed1) {
        (PoolKey memory key, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(id);
        c0 = Currency.unwrap(key.currency0);
        (owed0, owed1) = _owedIn(key.toId(), info.tickLower(), info.tickUpper(), id);
    }

    /// @dev `_owed`'s arithmetic, split out for the stack. Mirrors v4-core's `Position.update`.
    function _owedIn(PoolId poolId, int24 lower, int24 upper, uint256 id)
        private
        view
        returns (uint256 owed0, uint256 owed1)
    {
        (uint128 liquidity, uint256 last0, uint256 last1) =
            POOL_MANAGER.getPositionInfo(poolId, address(POSITION_MANAGER), lower, upper, bytes32(id));
        (uint256 inside0, uint256 inside1) = POOL_MANAGER.getFeeGrowthInside(poolId, lower, upper);
        // Fee growth wraps by design; v4-core subtracts it unchecked too.
        unchecked {
            owed0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            owed1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    ////////////////////////////// HELPERS //////////////////////////////

    function _balance(address currency) private view returns (uint256) {
        return currency == address(0) ? address(this).balance : IERC20(currency).balanceOf(address(this));
    }

    function _send(address currency, address to, uint256 amount) private {
        if (currency != address(0)) {
            IERC20(currency).safeTransfer(to, amount);
            return;
        }
        (bool ok,) = to.call{value: amount}("");
        require(ok, NativeTransferFailed());
    }
}
