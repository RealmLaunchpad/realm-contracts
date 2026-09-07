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

/// @notice Minimal surface the graduator and taxable tokens call to add single-sided ETH liquidity.
interface IRealmUniV4LiquidityAdder {
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
}

/// @title RealmUniV4LiquidityAdder
/// @notice Permissionless, stateless helper that turns native ETH into a SINGLE-SIDED ETH Uniswap-V4
///         liquidity position — a protective bid wall placed just below the current price. The pair is
///         `(currency0, currency1) = (ETH, token)`, so an ETH-only position lives at ticks ABOVE the
///         current tick (= below the current price in ETH/token terms); as the token price falls, that
///         ETH is progressively spent buying the token, cushioning the drop. No token custody and no
///         swaps: only native ETH is settled.
/// @dev Shared by `RealmGraduatorUniswapV4` (its secondary graduation position) and the taxable tokens'
///      liquidity earnings leg (`processLiquidity`). Holds no funds between calls: the minted NFT goes to
///      `nftReceiver` and any dust ETH is swept to `excessEthReceiver` within the same call. The position
///      NFT is never withdrawable here, so wherever the caller points it the liquidity is permanent pool
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

    /// @notice Uniswap V4 position manager that mints the liquidity positions.
    IPositionManager public immutable UNIV4_POSITION_MANAGER;

    /// @notice Uniswap V4 pool manager, read for the pool's current tick.
    IPoolManager public immutable UNIV4_POOL_MANAGER;

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

    constructor(address positionManager, address poolManager) {
        UNIV4_POSITION_MANAGER = IPositionManager(positionManager);
        UNIV4_POOL_MANAGER = IPoolManager(poolManager);
    }

    /// @inheritdoc IRealmUniV4LiquidityAdder
    /// @dev `[tickLower, tickUpper]` MUST sit entirely above the pool's current tick, otherwise the
    ///      position would require token1 (the token) that this call does not settle and the mint
    ///      reverts. Sizes the position from all of `msg.value`.
    function addSingleSidedEth(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        address nftReceiver,
        address excessEthReceiver
    ) external payable returns (uint128 liquidity) {
        require(msg.value > 0, NoEthProvided());
        liquidity = _mintSingleSidedEth(key, tickLower, tickUpper, nftReceiver, excessEthReceiver);
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
        liquidity = _mintSingleSidedEth(key, tickLower, tickUpper, nftReceiver, excessEthReceiver);
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
        require(tickWidth > 0, InvalidTickWidth());
        (, int24 currentTick,,) = UNIV4_POOL_MANAGER.getSlot0(key.toId());

        (usedTokenId, usedTickLower) = _nearestReusable(currentTick, reuseMaxGap, candidateIds, candidateTickLowers);
        if (usedTokenId != 0) {
            require(IERC721(address(UNIV4_POSITION_MANAGER)).ownerOf(usedTokenId) == msg.sender, NotPositionOwner());
            liquidity = _topUpSingleSidedEth(key, usedTokenId, excessEthReceiver);
            return (liquidity, usedTokenId, usedTickLower);
        }

        // The id the mint is about to consume: `nextTokenId` is assigned before it is incremented.
        usedTokenId = UNIV4_POSITION_MANAGER.nextTokenId();
        int24 tickUpper;
        (usedTickLower, tickUpper) = _wallRangeBelowPrice(currentTick, tickWidth, key.tickSpacing);
        liquidity = _mintSingleSidedEth(key, usedTickLower, tickUpper, nftReceiver, excessEthReceiver);
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
        uint256[2] calldata ids,
        int24[2] calldata tickLowers
    ) internal pure returns (uint256 id, int24 tickLower) {
        for (uint256 i = 0; i < 2; ++i) {
            int24 candidate = tickLowers[i];
            if (ids[i] == 0 || currentTick >= candidate || candidate - currentTick > reuseMaxGap) continue;
            if (id == 0 || candidate < tickLower) (id, tickLower) = (ids[i], candidate);
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
    function _topUpSingleSidedEth(PoolKey calldata key, uint256 tokenId, address excessEthReceiver)
        internal
        returns (uint128 liquidity)
    {
        uint128 liquidityBefore = UNIV4_POSITION_MANAGER.getPositionLiquidity(tokenId);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SETTLE),
            uint8(Actions.INCREASE_LIQUIDITY_FROM_DELTAS),
            uint8(Actions.TAKE_PAIR),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        // `payerIsUser` is irrelevant for native: the settle draws on the `msg.value` forwarded below.
        params[0] = abi.encode(key.currency0, msg.value, false);
        // amount0Max = msg.value (slippage cap), amount1Max = 0 (ETH-only, checked on the principal delta).
        // The cast is not cosmetic: the position manager decodes these fields with a raw `calldataload`,
        // so an over-wide value would be read back dirty rather than truncated.
        // forge-lint: disable-next-line(unsafe-typecast)
        params[1] = abi.encode(tokenId, uint128(msg.value), uint128(0), bytes(""));
        params[2] = abi.encode(key.currency0, key.currency1, excessEthReceiver); // TAKE_PAIR
        params[3] = abi.encode(key.currency0, excessEthReceiver); // SWEEP native ETH dust

        UNIV4_POSITION_MANAGER.modifyLiquidities{value: msg.value}(abi.encode(actions, params), block.timestamp);
        liquidity = UNIV4_POSITION_MANAGER.getPositionLiquidity(tokenId) - liquidityBefore;
    }

    /// @dev The spacing-aligned wall range starting just below the current price. Shared by
    ///      `addSingleSidedEthBelowPrice` and the mint half of `addOrTopUpSingleSidedEth`.
    function _wallRangeBelowPrice(int24 currentTick, int24 tickWidth, int24 spacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        tickLower = _ceilToSpacing(currentTick + 1, spacing);
        // Clamp the top to the highest spacing-aligned tick: a deeply depreciated pool (current tick
        // within `tickWidth` of MAX_TICK) gets a narrower wall instead of a TickMath revert.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 maxUsableTick = (TickMath.MAX_TICK / spacing) * spacing;
        tickUpper = tickLower + tickWidth;
        if (tickUpper > maxUsableTick) tickUpper = maxUsableTick;
        require(tickLower < tickUpper, WallOutOfRange());
    }

    /// @dev Sizes single-sided-ETH liquidity for `[tickLower, tickUpper]` from `msg.value` and mints it via
    ///      the position manager, sending the NFT to `nftReceiver` and sweeping any leftover ETH to
    ///      `excessEthReceiver`. Mirrors `RealmGraduatorUniswapV4._addLiquidity` for the ETH-only case (the
    ///      `amount1` bound is 0, and the SWEEP returns the rounding dust rather than leaving it stuck).
    function _mintSingleSidedEth(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        address nftReceiver,
        address excessEthReceiver
    ) internal returns (uint128 liquidity) {
        liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), msg.value
        );

        // Dust that sizes to nothing goes straight back: v4-core's `Position.update` reverts
        // `CannotUpdateEmptyPosition` on a zero `liquidityDelta`, and a graduation whose secondary
        // position is pure rounding remainder must not take the whole graduation down with it.
        if (liquidity == 0) {
            (bool returned,) = excessEthReceiver.call{value: msg.value}("");
            require(returned, EthReturnFailed());
            return 0;
        }

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        // MINT_POSITION: amount0Max = msg.value (slippage cap), amount1Max = 0 (ETH-only).
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, msg.value, uint256(0), nftReceiver, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1); // SETTLE_PAIR
        params[2] = abi.encode(key.currency0, excessEthReceiver); // SWEEP native ETH dust

        UNIV4_POSITION_MANAGER.modifyLiquidities{value: msg.value}(abi.encode(actions, params), block.timestamp);
    }

    /// @dev Smallest multiple of `spacing` that is `>= tick`. Solidity `%` keeps the dividend's sign, so a
    ///      positive remainder means truncation rounded down (positive ticks) and we bump up; a
    ///      non-positive remainder already left us at or above `tick` (exact, or negative ticks where
    ///      truncation rounds toward zero).
    function _ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24 rounded) {
        // Floor-to-grid then correct up: the divide-before-multiply is the intent (snap to a spacing grid).
        // forge-lint: disable-next-line(divide-before-multiply)
        rounded = (tick / spacing) * spacing;
        if (tick % spacing > 0) rounded += spacing;
    }
}
