// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Everything `addOrTopUpSingleSided` needs beyond the pool and the caller's wall memory.
///         Grouped into a struct so the call fits the stack without `via_ir`.
struct WallParams {
    /// @dev Side of the pair to deposit. `address(0)` is native, settled from `msg.value`; an ERC20 is
    ///      pulled from the caller, who must have approved this contract for `amount`.
    Currency currency;
    /// @dev How much of `currency` to place.
    uint256 amount;
    /// @dev Width of a FRESH wall, in ticks. Also how the reuse check recovers a remembered wall's far
    ///      bound from the lower tick the caller kept.
    int24 tickWidth;
    /// @dev How far the price may have moved away from a remembered wall and still have it topped up
    ///      rather than replaced.
    int24 reuseMaxGap;
    /// @dev Where the position NFT and the remainder both go. One address, not two: the caller of this
    ///      form owns the position AND is where the remainder belongs, and splitting them would let a
    ///      passer-by route a top-up's collected fees somewhere the owner did not choose.
    address receiver;
}

/// @notice Minimal surface the graduators and taxable tokens call to add single-sided liquidity.
interface IRealmUniV4LiquidityAdder {
    function addSingleSided(
        PoolKey calldata key,
        Currency currency,
        uint256 amount,
        int24 tickLower,
        int24 tickUpper,
        address nftReceiver,
        address excessReceiver
    ) external payable returns (uint128 liquidity);

    function addSingleSidedEth(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        address nftReceiver,
        address excessEthReceiver
    ) external payable returns (uint128 liquidity);

    function addSingleSidedEthBelowPrice(
        PoolKey calldata key,
        int24 tickWidth,
        address nftReceiver,
        address excessEthReceiver
    ) external payable returns (uint128 liquidity);

    function addOrTopUpSingleSidedEth(
        PoolKey calldata key,
        int24 tickWidth,
        int24 reuseMaxGap,
        uint256[2] calldata candidateIds,
        int24[2] calldata candidateTickLowers,
        address nftReceiver,
        address excessEthReceiver
    ) external payable returns (uint128 liquidity, uint256 usedTokenId, int24 usedTickLower);

    function addOrTopUpSingleSided(
        PoolKey calldata key,
        WallParams calldata p,
        uint256[2] calldata candidateIds,
        int24[2] calldata candidateTickLowers
    ) external payable returns (uint128 liquidity, uint256 usedTokenId, int24 usedTickLower);
}

