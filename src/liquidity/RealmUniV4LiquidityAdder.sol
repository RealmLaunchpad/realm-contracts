// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {UniversalRouterVenue} from "src/libraries/UniversalRouterVenue.sol";

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

    function topUpSingleSided(
        PoolKey calldata key,
        Currency currency,
        uint256 amount,
        uint256 tokenId,
        address receiver
    ) external payable returns (uint128 liquidity);
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
/// @dev Shared by `RealmDirectGraduatorUniV4` (the launch band) and the taxable tokens' liquidity earnings leg
///      (`processLiquidity`). Holds no funds between calls: the minted NFT goes to `nftReceiver` and
///      whatever the sizing rounded off goes to `excessReceiver` within the same call. The position NFT
///      is never withdrawable here, so wherever the caller points it the liquidity is permanent pool
///      depth.
/// @dev MINTING is permissionless — anyone may place a fresh wall on any pool. TOPPING UP an existing
///      position is not: it requires the owner's ERC721 approval (v4's `onlyIfApproved`) AND that the
///      owner is the caller. Granting that approval is safe precisely because this contract is
///      non-upgradeable and its whole surface adds liquidity: there is no decrease, no burn and no
///      transfer to reach, so an approved-for-all operator can only ever make a position bigger.
/// @dev The `SWEEP` action sends the POSITION MANAGER's whole native balance to the excess receiver, not
///      just this call's rounding dust. That is not a drain primitive this contract creates: v4's
///      `PositionManager.modifyLiquidities` is itself permissionless and `SWEEP` is reachable through it
///      directly, so anyone can already claim anything the POSM holds — which is nothing, by design: it
///      settles every delta inside the unlock and holds no native across transactions. Sweeping "all"
///      rather than "mine" is the only shape v4 offers, and the two are the same amount here.
contract RealmUniV4LiquidityAdder is IRealmUniV4LiquidityAdder {
    /// @notice Contract version.
    uint256 public constant VERSION = 1;

    using SafeERC20 for IERC20;

    /// @notice Uniswap V4 position manager that mints the liquidity positions.
    IPositionManager public immutable UNIV4_POSITION_MANAGER;

    /// @notice Permit2, the only way the position manager pulls an ERC20 settle. Only the ERC20 half of
    ///         `addSingleSided` touches it; the native paths settle straight from `msg.value`.
    address public immutable PERMIT2;

    /// @notice Thrown when called with no ETH — there is nothing to deposit.
    error NoEthProvided();
    /// @notice Thrown when `msg.value` sized to no liquidity and returning it to `excessReceiver`
    ///         failed. Only reachable from a receiver that rejects native.
    error EthReturnFailed();
    /// @notice Thrown when a top-up names a position the caller does not own. Minting stays open to
    ///         anyone; topping up does not, because an increase also collects the position's accrued fees
    ///         into the deltas, and this call hands those to a receiver the CALLER names.
    error NotPositionOwner();
    /// @notice Thrown when `currency` is neither side of `key`, or when the value sent does not match
    ///         the side being deposited (native needs `msg.value == amount`, ERC20 needs none).
    error CurrencyMismatch();

    constructor(address positionManager, address permit2) {
        UNIV4_POSITION_MANAGER = IPositionManager(positionManager);
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
    /// @dev Adds `amount` of `currency` to the caller's existing position `tokenId`, whose range must
    ///      still sit entirely on the side of the current tick that holds only `currency`. The leftover
    ///      the sizing rounds off, and any fees the increase folds into the deltas, go to `receiver`. An
    ///      ERC20 is PULLED from `msg.sender`, who must have approved this contract for `amount`.
    /// @dev Topping up needs the position manager's `onlyIfApproved`, so the NFT owner must have approved
    ///      this contract, and only that owner may drive it (`NotPositionOwner`). The owner gate is what
    ///      makes the approval safe to grant: nothing here can decrease, burn or transfer a position, and
    ///      the one thing a top-up DOES pay out — the fees an increase collects into the deltas — can only
    ///      be routed by the owner, not by a passer-by who adds a wei to someone else's position.
    function topUpSingleSided(
        PoolKey calldata key,
        Currency currency,
        uint256 amount,
        uint256 tokenId,
        address receiver
    ) external payable returns (uint128 liquidity) {
        require(amount > 0, NoEthProvided());
        require(msg.value == (currency.isAddressZero() ? amount : 0), CurrencyMismatch());
        bool isCurrency1 = Currency.unwrap(currency) == Currency.unwrap(key.currency1);
        require(isCurrency1 || Currency.unwrap(currency) == Currency.unwrap(key.currency0), CurrencyMismatch());
        require(IERC721(address(UNIV4_POSITION_MANAGER)).ownerOf(tokenId) == msg.sender, NotPositionOwner());
        if (currency.isAddressZero()) return _topUpSingleSided(key, currency, tokenId, amount, isCurrency1, receiver);

        IERC20 asset = IERC20(Currency.unwrap(currency));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        _approveForSettle(asset);
        // Pulled through Permit2 only as far as the increase owes; the remainder is returned from the
        // measured balance, as in `addSingleSided`.
        uint256 balanceBefore = asset.balanceOf(address(this));
        liquidity = _topUpSingleSided(key, currency, tokenId, amount, isCurrency1, receiver);
        uint256 unspent = asset.balanceOf(address(this)) + amount - balanceBefore;
        if (unspent > 0) asset.safeTransfer(receiver, unspent);
    }

    /// @dev Adds `amount` of `currency` to an existing single-sided position, returning the liquidity it gained.
    /// @dev SETTLE first, then `INCREASE_LIQUIDITY_FROM_DELTAS`: the position manager sizes the add from
    ///      the resulting credit and the position's OWN recorded range, so the caller never passes one.
    /// @dev `TAKE_PAIR`, not `SETTLE_PAIR`: after the settle both deltas are credits, never debts — the
    ///      leftover the sizing rounded off, plus any fees the position accrued (an increase folds
    ///      those into the deltas). Both go to `receiver`, which is why the token side can never
    ///      strand here.
    /// @dev No zero-liquidity guard, unlike the mint: an existing position's range sits entirely on the
    ///      deposited side of the current tick, so any non-zero amount sizes to at least one unit.
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

    /// @dev Grants the position manager, through Permit2, the standing allowance its ERC20 settle needs.
    ///      Read-then-write: after the first deposit of a given asset both approvals are already at their
    ///      maximum, and re-issuing them would cost two SSTOREs and two logs per call for nothing. The
    ///      allowance is unbounded but harmless — this contract only ever holds an asset WITHIN a call,
    ///      and the position manager can only pull what a mint it is executing actually owes.
    function _approveForSettle(IERC20 asset) internal {
        UniversalRouterVenue.ensureRouterPull(PERMIT2, address(UNIV4_POSITION_MANAGER), address(asset));
    }

    /// @dev Sizes single-sided liquidity for `[tickLower, tickUpper]` from `amount` of ONE side and mints
    ///      it via the position manager, sending the NFT to `nftReceiver` and returning whatever the
    ///      sizing rounded off to `excessReceiver`. Single-sided: the other side's `amountMax` bound is 0, and the remainder comes back
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
}
