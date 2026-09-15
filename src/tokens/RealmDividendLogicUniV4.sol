// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmTaxableTokenUniV4Base, IRealmV4Graduator} from "src/tokens/RealmTaxableTokenUniV4Base.sol";
// Self-aliased so the `chain-*` recipes can import-swap it for the target chain's pool constants.
import {UniswapV4PoolConstants as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {ERC20, IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IRealmUniV4LiquidityAdder} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";

/// @title RealmDividendLogicUniV4
/// @notice The dividend extension `RealmTaxableTokenUniV4` `delegatecall`s its out-of-band entry
///         points into: the round machinery, the native -> payout-asset conversion, and the per-holder
///         push. Deployed once, by the token implementation's own constructor.
/// @dev It shares `RealmTaxableTokenUniV4Base` with the token and adds NO state of its own, so the
///      compiler derives the same storage layout for both — the property the delegatecall depends on.
///      Pinned by `just check-dividend-layout`.
contract RealmDividendLogicUniV4 is RealmTaxableTokenUniV4Base, DividendDistributionLogic {
    //////////////////////// BURN (delegated from the token) //////////////////////

    /// @notice Buys back tokens with the accrued burn ETH and burns them, reducing total supply.
    ///         Permissionless in spirit but keeper-gated in practice: the accrued ETH is
    ///         protocol-committed to burning, so any KEEPER may trigger it (holders don't depend on the
    ///         creator staying active). Batches many small accruals into one swap, off the swap hot path.
    ///         Spends at most `MAX_EARNINGS_PER_PROCESS` per call, once per block (`ProcessCooldown`), so
    ///         a sandwiching manipulator's per-block take is capped; the remainder stays buffered.
    /// @param minTokensOut Slippage floor — the minimum tokens the buy-back must yield, or the swap
    ///        reverts. Callers should set this from the current price; a value of 0 invites sandwiching.
    /// @dev The buy-back is an ordinary pool swap, so `RealmSwapHook` charges its usual LP fee (and,
    ///      inside the launch tax window, tax — a fraction of which loops back into `burnPendingEth`
    ///      for the next call). This is accepted rather than special-casing the audited hook.
    function processBurn(uint256 minTokensOut) external nonReentrant {
        // Keeper-gated: the caller supplies the floor, so a permissionless caller could set it to zero
        // around their own price manipulation and keep almost the whole spend. See `RealmKeepersRegistry`.
        _requireKeeper();
        // Once per block + capped spend: bounds what a sandwich can extract per manipulated block once
        // the caller can no longer choose the floor. It is a second bound, not the first one.
        require(block.number > lastBurnProcessBlock, ProcessCooldown());
        lastBurnProcessBlock = uint48(block.number);

        uint256 ethIn = burnPendingEth;
        require(ethIn > 0, NothingToBurn());
        if (ethIn > MAX_EARNINGS_PER_PROCESS) ethIn = MAX_EARNINGS_PER_PROCESS;
        burnPendingEth -= ethIn;

        address hook = IRealmV4Graduator(graduator).HOOK_ADDRESS();
        uint256 balanceBefore = balanceOf(address(this));
        // Balance AND reserves, NOT the raw balance `processLiquidity` can use and NOT the clamped
        // `_sweepableNative()`: this one is a SWAP, so the hook's `accrueFees` lands native here
        // mid-call, raising the balance and the buffers by the same amount (the fund slice leaves
        // immediately). Tracking the two separately lets that accrual cancel while the router's spend
        // still shows. `burnPendingEth` was debited above, so `ethIn` is unreserved for the call.
        uint256 balanceBeforeEth = address(this).balance;
        uint256 reservedBefore = _reservedNative();
        // Precursor marker: must stay BEFORE the swap so indexers can classify the resulting
        // `RealmSwapHook.RealmSwapBuy` as a protocol buy-back rather than a trade by `tx.origin`.
        emit BuyBackInitiated(ethIn);
        require(_buyBackTokensWithEth(hook, ethIn, minTokensOut), BuyBackFailed());
        uint256 tokensBought = balanceOf(address(this)) - balanceBefore;

        // Whatever the pool did not take came back with the router's `SWEEP` and stays earmarked for
        // burning, mirroring `processLiquidity`: without this the unspent remainder rejoins the stray
        // pool and `sweepStrayEth` re-splits it into the fund / dividend / liquidity buckets, spending
        // an allocation meant for burning.
        // `spent = (balance drop) + (reserve growth)`, the same shape `_acquireDividendAsset` uses and
        // for the same reason: `_sweepableNative()` CLAMPS AT ZERO, and a native dividend payout
        // reentering here mid-`claimDividends` (the balance already sent, `dividendsOwed` not yet
        // reduced) pins both readings to zero — reporting a spend of 0 and re-crediting the whole
        // `ethIn` that the swap really consumed. Arranged so neither side can underflow.
        uint256 lhs = balanceBeforeEth + _reservedNative();
        uint256 rhs = address(this).balance + reservedBefore;
        uint256 ethSpent = lhs > rhs ? lhs - rhs : 0;
        if (ethSpent < ethIn) burnPendingEth += ethIn - ethSpent;

        // An EXTERNAL self-call, not `_burn`. `_burn` would drag `RealmToken._update` — the anti-sniper
        // caps and the dividend share tracking — into this extension's bytecode, and at ~7.4 KB that is
        // room it does not have under EIP-170 (the whole reason the cold half lives here). Routing
        // through the token's own `burn()` keeps the identical `Transfer(token, 0, amount)` semantics
        // with the code on the side that already carries it: under `delegatecall` `address(this)` IS the
        // token, so `msg.sender` is the token and `ERC20Burnable.burn` burns exactly this balance.
        if (tokensBought > 0) ERC20Burnable(address(this)).burn(tokensBought);
        // Reports the ETH the pool ACTUALLY took, as `processLiquidity` does with `ethAdded`.
        emit CreatorTaxBurn(ethSpent, tokensBought);
    }

    //////////////////////// LIQUIDITY (delegated from the token) //////////////////////

    /// @notice Deposits the accrued liquidity ETH as a single-sided ETH position just below the current
    ///         price — a protective bid wall. Both placing and reusing run through the shared
    ///         `RealmUniV4LiquidityAdder`: this token only keeps the memory of the two walls it most
    ///         recently used and the policy (`LIQUIDITY_WALL_TICK_WIDTH`, `LIQUIDITY_WALL_REUSE_MAX_GAP`)
    ///         that decides between topping one of them up and minting a fresh one.
    ///         Keeper-gated and off the swap hot path, mirroring `processBurn`. Positions are held by this
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
        // price the caller has arranged. See `RealmKeepersRegistry`.
        _requireKeeper();
        // Once per block + capped spend: bounds what a manipulated wall placement can extract per block.
        require(block.number > lastLiquidityProcessBlock, ProcessCooldown());
        lastLiquidityProcessBlock = uint48(block.number);

        uint256 ethIn = liquidityPendingEth;
        require(ethIn > 0, NothingToAdd());
        if (ethIn > MAX_EARNINGS_PER_PROCESS) ethIn = MAX_EARNINGS_PER_PROCESS;
        liquidityPendingEth -= ethIn;

        PoolKey memory key =
            UniswapV4PoolConstants.realmPoolKey(address(this), IRealmV4Graduator(graduator).HOOK_ADDRESS());
        address adder = IRealmV4Graduator(graduator).LIQUIDITY_ADDER();

        // The adder needs the position manager's `onlyIfApproved` to top up a wall this token owns.
        // Granted on demand rather than once: it self-heals if the graduator ever points at a different
        // adder — where a one-shot grant would leave `processLiquidity` reverting on every reusable
        // wall. The adder is already trusted with the ETH handed to it, cannot decrease, burn or
        // transfer a position, and comes from the same graduator that names the hook mediating every
        // swap. Read-then-write rather than an unconditional `setApprovalForAll`: the SSTORE is
        // same-value after the first call but the `ApprovalForAll` LOG is not free, and re-emitting it
        // on every single `processLiquidity` is noise every indexer has to filter.
        if (!IERC721(UNIV4_POSITION_MANAGER).isApprovedForAll(address(this), adder)) {
            IERC721(UNIV4_POSITION_MANAGER).setApprovalForAll(adder, true);
        }

        // NFT and leftover ETH both return to this token (permanent depth; the ETH stays earmarked). The
        // adder picks between topping up one of the remembered walls and minting a fresh one, and reports
        // back which position took the ETH so the memory below can be updated.
        uint256 balanceBefore = address(this).balance;
        (uint256[2] memory ids, int24[2] memory tickLowers) = getLiquidityWalls();
        (uint128 liquidity, uint256 usedId, int24 usedTickLower) = IRealmUniV4LiquidityAdder(adder)
        .addOrTopUpSingleSidedEth{value: ethIn}(
            key, LIQUIDITY_WALL_TICK_WIDTH, LIQUIDITY_WALL_REUSE_MAX_GAP, ids, tickLowers, address(this), address(this)
        );
        // A zero id means nothing was placed and the ETH came back — no wall to record.
        if (usedId != 0) _recordUsedWall(usedId, usedTickLower);

        // Whatever was not placed stays earmarked for liquidity, mirroring the V2 processor:
        // `liquidityPendingEth` was debited by the full `ethIn` above, so without this the unplaced
        // remainder silently rejoins the stray-ETH pool and `sweepStrayEth` re-splits it into the burn /
        // dividend / fund buckets. Ways to get one: `ethIn` sized to zero liquidity and was never spent,
        // or the add's `SWEEP` returned the rounding dust.
        // ⚠️ CLAMPED, not a plain subtraction. The balance can also come back HIGHER than it went out:
        // the top-up path is `INCREASE_LIQUIDITY_FROM_DELTAS` + `TAKE_PAIR`, and v4 folds a position's
        // `feesAccrued` into those deltas, so a reused wall whose accrued native fees exceed the
        // principal being added returns more than `ethIn`. Unreachable while
        // `UniswapV4PoolConstants.LP_FEE == 0` (the hook charges the fee instead, so these positions
        // accrue nothing), but a non-zero or dynamic pool fee would turn a bare subtraction into a
        // panic that bricks `processLiquidity` on the reuse path until the price moved far enough to
        // force a fresh mint. Clamping degrades that into "nothing was placed": the full `ethIn` is
        // re-earmarked and the surplus becomes stray native, which `sweepStrayEth` routes correctly.
        uint256 balanceAfter = address(this).balance;
        uint256 ethAdded = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (ethAdded < ethIn) liquidityPendingEth += ethIn - ethAdded;

        // Shared event signature; reports the ETH the pool ACTUALLY took, as the V2 processor does. The
        // token side is always 0 for the single-sided ETH wall.
        emit LiquidityAdded(ethAdded, 0, liquidity);
    }

    //////////////////////// DIVIDENDS //////////////////////

    /// @dev Adds the SELF-TOKEN payout shape: V4 is ETH-native, so a token paying dividends in itself
    ///      buys itself back on its own pool, reusing the same primitive `processBurn` uses. Native and
    ///      third-asset payouts fall through to the base.
    /// @dev The precursor event must stay BEFORE the swap: an indexer has to classify the resulting
    ///      `RealmSwapHook.RealmSwapBuy` as protocol-internal as it arrives, whereas anything emitted after
    ///      the swap lands once the keeper's PnL has already been updated.
    function _acquireDividendAsset(address asset, uint256 nativeIn, uint256 minOut)
        internal
        override
        returns (uint256)
    {
        if (asset != address(this)) return super._acquireDividendAsset(asset, nativeIn, minOut);

        address hook = IRealmV4Graduator(graduator).HOOK_ADDRESS();
        uint256 balanceBefore = balanceOf(address(this));
        // Balance AND reserves, not either alone. A buy-back is a SWAP, so the hook's `accrueFees` lands
        // native here mid-call: it raises the balance and the buffers together, and only the router's
        // spend moves the two apart. `_sweepableNative()` is the same quantity but CLAMPED at zero, and
        // the clamp bites exactly here — `pendingNative` still holds the amount being spent (the base
        // debits it after this returns), so the token is fully reserved and stray reads 0 both times.
        uint256 balanceBeforeEth = address(this).balance;
        uint256 reservedBefore = _reservedNative();
        emit DividendBuyBackInitiated(nativeIn);
        _buyBackTokensWithEth(hook, nativeIn, minOut);
        uint256 bought = balanceOf(address(this)) - balanceBefore;

        // Nothing bought: the base either leaves the buffer alone or sweeps the whole `nativeIn` to the
        // treasury, and both of those already account for the native the router handed back. Re-earmarking
        // here would double-count it.
        if (bought == 0) return 0;

        // The base is about to debit the FULL `nativeIn`, so whatever the pool did not take — returned by
        // the router's `SWEEP` on a partial fill — has to go back on the dividend ledger. Without this it
        // becomes stray and `sweepStrayEth` re-splits holders' money into the burn / liquidity / fund
        // buckets. Read defensively: assuming the whole spend merely under-credits, an underflow would
        // revert a good conversion.
        // `spent = (balance drop) + (reserve growth)`, arranged so neither side can underflow: an
        // accrual that lands mid-swap shows up in both terms and cancels out.
        uint256 lhs = balanceBeforeEth + _reservedNative();
        uint256 rhs = address(this).balance + reservedBefore;
        uint256 spent = lhs > rhs ? lhs - rhs : 0;
        // Asset 0 by construction: a self-token payout may only be configured as the SOLE asset, so this
        // branch is only ever reached for index 0 and there is no other buffer the refund could belong to.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (spent < nativeIn) {
            // forge-lint: disable-next-line(unsafe-typecast)
            dividendAssets[0].pendingNative = uint88(dividendAssets[0].pendingNative + (nativeIn - spent));
        }

        return bought;
    }

    /// @notice Creation-time dividend configuration, executed here on the token's storage. Guarded by
    ///         the transient `tokenFactory`, which the `delegatecall` shares with the token.
    function initializeEarningsAllocation(
        uint16 _burnBps,
        uint16 _dividendsBps,
        uint16 _liquidityBps,
        address _dividendToken
    ) external override {
        require(msg.sender == tokenFactory, Unauthorized());
        _initializeEarningsAllocation(_burnBps, _dividendsBps, _liquidityBps);
        if (_dividendsBps != 0) {
            (address[] memory tokens, uint16[] memory weights) = _soleAssetSet(_dividendToken);
            // No routes: the legacy single-asset shape predates them, and an empty route is exactly the
            // permissionless V2 pair it always meant.
            dividendAssetCount = _initializeDividends(tokens, weights, new bytes[](0));
            hasDividends = true;
        }
    }

    /// @notice Multi-asset creation-time dividend configuration. See
    ///         `RealmTaxableToken.initializeEarningsAllocation(uint16,uint16,uint16,address[],uint16[])`.
    function initializeEarningsAllocation(
        uint16 _burnBps,
        uint16 _dividendsBps,
        uint16 _liquidityBps,
        address[] calldata _dividendTokens,
        uint16[] calldata _dividendWeightsBps,
        bytes[] calldata _dividendRoutes
    ) external override {
        require(msg.sender == tokenFactory, Unauthorized());
        _initializeEarningsAllocation(_burnBps, _dividendsBps, _liquidityBps);
        if (_dividendsBps != 0) {
            dividendAssetCount = _initializeDividends(_dividendTokens, _dividendWeightsBps, _dividendRoutes);
            hasDividends = true;
        }
    }

    ////////////////// NOT A TOKEN //////////////////
    // An extension is only ever reached through a `delegatecall` from a token, so its own copy of the
    // token's behaviour is dead weight — and, at ~7.4 KB, dead weight it cannot afford: the extension is
    // bound by the same EIP-170 limit as the token it serves. Reverting each entry point makes the
    // machinery behind it unreachable and the compiler drops it: the transfer hook with its anti-sniper
    // and dividend tracking, the tax-config views and their decay arithmetic, the earnings split and the
    // fee-handler deposit. Measured on the V2 extension: 19,748 -> 12,322 bytes of inherited surface,
    // which is what buys the cold half its room. The reverts are also the honest answer — none of these
    // has anything to act on here.

    /// @dev Only here because `IRealmTaxableToken` declares it. The storage every entry point touches
    ///      belongs to the token that `delegatecall`s in, so there is nothing here to initialize.
    function initialize(IRealmToken.InitializeParams memory, TaxConfigs memory, AntiSniperConfigs memory)
        external
        pure
    {
        revert NotAToken();
    }

    /// @dev The base token's own entry point; same reasoning as the 3-arg one above.
    function initialize(IRealmToken.InitializeParams memory, AntiSniperConfigs memory) external pure override {
        revert NotAToken();
    }

    /// @dev With every mint/transfer entry point stubbed, nothing reaches `_update` and the compiler drops
    ///      the whole transfer hook (`SniperProtection`, dividend share tracking) — the single largest saving.
    function transfer(address, uint256) public pure override(ERC20, IERC20) returns (bool) {
        revert NotAToken();
    }

    function transferFrom(address, address, uint256) public pure override(ERC20, IERC20) returns (bool) {
        revert NotAToken();
    }

    /// @dev Stubbed for the same reason `transfer` is — `_burn` reaches `_update` too, and `processBurn`
    ///      above deliberately routes its burn through an EXTERNAL call to the token's own `burn()` so
    ///      that path stays on the side that already carries the hot-path bytecode.
    function burn(uint256) public pure override {
        revert NotAToken();
    }

    function burnFrom(address, uint256) public pure override {
        revert NotAToken();
    }

    function markGraduated() external pure override {
        revert NotAToken();
    }

    function rescueTokens(address) external pure override {
        revert NotAToken();
    }

    function setTaxBps(uint16, uint16) external pure override {
        revert NotAToken();
    }

    function accrueFees() external payable override {
        revert NotAToken();
    }

    /// @dev The second entry point into the earnings split, stubbed for the same reason `accrueFees` is:
    ///      an extension holds no balance, so it has no stray native — and leaving it live would link
    ///      `_allocateEthEarnings` and everything under it back into this contract's bytecode.
    function sweepStrayEth() external pure override {
        revert NotAToken();
    }

    function getLaunchpadFees(IRealmToken.LaunchpadTrade calldata)
        external
        pure
        override
        returns (IRealmToken.LaunchpadFees memory)
    {
        revert NotAToken();
    }

    function getTaxConfig() external pure override returns (TaxConfig memory) {
        revert NotAToken();
    }

    function getSwapFees(bool) external pure override returns (IRealmToken.RealmTradeFees memory) {
        revert NotAToken();
    }

    function initializeEarningsAllocation(uint16, uint16, uint16) external pure override {
        revert NotAToken();
    }

    /// @dev The cold half is already inline here, so the token stubs this contract inherits would
    ///      `delegatecall` into itself if they were ever reached. They are not: `DividendDistributionLogic`
    ///      carries the real bodies.
    function dividendLogic() public view override returns (address) {
        return address(this);
    }
}
