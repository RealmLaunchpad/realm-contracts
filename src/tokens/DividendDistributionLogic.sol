// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IRealmDividendSwapRegistry} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

/// @title DividendDistributionLogic
/// @notice The COLD half of `DividendDistribution`: the native -> payout-asset conversion, the stream
///         funding, and the per-holder push. Everything here runs out-of-band, driven by a keeper or a
///         holder — never from a transfer or a swap.
///
/// @dev ONE ENTRY POINT PER ASSET for the keeper. `processDividends(index, ...)` converts that asset's
///      buffer, folds the proceeds into its running stream and pushes its payouts, doing whichever of
///      the three there is anything to do. They were three separate transactions and a round state
///      machine once, and there was never a reason for it: the anti-flash-loan property comes from the
///      DRIP, not from a transaction boundary or a phase, so the three collapse into one call that can
///      be made at any moment.
///
/// @dev ONE ASSET PER CALL, deliberately. Each asset crosses its threshold on its own schedule, prices
///      its slippage floor against its own pool and holds its own per-block cooldown, so a call that
///      tried to serve the whole set would need a floor per asset and would pay a transfer per asset per
///      holder. A keeper batches per asset instead, and the assets never contend.
///
/// @dev NOTHING HERE REVERTS FOR BEING EARLY. A distribution landing mid-stream is the normal case: it
///      folds the undelivered remainder into a fresh window and changes the slope. The only reverts are
///      for a call that could accomplish NOTHING — an empty push list against an unfundable buffer —
///      and they are there so a keeper's simulation gets a reason rather than a silent success.
///
/// @dev WHY THIS IS A SEPARATE CONTRACT. Taxable tokens are CLONES of a single implementation, and that
///      implementation has to fit in EIP-170's 24,576 bytes. The dividend engine did not fit alongside
///      the rest of the token, so this half — never on a hot path — lives behind a thin `delegatecall`
///      stub per entry point (see `RealmTaxableToken._delegateToDividendLogic`), in a contract
///      deployed ONCE per venue per chain by the token implementation's own constructor.
///
/// @dev The delegatecall means every line below runs in the TOKEN's context: `address(this)` is the
///      token, the payouts come out of the token's own balance, the events are emitted from the token's
///      address (so indexers see no change), and the `dividendLocked` transient guard is the token's.
///      Nothing is pooled and nothing is custodied here.
///
/// @dev ⚠️ STORAGE LAYOUT. This contract writes the token's storage directly, so the two layouts must be
///      byte-identical. The concrete extensions (`RealmDividendLogicUniV2` / `...UniV4`) inherit the same
///      venue base the token does and add no state of their own, so the compiler derives the layout for
///      both — never hand-maintain it. `just check-dividend-layout` fails if they ever drift.
///      The same applies to TRANSIENT slots, which is why `dividendLocked` stays declared in
///      `DividendDistribution` rather than moving here with the modifier's users.
abstract contract DividendDistributionLogic is DividendDistribution, KeeperGated, ReentrancyGuardTransient {
    /// @notice Thrown by every TOKEN entry point on an extension. An extension is an execution body for
    ///         a token, not a token: deployed once, never cloned, holding no balance, and its own
    ///         storage never read. Anyone reaching one of those entry points here has the wrong address.
    error NotAToken();

    /// @notice A distribution would have set a stream slope wider than `DivAsset.rate` can hold. Not
    ///         reachable with any asset the registry accepts — see `_fundDividendStream`.
    error DividendRateOverflow();

    /// @notice What `_fundDividends` found. A return value rather than a flag because the caller has to
    ///         distinguish "wait for earnings" from "the earnings are here and the swap is broken".
    enum FundOutcome {
        /// @dev Nothing buffered, or not enough of it yet. The quiet, normal answer.
        NotReady,
        /// @dev The stream is funded with `out` of the payout asset.
        Funded,
        /// @dev Enough was buffered and the conversion did not happen. The buffer is untouched.
        ConversionFailed,
        /// @dev Same as `ConversionFailed`, but this call put the failure ON RECORD for the treasury
        ///      sweep's persistence gate. Reported separately because it WROTE, so the caller must not
        ///      revert it away.
        FailureRecorded,
        /// @dev The conversion could not happen at ANY price, so that slice of the buffer went to
        ///      `DIVIDEND_TREASURY`. Nothing was streamed, and nothing accrued was written off.
        SweptToTreasury
    }

    //////////////////////// configuration //////////////////////

    /// @dev Stores the creation-time payout configuration: one to `MAX_DIVIDEND_ASSETS` assets and the
    ///      bps split of the dividends slice between them. Called once, by the token, only when the
    ///      earnings allocation routes a non-zero share to dividends.
    ///
    /// @dev THE REGISTRY IS THE ONLY JUDGE, and the creator never names a route: any ERC20 with a
    ///      Uniswap V2 pair deep enough to swap against is accepted with no whitelist and no per-asset
    ///      approval, and so is one a registry admin has given a curated Uniswap V4 route (the only way
    ///      an asset with no V2 pair at all — Robinhood Chain's xStocks — can be reached). Asking here
    ///      is what stops a creator from configuring a payout their own token could never convert into
    ///      — the failure mode a clone cannot be patched out of. Every asset in the set is asked.
    /// @dev The registry is a proxy behind a constant address, so a token created today is bound to the
    ///      RULE rather than to today's version of it: raising the threshold, blacklisting an asset or
    ///      adding a venue reaches this token too, for every conversion it has not made yet.
    ///
    /// @dev THE SET RULES, and why each one is a `require` rather than a normalization:
    ///      - 1..`MAX_DIVIDEND_ASSETS` assets. The transfer hook loops the set, so it is bounded in the
    ///        type as well as here.
    ///      - Weights non-zero and summing to `DIVIDEND_BPS_TOTAL`. A zero-weight asset is an asset that
    ///        can never be funded but is still settled on every transfer, i.e. pure cost; weights that
    ///        do not sum leave a slice of the dividends allocation stranded in no bucket at all.
    ///      - NO DUPLICATES. `committedDividends` is what keeps `rescueTokens` and `sweepStrayEth` off
    ///        holders' money, and it answers per asset — the same asset in two slots would have it report
    ///        one slot's debt and hand the other slot's to the owner. This is the one rule here whose
    ///        failure mode is a value leak rather than a dead configuration.
    ///      - `DIVIDEND_SELF_TOKEN` only when it is the SOLE asset. On Uniswap V2 that payout is carved
    ///        in token space out of the tax tokens and removes itself from the ETH split's denominator,
    ///        which is a whole-slice operation with no per-asset fraction; a V2 token that configured it
    ///        alongside others would buffer native it could never convert (a V2 pair reverts `INVALID_TO`
    ///        when asked to deliver a token to its own address). Rejected on both venues so the rule is
    ///        the same wherever a creator reads it.
    ///
    /// @dev ⚠️ ACCEPTED: THE ELIGIBILITY PROOF IS A SPOT READ AND CAN BE FLASH-PASSED. The registry
    ///      measures the pair's reserves at this instant, so a creator can add liquidity, create the
    ///      token, and pull the liquidity back out in the same transaction. What that buys them is
    ///      nothing: the registry re-checks eligibility on EVERY conversion, so the token simply never
    ///      converts that asset, and after `STALE_DIVIDEND_WINDOW` its buffer goes to `DIVIDEND_TREASURY`
    ///      rather than to the creator. Nothing is stolen from holders — they were promised a payout
    ///      asset the token cannot reach, which is a disclosure problem for the frontend, not a value
    ///      leak here. Making it un-fakeable would need depth measured across blocks, which is not worth
    ///      the permanent complexity for a gate whose only failure mode is a token that pays nobody.
    /// @param routes one per asset, in the `DividendRouteLib` wire format: the pools this token will
    ///        convert that asset through, for life. Empty for an asset bought on its permissionless V2
    ///        pair, which is also what a shorter array means for the assets it does not reach.
    /// @return count How many assets were configured, for the caller to store on the token.
    function _initializeDividends(address[] memory tokens, uint16[] memory weights, bytes[] memory routes)
        internal
        returns (uint8 count)
    {
        uint256 n = tokens.length;
        require(n != 0 && n <= MAX_DIVIDEND_ASSETS && weights.length == n, InvalidDividendAssetSet());
        require(routes.length <= n, InvalidDividendAssetSet());
        count = uint8(n);

        IRealmDividendSwapRegistry registry = IRealmDividendSwapRegistry(DIVIDEND_SWAP_REGISTRY);
        uint256 weightSum;
        for (uint256 i; i < count; ++i) {
            address token = tokens[i];
            // Resolve the "pay in the token itself" sentinel now, so every later read is a plain address.
            if (token == DIVIDEND_SELF_TOKEN) token = address(this);
            require(token != address(this) || count == 1, SelfTokenDividendMustBeSole());

            require(weights[i] != 0, InvalidDividendAssetSet());
            weightSum += weights[i];
            // Pairwise against the slots already written. At most three comparisons, and the reason is
            // on the docstring: a duplicate is the one misconfiguration that leaks value.
            for (uint256 j; j < i; ++j) {
                require(dividendAssets[j].token != token, InvalidDividendAssetSet());
            }

            // Native and the token itself are both 18-decimal and have nothing to buy: no pool, nothing
            // to prove, and no `decimals()` to ask (native has no contract, and self-calling this token
            // for a constant would be a wasted CALL).
            uint8 assetDecimals = 18;
            if (token != address(0) && token != address(this)) {
                // Registers AND validates in one call: the registry refuses a route whose pools are not
                // real, and stores the accepted one against this token. Write-once and unfixable
                // afterwards, which is why the refusal has to happen here, while the mistake is free.
                registry.registerRoute(token, i < routes.length ? routes[i] : bytes(""));
                // Not `try`/`catch`: an asset with no `decimals()` reverts the CREATION, which is the only
                // moment this is cheap to discover. Defaulting to 18 instead would silently under-scale
                // the accumulator for the rest of that token's life, and a clone cannot be patched.
                assetDecimals = IERC20Metadata(token).decimals();
            }

            dividendAssets[i].token = token;
            // Clamped rather than reverted above 36 decimals: an exponent of 0 is simply the coarsest
            // scale, and such an asset has so many units per whole token that it needs no help.
            dividendAssets[i].precisionExp =
                assetDecimals >= DIVIDEND_PRECISION_DECIMALS ? 0 : uint8(DIVIDEND_PRECISION_DECIMALS - assetDecimals);
            dividendWeightsBps[i] = weights[i];
            emit DividendAssetInitialized(i, token, weights[i]);
        }
        require(weightSum == DIVIDEND_BPS_TOTAL, InvalidDividendAssetSet());

        // Kept for the indexers and integrators written against the single-asset shape, which read the
        // payout asset off this event. Emitted last so the per-asset events describe the whole set first.
        emit DividendsInitialized(dividendAssets[0].token);
    }

    /// @dev Lifts a single payout asset into the one-entry set `_initializeDividends` consumes, so the
    ///      original single-asset `initializeEarningsAllocation` overload and the multi-asset one run
    ///      through exactly the same rules. A sole asset takes the whole dividends slice by definition.
    function _soleAssetSet(address asset) internal pure returns (address[] memory tokens, uint16[] memory weights) {
        tokens = new address[](1);
        tokens[0] = asset;
        weights = new uint16[](1);
        weights[0] = uint16(DIVIDEND_BPS_TOTAL);
    }

    //////////////////////// the distribution //////////////////////

    /// @notice Converts whatever has accrued to ONE payout asset, folds it into that asset's running
    ///         stream, and pushes its payouts to `holders`. The only entry point a keeper needs, called
    ///         once per asset.
    ///
    /// @dev Idempotent and unforgeable in the part that matters: the amounts are read from each holder's
    ///      own accrued balance, so a duplicate pays 0, an unknown address pays 0, and an omitted holder
    ///      loses nothing at all — their accrual keeps sitting there for the next batch or for their own
    ///      `claimDividends()`. A keeper is free to push only to holders above whatever size threshold
    ///      it likes; the small ones are not forfeiting anything by being skipped.
    ///
    /// @dev What gets funded, and when, is DERIVED: a function of that asset's buffer and the clock
    ///      alone. The only things a caller supplies are which asset and the slippage floor for its
    ///      conversion.
    ///
    /// @param assetIndex Which configured payout asset to service. Reverts past the configured count.
    /// @param minOut Slippage floor for the conversion, in that asset's own decimals. Ignored when the
    ///        asset is native or the token itself, and by any call that does not convert.
    /// @param holders Addresses to push accrued payouts to. May be empty — a fund-only call is a normal
    ///        thing for a keeper to make.
    /// @dev Takes the TOKEN's `nonReentrant` on top of `nonReentrantDividends`. The dividend lock alone
    ///      leaves `sweepStrayEth()` — which holds only the token's lock — free to run inside the
    ///      conversion, and the V4 self-token buy-back reconstructs what the pool took as
    ///      `(balance drop) + (reserve growth)`. A sweep landing mid-call raises the reserved side
    ///      without lowering the balance, so the spend is over-reported, the partial-fill refund is
    ///      skipped, and the buffer loses native the pool never received. `processBurn` and
    ///      `processLiquidity` already hold this lock; this was the one earnings entry point that did
    ///      not. Costs no SSTORE (transient) and blocks nothing legitimate: `accrueFees`, which the V4
    ///      hook calls back mid-swap, deliberately takes neither lock.
    function processDividends(uint8 assetIndex, uint256 minOut, address[] calldata holders)
        public
        nonReentrant
        nonReentrantDividends
    {
        require(assetIndex < _dividendAssetCount(), DividendAssetOutOfRange());
        DivAsset storage asset = dividendAssets[assetIndex];
        require(asset.periodFinish != 0, DividendsNotActive());

        // KEEPER-GATED, with staleness as the escape hatch. The conversion below takes its slippage
        // floor from the caller, so a permissionless caller could manipulate the payout pool, call in
        // with a zero floor and unwind, all in one transaction — see `RealmKeepersRegistry` for why no
        // depth threshold bounds that. Holders never depend on a keeper to be PAID: `claimDividends()`
        // is open to everyone and pays in full. What a keeper is needed for is moving the buffer.
        // The stale branch is the backstop for a keeper set that has gone away for good: after
        // `STALE_DIVIDEND_WINDOW` with no distribution, anyone may fund, because a buffer nobody can
        // ever convert is a worse outcome than one someone can convert badly.
        //
        // ⚠️ STALENESS ALONE IS NOT THAT SIGNAL for an asset that SWAPS. `dividendsStale` reads "no
        // distribution in a month", which a quiet token reaches in its ordinary steady state: a
        // low-volume token may simply never buffer `DIVIDEND_THRESHOLD` inside one window, with every
        // keeper present and working. Opening the gate there would hand any caller a zero-floor
        // conversion of a real buffer, every month, on every quiet token — the exact sandwich the
        // keeper set exists to prevent. So the bypass ALSO requires the buffer to have been convertible
        // all along: keepers are paid per conversion and fire as soon as the threshold is crossed, so
        // `DIVIDEND_THRESHOLD` left sitting for `STALE_DIVIDEND_WINDOW` is what actually evidences a
        // keeper set that is gone. A sub-threshold residual stays keeper-only — the smaller loss.
        // Assets whose funding does NOT swap keep the wide hatch (native, and the V2 self-token leg,
        // which is carved in token space and merely moves a buffer into the stream): there is nothing
        // for a caller to sandwich, so stranding is their only failure mode.
        {
            // Scoped: this function is already at the stack limit, so these must die before the loop.
            address payout = asset.token;
            bool swaps = payout != address(0) && !_isTokenSpaceDividendAsset(payout);
            if (!dividendsStale(assetIndex) || (swaps && asset.pendingNative < DIVIDEND_THRESHOLD)) {
                _requireKeeper();
            }
        }

        // Before anything else, for the reason the base spells out: the accumulator has to close the
        // interval that just ended at the supply that was actually in effect for it.
        (uint256 rpt,) = _syncDividend(assetIndex, 0);

        // Once per block PER ASSET, for exactly the reason `processBurn` and `processLiquidity` are: the
        // per-call cap only bounds what a manipulated block can yield if the block allows ONE conversion.
        // Without it a caller re-enters at the same distorted price until the buffer is gone, paying the
        // manipulation cost once instead of once per block. Per asset because the manipulation is of one
        // asset's pool and buys nothing in the others.
        // The gate is on the FUNDING leg ALONE. Pushing payouts is not rate-limited and must not be: a
        // keeper splitting a large holder set across several transactions in one block is ordinary, and
        // those calls read a buffer this one already resolved.
        bool cooldown = block.number <= asset.lastProcessBlock;

        FundOutcome outcome = FundOutcome.NotReady;
        uint256 nativeIn;
        uint256 out;
        if (!cooldown) {
            (outcome, nativeIn, out) = _fundDividends(assetIndex, minOut);
            // Claimed only when the buffer actually MOVED. A call that found nothing fundable, or whose
            // swap failed, spent nothing and must not lock the block against an honest keeper.
            if (outcome == FundOutcome.Funded || outcome == FundOutcome.SweptToTreasury) {
                // forge-lint: disable-next-line(unsafe-typecast)
                asset.lastProcessBlock = uint40(block.number);
            }
        }

        if (outcome == FundOutcome.Funded) {
            _fundDividendStream(assetIndex, out);
            // `rate` and `periodFinish` are read AFTER the fold-in, which is what makes them the
            // authoritative slope from this block on. `rpt` needs no re-read: funding moves the slope,
            // never the accumulator, so the value `_syncDividend` returned is still current.
            emit DividendsFunded(asset.token, nativeIn, out, asset.rate, asset.periodFinish);
        }

        if (holders.length != 0) {
            // The asset leg gets its own, far larger stipend: `NATIVE_PAYOUT_GAS` is sized for a wallet's
            // `receive()` and would starve an ordinary ERC20 `transfer`.
            address payoutAsset = asset.token;
            uint256 stipend = payoutAsset == address(0) ? NATIVE_PAYOUT_GAS : ASSET_PAYOUT_GAS;
            uint256 paid;
            for (uint256 i; i < holders.length; ++i) {
                paid += _payHolder(holders[i], assetIndex, payoutAsset, rpt, stipend);
            }
            _reduceDividendsOwed(assetIndex, paid);
        } else if (cooldown) {
            // Distinct from the two below on purpose: this keeper has to wait a block, not wait for
            // earnings or re-price a floor.
            revert DividendProcessCooldown();
        } else if (outcome == FundOutcome.NotReady) {
            // Two different situations, two different errors: a keeper that sees `BelowDividendThreshold`
            // has to wait for earnings, one that sees `DividendConversionFailed` has the earnings and a
            // swap problem — a `minOut` the pool has moved past, or a pool that is gone.
            revert BelowDividendThreshold();
        } else if (outcome == FundOutcome.ConversionFailed) {
            revert DividendConversionFailed();
        }
        // `SweptToTreasury` and `FailureRecorded` fall through: neither could stream anything, but both
        // CHANGED something — the buffer in one case, the sweep's persistence marker in the other — and
        // reverting would undo the very write the call was made to perform.
        // A call carrying holders never reverts for the buffer being short or the swap being broken: it
        // asked to push payouts, and it pushed them.
    }

    /// @notice The pre-multi-asset signature, servicing asset 0. Kept so keepers and scripts written
    ///         against single-asset tokens — which is what every token with one payout asset still is —
    ///         keep working unchanged.
    function processDividends(uint256 minOut, address[] calldata holders) external {
        processDividends(0, minOut, holders);
    }

    /// @notice Self-serve payout of everything the caller has accrued, in EVERY configured asset.
    /// @dev Forwards ALL remaining gas to a native payout instead of `NATIVE_PAYOUT_GAS`. The stipend
    ///      exists to stop one expensive fallback from starving the REST of a keeper batch; a self-serve
    ///      claim has no rest of a batch, and the caller is spending their own gas on their own payout.
    ///      This is what keeps the stipend a throughput knob rather than a permanent eligibility gate —
    ///      a holder whose wallet costs more than a batch will spend can still always be paid here.
    ///      Across assets that is safe for the same reason: an expensive receive can only starve the
    ///      claimer's own later legs, and they can re-claim.
    function claimDividends() external nonReentrantDividends {
        uint256 n = _dividendAssetCount();
        require(n != 0 && dividendAssets[0].periodFinish != 0, DividendsNotActive());

        uint256 supply;
        for (uint256 i; i < n; ++i) {
            uint256 rpt;
            (rpt, supply) = _syncDividend(i, supply);
            _reduceDividendsOwed(i, _payHolder(msg.sender, i, dividendAssets[i].token, rpt, gasleft()));
        }
    }

    //////////////////////// internal //////////////////////

    /// @dev Folds `amount` into asset `i`'s stream: whatever the running one still had to deliver is
    ///      added to it, and the sum is re-spread over a fresh full `DIVIDEND_DRIP_DURATION`. The slope
    ///      changes; nothing is ever rejected, delayed or carried over.
    ///
    /// @dev THE WHOLE POINT of re-spreading rather than appending: a stream that merely extended would
    ///      let a large distribution land at the old (small) slope, and the money would take
    ///      proportionally longer to reach holders the more of it there was. Re-spreading keeps the
    ///      delivery time constant and puts the size into the slope, which is the only variable a
    ///      flash-loan attacker cannot integrate against.
    function _fundDividendStream(uint256 i, uint256 amount) private {
        DivAsset storage a = dividendAssets[i];
        uint256 finish = a.periodFinish;
        uint256 remaining = finish > block.timestamp ? (finish - block.timestamp) * a.rate : 0;

        uint256 total = amount + remaining;
        uint256 duration = DIVIDEND_DRIP_DURATION;
        uint256 rate = total / duration;
        // A `uint96` holds 7.9e28 units per second, i.e. 7.1e31 units inside one 15-minute window. That
        // is 71 trillion whole tokens of an 18-decimal asset — but the payout asset is the CREATOR's
        // choice, and a quadrillion-supply memecoin with a barely-eligible pair can put a single 0.2 ETH
        // conversion over it. Reverting there would brick `processDividends` permanently on a token that
        // is otherwise fine, so the rate is CLAMPED and the window stretched to carry the same total
        // instead: everything is still delivered, just more slowly, which errs the safe way (a slower
        // slope is strictly harder to time into than a faster one).
        if (rate > type(uint96).max) {
            rate = type(uint96).max;
            duration = total / rate;
        }
        // The same clamp at the OTHER end. A total under `duration` base units truncates the slope to 0,
        // and `owed` would still grow by the whole `amount`: nothing would ever stream it to holders,
        // and `committedDividends` reserves it against every sweep and rescue, so it would be locked in
        // the contract forever. Only reachable for a payout asset with very few base units per unit of
        // value (a 0- or 2-decimal token). Shortening the window instead delivers exactly the same
        // total, one unit per second. `total != 0` here: `_fundDividends` only reports `Funded` with a
        // non-zero `out`.
        if (rate == 0) {
            rate = 1;
            duration = total;
        }
        // Now genuinely unreachable — `total` would have to exceed 8.7e40 units for the stretched window
        // to overflow the `uint40` clock — and a revert here leaves the buffer untouched.
        require(block.timestamp + duration <= type(uint40).max, DividendRateOverflow());

        // Owed grows by the whole distribution. Integer division leaves a sub-`duration` residue the
        // stream cannot deliver, which stays owed and simply never leaves the balance — dust, and dust
        // that errs towards holders rather than towards a sweep.
        // `uint128` holds 3.4e38 payout-asset units; `amount` is bounded by the conversion cap.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.owed = uint128(uint256(a.owed) + amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        a.rate = uint96(rate);
        // forge-lint: disable-next-line(unsafe-typecast)
        a.periodFinish = uint40(block.timestamp + duration);
        // The caller synced first, so this only ever moves the clock FORWARD across a gap between
        // streams — seconds in which the rate was zero and nothing could have accrued.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.lastUpdate = uint40(block.timestamp);
    }

    /// @dev Saturating on purpose. The accumulator truncates in the holders' favour at every step, so
    ///      `Σ payouts <= owed` holds by construction — but this runs in a non-upgradeable clone, and a
    ///      rounding surprise must degrade into a stale counter rather than into payouts that revert
    ///      forever.
    function _reduceDividendsOwed(uint256 i, uint256 paid) private {
        if (paid == 0) return;
        uint256 owed = dividendAssets[i].owed;
        // forge-lint: disable-next-line(unsafe-typecast)
        dividendAssets[i].owed = paid >= owed ? 0 : uint128(owed - paid);
    }

    /// @dev Turns asset `i`'s accrued buffer into payout-asset units, or reports why it could not.
    ///      Overridable so a venue can source the payout from somewhere other than the native buffer
    ///      (the V2 self-token payout, which is carved from tax tokens).
    function _fundDividends(uint256 i, uint256 minOut)
        internal
        virtual
        returns (FundOutcome, uint256 nativeIn, uint256 out)
    {
        DivAsset storage a = dividendAssets[i];
        uint256 buffered = a.pendingNative;
        if (buffered == 0) return (FundOutcome.NotReady, 0, 0);

        // The threshold exists so a distribution only fires when it is worth its gas, and staleness is
        // its ONLY bypass: a residual below the threshold on an asset nobody has converted for
        // `STALE_DIVIDEND_WINDOW` would otherwise strand forever. There is nothing to grief here any
        // more — a dust distribution just sets a dust slope, it cannot stall anything.
        bool stale = dividendsStale(i);
        if (buffered < DIVIDEND_THRESHOLD && !stale) return (FundOutcome.NotReady, 0, 0);

        address asset = a.token;
        // Only a payout that SWAPS is capped. Native is already denominated in the payout asset, so it
        // has no swap to sandwich, and throttling it would delay real money for no security gain.
        uint256 spend =
            (asset != address(0) && buffered > MAX_DIVIDEND_PER_CONVERSION) ? MAX_DIVIDEND_PER_CONVERSION : buffered;
        out = _acquireDividendAsset(asset, spend, minOut);

        if (out == 0) {
            // A conversion that did not happen must leave the buffer untouched, not burn it: the swap can
            // fail for reasons outside anyone's control — most often a floor the pool has merely moved
            // past — and the next call simply tries again with a floor priced off the live pool.
            if (minOut != 0) return (FundOutcome.ConversionFailed, 0, 0);

            // Zero floor and still nothing came back: the pool cannot produce a single wei at any price.
            // That is a SNAPSHOT, though, and a snapshot is manufacturable — and cheaply, because the
            // registry refuses whenever the pair's quote depth merely dips under its threshold, so one
            // sell causes the failure and one buy undoes it. TWO gates stand between that and a sweep,
            // and both have to hold:
            //   1. staleness — this asset's `periodFinish` only moves when a distribution SUCCEEDS, so a
            //      genuinely dead pool reaches it on its own a `STALE_DIVIDEND_WINDOW` after the last
            //      distribution, and an actively distributing asset never does;
            //   2. persistence — the same failure has to be on record from an EARLIER block, which costs
            //      a griefer a second round trip held across a block boundary, per slice.
            //
            // KNOWN LIMIT, accepted: staleness reads "no distribution in a month", which a dead pool
            // guarantees but does not uniquely cause, and persistence proves only that the failure
            // outlived a block. Neither is proof the pool is dead — they make manufacturing one cost real
            // money for a griefer who cannot profit (the native lands in Realm's own treasury, never
            // theirs) and holders are made whole off-chain. Do not read this gate as proof of anything
            // stronger.
            if (!stale) return (FundOutcome.ConversionFailed, 0, 0);

            uint256 recorded = a.failedConversionBlock;
            if (recorded == 0 || block.number <= recorded) {
                // First sighting (or a second one inside the same block, which proves nothing new).
                // Reported as `FailureRecorded`, not `ConversionFailed`: this branch WRITES, and the
                // caller reverts on `ConversionFailed` — which would roll the record back and leave the
                // gate unreachable forever. Same reasoning as the sweep's own fall-through below.
                // forge-lint: disable-next-line(unsafe-typecast)
                if (recorded != block.number) a.failedConversionBlock = uint40(block.number);
                return (FundOutcome.FailureRecorded, 0, 0);
            }

            // The pool has been failing across blocks, long enough that "try again" never terminates. The
            // slice goes to the treasury instead of sitting owed to holders forever — see the contract
            // docstring for why that beats repointing the asset.
            _sweepFailedConversion(i, asset, spend);
            return (FundOutcome.SweptToTreasury, 0, 0);
        }

        // A conversion went through, so whatever the marker was recording is over. Cleared under a guard
        // so the common path (nothing on record) pays no SSTORE.
        if (a.failedConversionBlock != 0) a.failedConversionBlock = 0;

        // Re-read rather than reuse `buffered`: the swap is an external call, and earnings that arrived
        // during it (`_accrueDividends` is not behind the dividend lock) must survive this write.
        // Bounded by the value read, which is already a `uint88`.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.pendingNative = uint88(a.pendingNative - spend);
        return (FundOutcome.Funded, spend, out);
    }

    /// @dev Hands `amount` of unconvertible native to `DIVIDEND_TREASURY`. Bounded by
    ///      `MAX_DIVIDEND_PER_CONVERSION` per call, so clearing a dead pool's whole buffer takes as many
    ///      calls as converting it would have.
    /// @dev Debited BEFORE the send, and re-read rather than reusing the caller's snapshot: the failed
    ///      conversion was an external call, so earnings that arrived during it must survive this write.
    /// @dev Deliberately NOT a write-off of anything holders hold. The asset, its `owed`, its
    ///      accumulator and every `Acct` are untouched — this moves native that had not been converted
    ///      yet and therefore was never streamed to anyone.
    function _sweepFailedConversion(uint256 i, address asset, uint256 amount) private {
        // forge-lint: disable-next-line(unsafe-typecast)
        dividendAssets[i].pendingNative = uint88(dividendAssets[i].pendingNative - amount);
        (bool sent,) = DIVIDEND_TREASURY.call{value: amount}("");
        require(sent, DividendSweepFailed());
        emit DividendBufferSweptToTreasury(asset, amount);
    }

    /// @dev Converts `nativeIn` into `asset`. Native needs no conversion; a third ERC20 is bought on the
    ///      pool the registry resolves for it. The token itself is venue-specific, handled by an override.
    /// @dev The route is the registry's, never the caller's: `processDividends` is permissionless, so a
    ///      route supplied there would let any caller send the token's earnings through a pool they
    ///      control.
    /// @return out asset actually received, measured as a balance delta so a fee-on-transfer asset is
    ///         counted for what it delivered. 0 when the conversion did not happen — see
    ///         `_fundDividends`.
    function _acquireDividendAsset(address asset, uint256 nativeIn, uint256 minOut)
        internal
        virtual
        returns (uint256 out)
    {
        if (asset == address(0)) return nativeIn; // native: the buffer already IS the payout asset

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        if (!_swapNativeToDividendAsset(asset, nativeIn, minOut)) return 0;
        return IERC20(asset).balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Hands the conversion to the registry, which re-checks eligibility, swaps and forwards the
    ///      asset back here in one call. Nothing about the route is stored on the token: the registry
    ///      resolves it, so a token created before a venue existed can still use it.
    /// @dev A LOW-LEVEL call, on purpose. The registry reverts on a dead pair, a missed floor or an
    ///      asset blacklisted since creation, and this caller is a distribution that must not lose its
    ///      buffer to any of those — a reverted call leaves the native exactly where it was, and
    ///      `false` here becomes `ConversionFailed` rather than a reverted distribution.
    /// @dev The `extcodesize` check is what makes the low-level call fail CLOSED. A raw `call` to an
    ///      address with no code succeeds, so against a misconfigured (or not-yet-deployed) registry
    ///      constant it would hand the buffer over and report success while `_acquireDividendAsset`
    ///      measured a zero delta — burning the native on every call instead of reverting once.
    function _swapNativeToDividendAsset(address asset, uint256 nativeIn, uint256 minOut) private returns (bool ok) {
        if (DIVIDEND_SWAP_REGISTRY.code.length == 0) return false;
        (ok,) = DIVIDEND_SWAP_REGISTRY.call{value: nativeIn}(
            abi.encodeCall(IRealmDividendSwapRegistry.swapNativeToAsset, (asset, minOut, address(this)))
        );
    }

    /// @dev Pays one holder everything they have accrued in asset `i`, or nothing.
    /// @dev The banked accrual is zeroed AFTER the send succeeds, never before. A failed send therefore
    ///      costs the holder nothing — the amount stays accrued and the next batch (or their own claim)
    ///      pays it. This is what a reverting `receive()` or a payout-asset blacklist degrades into.
    /// @dev Settling before reading is not optional: the caller has already advanced the accumulator, so
    ///      this holder's share of the interval that just closed is only in `Acct.rewards` after this.
    /// @param gasStipend Gas forwarded to the payout call: `NATIVE_PAYOUT_GAS` or `ASSET_PAYOUT_GAS` from
    ///        a keeper batch, `gasleft()` from `claimDividends` (which, under EIP-150's 63/64 rule, is an
    ///        uncapped call).
    /// @return The amount actually delivered, 0 if the holder was skipped or the send failed.
    function _payHolder(address holder, uint256 i, address asset, uint256 rpt, uint256 gasStipend)
        private
        returns (uint256)
    {
        // An excluded address never accrues, so its `Acct` is a stale checkpoint against a live balance
        // — settling it would mint a phantom claim out of the accumulator's whole history.
        if (_dividendExcluded(holder)) return 0;

        _settleDividends(holder, i, rpt);
        uint256 amount = dividendAccounts[holder][i].rewards;
        if (amount == 0) return 0;

        if (!_payDividend(asset, holder, amount, gasStipend)) return 0;

        dividendAccounts[holder][i].rewards = 0;
        emit DividendPaid(holder, asset, amount);
        return amount;
    }

    /// @dev Delivers one payout, reporting failure instead of reverting — for BOTH shapes. A third asset
    ///      is the creator's choice, and a creator's choice can blacklist addresses, so a reverting
    ///      `safeTransfer` on ONE holder would take down the whole batch and `claimDividends` for everyone.
    /// @dev BOTH shapes are gas-bounded too, for the same reason and with different numbers: an
    ///      unbounded `receive()` starves the batch, and so does an unbounded `transfer` on a payout asset
    ///      the registry only ever vetted for liquidity. `claimDividends` passes `gasleft()` either way,
    ///      so a stipend never becomes an eligibility gate.
    function _payDividend(address asset, address to, uint256 amount, uint256 gasStipend) private returns (bool) {
        if (asset == address(0)) {
            (bool sent,) = to.call{value: amount, gas: gasStipend}("");
            return sent;
        }
        bytes memory payload = abi.encodeCall(IERC20.transfer, (to, amount));
        bool ok;
        uint256 size;
        uint256 word;
        // Raw `call` with a 32-byte output window, NOT Solidity's `(bool, bytes memory)` form. That form
        // copies the WHOLE returndata into memory at the CALLER's expense, outside the stipend — so an
        // asset that expands memory before returning makes the copy unaffordable. Under EIP-150 the
        // callee always receives 63/64 of what is left, i.e. far more than the caller keeps, which made
        // `claimDividends` (it forwards `gasleft()`) revert no matter how much gas the holder supplied —
        // the one payout route that is supposed to always work. Capping the window at one word costs the
        // caller nothing whatever the asset returns.
        assembly ("memory-safe") {
            // Scratch space (0x00-0x3f) is free for this; zeroed first so a short return cannot leave a
            // stale word behind for the `size` checks below to read.
            mstore(0, 0)
            ok := call(gasStipend, asset, 0, add(payload, 32), mload(payload), 0, 32)
            size := returndatasize()
            word := mload(0)
        }
        // `SafeERC20`'s success test minus the revert: empty returndata is success (non-standard ERC20s),
        // and anything too short to decode is failure rather than a panic. `asset` is known to be a
        // contract — its pot could only have been funded through a `balanceOf` call on it.
        // Compared as a WORD, not decoded as a `bool`: `abi.decode(_, (bool))` reverts on any value above
        // 1, which a non-standard ERC20 may legally return — and reverting here is precisely what this
        // function exists not to do (it would brick the batch and `claimDividends`).
        return ok && (size == 0 || (size >= 32 && word != 0));
    }
}