/// @title RealmUniV4LiquidityAdder
/// @notice Permissionless, stateless helper that turns ONE side of a pair into a SINGLE-SIDED Uniswap-V4
///         liquidity position. Two shapes, one primitive:
///         - The NATIVE side (`currency0` on every Realm pool) becomes a protective bid wall placed just
///           below the current price. An ETH-only position lives at ticks ABOVE the current tick (= below
///           the current price in ETH/token terms); as the token price falls that ETH is progressively
///           spent buying the token, cushioning the drop.
///         - The TOKEN side (`currency1`) becomes a launch band: a position entirely BELOW the current
///           tick holds only the token, and buyers walk up into it. This is how the direct-launch venue
///           seeds a pool with supply and no quote at all.
///         No swaps: exactly one currency is ever settled.
/// @dev Shared by `RealmGraduatorUniswapV4` (its secondary graduation position),
///      `RealmDirectGraduatorUniV4` (the launch band) and the taxable tokens' liquidity earnings leg
///      (`processLiquidity`). Holds no funds between calls: the minted NFT goes to `nftReceiver` and
///      whatever the sizing rounded off goes to `excessReceiver` within the same call. The position NFT
///      is never withdrawable here, so wherever the caller points it the liquidity is permanent pool
///      depth.
/// @dev MINTING is permissionless — anyone may place a fresh wall on any pool. TOPPING UP an existing
///      position is not: it requires the owner's ERC721 approval (v4's `onlyIfApproved`) AND that the
///      owner is the caller. Granting that approval is safe precisely because this contract is
///      non-upgradeable and its whole surface adds liquidity: there is no decrease, no burn and no
///      transfer to reach, so an approved-for-all operator can only ever make a position bigger.
/// @dev The `SWEEP` action sends the POSITION MANAGER's whole native balance to `excessEthReceiver`, not
///      just this call's rounding dust. That is not a drain primitive this contract creates: v4's
///      `PositionManager.modifyLiquidities` is itself permissionless and `SWEEP` is reachable through it
///      directly, so anyone can already claim anything the POSM holds — which is nothing, by design: it
///      settles every delta inside the unlock and holds no native across transactions. Sweeping "all"
///      rather than "mine" is the only shape v4 offers, and the two are the same amount here.
contract RealmUniV4LiquidityAdder is IRealmUniV4LiquidityAdder {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice Uniswap V4 position manager that mints the liquidity positions.
    IPositionManager public immutable UNIV4_POSITION_MANAGER;

    /// @notice Uniswap V4 pool manager, read for the pool's current tick.
    IPoolManager public immutable UNIV4_POOL_MANAGER;

    /// @notice Permit2, the only way the position manager pulls an ERC20 settle. Only the ERC20 half of
    ///         `addSingleSided` touches it; the native paths settle straight from `msg.value`.
    address public immutable PERMIT2;

    /// @notice Thrown when called with no ETH — there is nothing to deposit.
    error NoEthProvided();
    /// @notice Thrown when the requested tick width is not strictly positive.
    error InvalidTickWidth();
    /// @notice Thrown by `addSingleSidedEthBelowPrice` when the current tick is so close to `MAX_TICK`
    ///         (token price collapsed to the absolute tick boundary, ~1e-39 native per token) that no
    ///         spacing-aligned range fits above it. Reverting leaves the caller's ETH with the caller.
    error WallOutOfRange();
    /// @notice Thrown when `msg.value` sized to no liquidity and returning it to `excessEthReceiver`
    ///         failed. Only reachable from a receiver that rejects native.
    error EthReturnFailed();
    /// @notice Thrown when a top-up names a position the caller does not own. Minting stays open to
    ///         anyone; topping up does not, because an increase also collects the position's accrued fees
    ///         into the deltas, and this call hands those to a receiver the CALLER names.
    error NotPositionOwner();
    /// @notice Thrown when `currency` is neither side of `key`, or when the value sent does not match
    ///         the side being deposited (native needs `msg.value == amount`, ERC20 needs none).
    error CurrencyMismatch();

    constructor(address positionManager, address poolManager, address permit2) {
        UNIV4_POSITION_MANAGER = IPositionManager(positionManager);
        UNIV4_POOL_MANAGER = IPoolManager(poolManager);
        PERMIT2 = permit2;
    }

    /// @inheritdoc IRealmUniV4LiquidityAdder
    /// @dev The general form: deposit `amount` of ONE side of `key` into `[tickLower, tickUpper]`, which
    ///      must sit entirely on the side of the current tick that makes the position single-sided in
    ///      that currency — above it for `currency0`, below it for `currency1`. Otherwise the mint would
    ///      need the other side, which this call does not settle, and reverts.
    /// @dev Native is settled from `msg.value` (which must equal `amount`); an ERC20 is PULLED from
    ///      `msg.sender`, who must have approved this contract for `amount`. Whatever the sizing rounds
    ///      off goes to `excessReceiver` in the same call — this contract never holds funds between them.
    function addSingleSided(
        PoolKey calldata key,
        Currency currency,
        uint256 amount,
        int24 tickLower,
        int24 tickUpper,
        address nftReceiver,
        address excessReceiver
    ) external payable returns (uint128 liquidity) {
        require(amount > 0, NoEthProvided());
        bool isCurrency1 = Currency.unwrap(currency) == Currency.unwrap(key.currency1);
        require(isCurrency1 || Currency.unwrap(currency) == Currency.unwrap(key.currency0), CurrencyMismatch());
        // Native settles from the forwarded value; an ERC20 settles from a pull, so any value sent
        // alongside it would strand here.
        require(msg.value == (currency.isAddressZero() ? amount : 0), CurrencyMismatch());

        if (currency.isAddressZero()) {
            return _mintSingleSided(key, isCurrency1, amount, tickLower, tickUpper, nftReceiver, excessReceiver);
        }

        IERC20 asset = IERC20(Currency.unwrap(currency));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        _approveForSettle(asset);

        // Measured around the mint, not derived from the sizing: the position manager pulls only what the
        // mint actually owes, and the `SWEEP` action only ever hands back NATIVE — so on the ERC20 side
        // the rounding remainder would otherwise stay here, where the next caller's mint would spend it.
        // `balanceBefore` is read after the pull, so `balanceBefore - amount` is the pre-existing balance
        // this call must leave untouched.
        uint256 balanceBefore = asset.balanceOf(address(this));
        liquidity = _mintSingleSided(key, isCurrency1, amount, tickLower, tickUpper, nftReceiver, excessReceiver);
        uint256 unspent = asset.balanceOf(address(this)) + amount - balanceBefore;
        if (unspent > 0) asset.safeTransfer(excessReceiver, unspent);
    }

    /// @inheritdoc IRealmUniV4LiquidityAdder
    /// @dev `[tickLower, tickUpper]` MUST sit entirely above the pool's current tick, otherwise the
    ///      position would require token1 (the token) that this call does not settle and the mint
    ///      reverts. Sizes the position from all of `msg.value`. A thin wrapper over `addSingleSided`
    ///      for the native side, kept because the graduator and every token's liquidity leg call it.
    function addSingleSidedEth(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        address nftReceiver,
        address excessEthReceiver
    ) external payable returns (uint128 liquidity) {
        require(msg.value > 0, NoEthProvided());
        liquidity = _mintSingleSided(key, false, msg.value, tickLower, tickUpper, nftReceiver, excessEthReceiver);
    }

    /// @inheritdoc IRealmUniV4LiquidityAdder
    /// @dev Reads the pool's current tick and places the wall in
    ///      `[snapUp(tick + 1), snapUp(tick + 1) + tickWidth]` — starting just below the current price and
    ///      spanning `tickWidth` ticks further down in price. A percentage drop maps to a CONSTANT
    ///      `tickWidth` (ticks are log-price), so callers pass a fixed, spacing-aligned width. The lower
    ///      bound is snapped strictly above the current tick so the whole range stays ETH-only.
    function addSingleSidedEthBelowPrice(
        PoolKey calldata key,
        int24 tickWidth,
        address nftReceiver,
        address excessEthReceiver
    ) external payable returns (uint128 liquidity) {
        require(msg.value > 0, NoEthProvided());
        require(tickWidth > 0, InvalidTickWidth());
        (, int24 currentTick,,) = UNIV4_POOL_MANAGER.getSlot0(key.toId());
        (int24 tickLower, int24 tickUpper) = _wallRangeBelowPrice(currentTick, tickWidth, key.tickSpacing);
        liquidity = _mintSingleSided(key, false, msg.value, tickLower, tickUpper, nftReceiver, excessEthReceiver);
    }

    /// @inheritdoc IRealmUniV4LiquidityAdder
    /// @dev Mechanism for a caller that keeps a small memory of the walls it already owns: rather than
    ///      minting a position per call, this tops one of them up when it is still usable, and mints only
    ///      when none is. A candidate qualifies while its range sits STRICTLY above the current tick —
    ///      what keeps it ETH-only, so an ETH-only add still settles — and no further above it than
    ///      `reuseMaxGap`, which is what stops the ETH being parked in a wall the price has long left
    ///      behind. The NEAREST qualifying candidate wins; a zero id is an empty slot.
    /// @dev The reuse POLICY (how many candidates, how wide a gap, what to do with the answer) stays with
    ///      the caller: this contract holds no state and just executes the choice. Returns the position it
    ///      used and that position's lower tick so the caller can update its own memory, or `(0, 0)` when
    ///      nothing was placed — the zero-liquidity refund branch, where no id was consumed.
    /// @dev Topping up needs the position manager's `onlyIfApproved`, so the NFT owner must have approved
    ///      this contract, and only that owner may drive it (`NotPositionOwner`). Minting stays open to
    ///      anyone. The owner gate is what makes the approval safe to grant: nothing here can decrease,
    ///      burn or transfer a position, and the one thing a top-up DOES pay out — the fees an increase
    ///      collects into the deltas — can now only be routed by the owner, not by a passer-by who adds a
    ///      wei to someone else's wall.
    function addOrTopUpSingleSidedEth(
        PoolKey calldata key,
        int24 tickWidth,
        int24 reuseMaxGap,
        uint256[2] calldata candidateIds,
        int24[2] calldata candidateTickLowers,
        address nftReceiver,
        address excessEthReceiver
    ) external payable returns (uint128 liquidity, uint256 usedTokenId, int24 usedTickLower) {
        require(msg.value > 0, NoEthProvided());
        excessEthReceiver; // the general form below sends the NFT and the remainder to one receiver
        return _addOrTopUp(
            key,
            WallParams({
                currency: key.currency0,
                amount: msg.value,
                tickWidth: tickWidth,
                reuseMaxGap: reuseMaxGap,
                receiver: nftReceiver
            }),
            candidateIds,
            candidateTickLowers
        );
    }

    /// @inheritdoc IRealmUniV4LiquidityAdder
    /// @dev The general form: the wall is placed in `currency`, on whichever side of the current tick
    ///      holds only that currency — above it for `currency0`, below it for `currency1`. An ERC20 is
    ///      PULLED from `msg.sender`, who must have approved this contract for `amount`.
    /// @dev One `receiver` rather than two: the caller of this form owns the position AND is where the
    ///      remainder belongs, and splitting them would let a passer-by route a top-up's collected fees
    ///      somewhere the owner did not choose.
    function addOrTopUpSingleSided(
        PoolKey calldata key,
        WallParams calldata p,
        uint256[2] calldata candidateIds,
        int24[2] calldata candidateTickLowers
    ) external payable returns (uint128 liquidity, uint256 usedTokenId, int24 usedTickLower) {
        require(p.amount > 0, NoEthProvided());
        require(msg.value == (p.currency.isAddressZero() ? p.amount : 0), CurrencyMismatch());
        if (p.currency.isAddressZero()) return _addOrTopUp(key, p, candidateIds, candidateTickLowers);

        IERC20 asset = IERC20(Currency.unwrap(p.currency));
        asset.safeTransferFrom(msg.sender, address(this), p.amount);
        _approveForSettle(asset);
        // A fresh mint's `SETTLE_PAIR` pulls only what the position owes, so the rounding remainder is
        // returned from the measured balance, as in `addSingleSided`.
        uint256 balanceBefore = asset.balanceOf(address(this));
        (liquidity, usedTokenId, usedTickLower) = _addOrTopUp(key, p, candidateIds, candidateTickLowers);
        uint256 unspent = asset.balanceOf(address(this)) + p.amount - balanceBefore;
        if (unspent > 0) asset.safeTransfer(p.receiver, unspent);
    }

    /// @dev Shared body: top one of the caller's remembered walls up when it is still usable, mint a
    ///      fresh one when none is. A candidate qualifies while its range sits STRICTLY on the
    ///      single-sided side of the current tick — what keeps it one-currency, so a one-currency add
    ///      still settles — and no further from it than `reuseMaxGap`, which is what stops the deposit
    ///      being parked in a wall the price has long left behind. The NEAREST qualifying candidate
    ///      wins; a zero id is an empty slot.
    /// @dev The reuse POLICY (how many candidates, how wide a gap, what to do with the answer) stays
    ///      with the caller: this contract holds no state and just executes the choice. Returns the
    ///      position it used and that position's lower tick so the caller can update its own memory, or
    ///      `(0, 0)` when nothing was placed — the zero-liquidity refund branch, where no id was used.
    /// @dev Topping up needs the position manager's `onlyIfApproved`, so the NFT owner must have
    ///      approved this contract, and only that owner may drive it (`NotPositionOwner`). Minting stays
    ///      open to anyone. The owner gate is what makes the approval safe to grant: nothing here can
    ///      decrease, burn or transfer a position, and the one thing a top-up DOES pay out — the fees an
    ///      increase collects into the deltas — can only be routed by the owner.
    function _addOrTopUp(
        PoolKey calldata key,
        WallParams memory p,
        uint256[2] calldata candidateIds,
        int24[2] calldata candidateTickLowers
    ) internal returns (uint128 liquidity, uint256 usedTokenId, int24 usedTickLower) {
        require(p.tickWidth > 0, InvalidTickWidth());
        bool isCurrency1 = Currency.unwrap(p.currency) == Currency.unwrap(key.currency1);
        require(isCurrency1 || Currency.unwrap(p.currency) == Currency.unwrap(key.currency0), CurrencyMismatch());
        (, int24 currentTick,,) = UNIV4_POOL_MANAGER.getSlot0(key.toId());

        (usedTokenId, usedTickLower) =
            _nearestReusable(currentTick, p.reuseMaxGap, isCurrency1, p.tickWidth, candidateIds, candidateTickLowers);
        if (usedTokenId != 0) {
            require(IERC721(address(UNIV4_POSITION_MANAGER)).ownerOf(usedTokenId) == msg.sender, NotPositionOwner());
            liquidity = _topUpSingleSided(key, p.currency, usedTokenId, p.amount, isCurrency1, p.receiver);
            return (liquidity, usedTokenId, usedTickLower);
        }

        // The id the mint is about to consume: `nextTokenId` is assigned before it is incremented.
        usedTokenId = UNIV4_POSITION_MANAGER.nextTokenId();
        int24 tickUpper;
        (usedTickLower, tickUpper) = _wallRange(currentTick, p.tickWidth, key.tickSpacing, isCurrency1);
        liquidity = _mintSingleSided(key, isCurrency1, p.amount, usedTickLower, tickUpper, p.receiver, p.receiver);
        // Nothing was minted, so no id was consumed and there is no wall for the caller to remember.
        if (liquidity == 0) return (0, 0, 0);
    }

    /// @dev The nearest candidate still entirely above `currentTick` and within `reuseMaxGap` of it, or a
    ///      zero id when neither qualifies. Nearest, not first: a price that zigzags can leave the OLDER
    ///      candidate closer to the tick, and topping up the deeper of two is exactly what the gap bound
    ///      exists to prevent.
    function _nearestReusable(
        int24 currentTick,
        int24 reuseMaxGap,
        bool isCurrency1,
        int24 tickWidth,
        uint256[2] calldata ids,
        int24[2] calldata tickLowers
    ) internal pure returns (uint256 id, int24 tickLower) {
        for (uint256 i = 0; i < 2; ++i) {
            int24 lower = tickLowers[i];
            if (ids[i] == 0) continue;
            if (isCurrency1) {
                // A `currency1`-only position lives entirely BELOW the current tick, so its UPPER bound
                // is what has to clear it. The caller remembers only the lower tick, and every wall this
                // contract mints is `tickWidth` wide, so the upper is recoverable from the two.
                int24 upper = lower + tickWidth;
                if (currentTick <= upper || currentTick - upper > reuseMaxGap) continue;
                if (id == 0 || lower > tickLower) (id, tickLower) = (ids[i], lower);
            } else {
                if (currentTick >= lower || lower - currentTick > reuseMaxGap) continue;
                if (id == 0 || lower < tickLower) (id, tickLower) = (ids[i], lower);
            }
        }
    }

    /// @dev Adds all of `msg.value` to an existing ETH-only position, returning the liquidity it gained.
    /// @dev SETTLE first, then `INCREASE_LIQUIDITY_FROM_DELTAS`: the position manager sizes the add from
    ///      the resulting credit and the position's OWN recorded range, so this never has to re-derive a
    ///      range the caller only half-remembers.
    /// @dev `TAKE_PAIR`, not `SETTLE_PAIR`: after the settle both deltas are credits, never debts — the
    ///      leftover ETH the sizing rounded off, plus any fees the position accrued (an increase folds
    ///      those into the deltas). Both go to `excessEthReceiver`, which is why the token side can never
    ///      strand here.
    /// @dev No zero-liquidity guard, unlike the mint: a candidate's range sits entirely above the current
    ///      tick and liquidity per ETH grows with that distance, so any non-zero `msg.value` sizes to at
    ///      least one unit.
    function _topUpSingleSided(
        PoolKey calldata key,
        Currency currency,
        uint256 tokenId,
        uint256 amount,
        bool isCurrency1,
        address receiver
    ) internal returns (uint128 liquidity) {
        uint128 liquidityBefore = UNIV4_POSITION_MANAGER.getPositionLiquidity(tokenId);

        // `SWEEP` only when the pool has a native side to sweep — see the note in `_mintSingleSided`.
        bytes memory actions = key.currency0.isAddressZero()
            ? abi.encodePacked(
                uint8(Actions.SETTLE),
                uint8(Actions.INCREASE_LIQUIDITY_FROM_DELTAS),
                uint8(Actions.TAKE_PAIR),
                uint8(Actions.SWEEP)
            )
            : abi.encodePacked(
                uint8(Actions.SETTLE), uint8(Actions.INCREASE_LIQUIDITY_FROM_DELTAS), uint8(Actions.TAKE_PAIR)
            );
        bytes[] memory params = new bytes[](key.currency0.isAddressZero() ? 4 : 3);
        // Native settles from the value forwarded below (`payerIsUser = false`: the position manager's
        // own balance). An ERC20 must be pulled from THIS contract through Permit2 (`payerIsUser = true`):
        // with `false` the position manager would pay out of its own, empty, balance.
        params[0] = abi.encode(currency, amount, !currency.isAddressZero());
        // The deposited side's max is `amount` (slippage cap), the other side's is 0 — checked on the
        // principal delta. The cast is not cosmetic: the position manager decodes these fields with a
        // raw `calldataload`, so an over-wide value would be read back dirty rather than truncated.
        // forge-lint: disable-next-line(unsafe-typecast)
        params[1] = abi.encode(
            tokenId,
            // forge-lint: disable-next-line(unsafe-typecast)
            isCurrency1 ? uint128(0) : uint128(amount),
            // forge-lint: disable-next-line(unsafe-typecast)
            isCurrency1 ? uint128(amount) : uint128(0),
            bytes("")
        );
        params[2] = abi.encode(key.currency0, key.currency1, receiver); // TAKE_PAIR
        if (params.length == 4) params[3] = abi.encode(key.currency0, receiver); // SWEEP native dust

        UNIV4_POSITION_MANAGER.modifyLiquidities{value: currency.isAddressZero() ? amount : 0}(
            abi.encode(actions, params), block.timestamp
        );
        liquidity = UNIV4_POSITION_MANAGER.getPositionLiquidity(tokenId) - liquidityBefore;
    }

    /// @dev The spacing-aligned wall range starting just below the current price. Shared by
    ///      `addSingleSidedEthBelowPrice` and the mint half of `addOrTopUpSingleSidedEth`.
    function _wallRangeBelowPrice(int24 currentTick, int24 tickWidth, int24 spacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        return _wallRange(currentTick, tickWidth, spacing, false);
    }

    /// @dev The spacing-aligned wall range just below the current PRICE OF THE TOKEN, on whichever side
    ///      of the current tick holds only the wall's currency.
    ///      - `currency0` (native on every Realm pool): ticks ABOVE the current one. Price in this pair
    ///        is token-per-quote, so a higher tick is a cheaper token — the wall sits under the price.
    ///      - `currency1` (an ERC20 quote that sorted second): ticks BELOW the current one, for exactly
    ///        the same reason mirrored.
    ///      Either way the range is clamped to the usable band, so a pool at an extreme gets a narrower
    ///      wall instead of a `TickMath` revert.
    function _wallRange(int24 currentTick, int24 tickWidth, int24 spacing, bool isCurrency1)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        // Snapping to the spacing grid is the intent, not an accident of ordering.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 maxUsableTick = (TickMath.MAX_TICK / spacing) * spacing;
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 minUsableTick = (TickMath.MIN_TICK / spacing) * spacing;

        if (isCurrency1) {
            tickUpper = _floorToSpacing(currentTick - 1, spacing);
            tickLower = tickUpper - tickWidth;
            if (tickLower < minUsableTick) tickLower = minUsableTick;
        } else {
            tickLower = _ceilToSpacing(currentTick + 1, spacing);
            tickUpper = tickLower + tickWidth;
            if (tickUpper > maxUsableTick) tickUpper = maxUsableTick;
        }
        require(tickLower < tickUpper && tickLower >= minUsableTick && tickUpper <= maxUsableTick, WallOutOfRange());
    }

    /// @dev Grants the position manager, through Permit2, the standing allowance its ERC20 settle needs.
    ///      Read-then-write: after the first deposit of a given asset both approvals are already at their
    ///      maximum, and re-issuing them would cost two SSTOREs and two logs per call for nothing. The
    ///      allowance is unbounded but harmless — this contract only ever holds an asset WITHIN a call,
    ///      and the position manager can only pull what a mint it is executing actually owes.
    function _approveForSettle(IERC20 asset) internal {
        if (asset.allowance(address(this), PERMIT2) == 0) asset.forceApprove(PERMIT2, type(uint256).max);
        (uint160 allowed,,) =
            IAllowanceTransfer(PERMIT2).allowance(address(this), address(asset), address(UNIV4_POSITION_MANAGER));
        if (allowed == 0) {
            IAllowanceTransfer(PERMIT2)
                .approve(address(asset), address(UNIV4_POSITION_MANAGER), type(uint160).max, type(uint48).max);
        }
    }

    /// @dev Sizes single-sided liquidity for `[tickLower, tickUpper]` from `amount` of ONE side and mints
    ///      it via the position manager, sending the NFT to `nftReceiver` and returning whatever the
    ///      sizing rounded off to `excessReceiver`. Mirrors `RealmGraduatorUniswapV4._addLiquidity` for
    ///      the single-sided case: the other side's `amountMax` bound is 0, and the remainder comes back
    ///      rather than sticking here.
    /// @param isCurrency1 Which side `amount` is denominated in. `false` = `currency0` (the native side
    ///        on every Realm pool, settled from the forwarded value); `true` = `currency1`, settled from
    ///        this contract's own balance through Permit2.
    function _mintSingleSided(
        PoolKey calldata key,
        bool isCurrency1,
        uint256 amount,
        int24 tickLower,
        int24 tickUpper,
        address nftReceiver,
        address excessReceiver
    ) internal returns (uint128 liquidity) {
        liquidity = isCurrency1
            ? LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount
            )
            : LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount
            );

        // Dust that sizes to nothing goes straight back: v4-core's `Position.update` reverts
        // `CannotUpdateEmptyPosition` on a zero `liquidityDelta`, and a graduation whose secondary
        // position is pure rounding remainder must not take the whole graduation down with it.
        if (liquidity == 0) {
            _returnUnspent(key, isCurrency1, amount, excessReceiver);
            return 0;
        }

        // NATIVE is a property of the CURRENCY, not of which index it sits at. On a pool quoted in the
        // chain's native currency that is always `currency0`, but against an ERC20 quote the token
        // itself can sort first — and forwarding `amount` as value for an ERC20 deposit would send funds
        // this contract does not have.
        bool poolHasNative = key.currency0.isAddressZero();

        // The `SWEEP` leg exists only for a pool with a native side: it returns the value forwarded
        // below that the mint did not consume. An all-ERC20 pool forwards nothing, and its rounding
        // remainder comes back through `addSingleSided`'s measured balance delta instead.
        bytes[] memory params = new bytes[](poolHasNative ? 3 : 2);
        // MINT_POSITION: the deposited side's max is `amount` (slippage cap), the other side's is 0.
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            liquidity,
            isCurrency1 ? uint256(0) : amount,
            isCurrency1 ? amount : uint256(0),
            nftReceiver,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1); // SETTLE_PAIR
        if (poolHasNative) params[2] = abi.encode(key.currency0, excessReceiver); // SWEEP native dust

        UNIV4_POSITION_MANAGER.modifyLiquidities{value: poolHasNative && !isCurrency1 ? amount : 0}(
            abi.encode(
                poolHasNative
                    ? abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP))
                    : abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)),
                params
            ),
            block.timestamp
        );
    }

    /// @dev Hands `amount` of the deposited side back to `excessReceiver`, in that side's own currency —
    ///      an ERC20 quote can sit at `currency0` too. The native leg is a raw call whose failure must
    ///      revert: the caller's funds are in this contract and there is nowhere else for them to go.
    function _returnUnspent(PoolKey calldata key, bool isCurrency1, uint256 amount, address excessReceiver) internal {
        Currency currency = isCurrency1 ? key.currency1 : key.currency0;
        if (!currency.isAddressZero()) {
            IERC20(Currency.unwrap(currency)).safeTransfer(excessReceiver, amount);
            return;
        }
        (bool returned,) = excessReceiver.call{value: amount}("");
        require(returned, EthReturnFailed());
    }

    /// @dev Smallest multiple of `spacing` that is `>= tick`. Solidity `%` keeps the dividend's sign, so a
    ///      positive remainder means truncation rounded down (positive ticks) and we bump up; a
    ///      non-positive remainder already left us at or above `tick` (exact, or negative ticks where
    ///      truncation rounds toward zero).
    /// @dev Largest multiple of `spacing` that is `<= tick`. The mirror of `_ceilToSpacing`: Solidity
    ///      `%` keeps the dividend's sign, so a negative remainder means truncation rounded UP (negative
    ///      ticks) and we push back down.
    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24 rounded) {
        // forge-lint: disable-next-line(divide-before-multiply)
        rounded = (tick / spacing) * spacing;
        if (tick % spacing < 0) rounded -= spacing;
    }

    function _ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24 rounded) {
        // Floor-to-grid then correct up: the divide-before-multiply is the intent (snap to a spacing grid).
        // forge-lint: disable-next-line(divide-before-multiply)
        rounded = (tick / spacing) * spacing;
        if (tick % spacing > 0) rounded += spacing;
    }
}
