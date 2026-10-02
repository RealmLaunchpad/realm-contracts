// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IRealmSwapper} from "src/interfaces/IRealmSwapper.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

/// @title DividendDistributionLogic
/// @notice The COLD half of `DividendDistribution`: the native -> payout-asset conversion, the
///         crediting, and the per-holder push. Everything here runs out-of-band, driven by a keeper or a
///         holder — never from a transfer or a swap.
///
/// @dev ONE ENTRY POINT PER ASSET for the keeper. `processDividends(index, ...)` converts that asset's
///      buffer, credits the proceeds to its accumulator and pushes its payouts, doing whichever of the
///      three there is anything to do. They were three separate transactions and a round state machine
///      once, and there was never a reason for it: the anti-flash-loan property comes from the keeper
///      gate and the settle-before-mutate rule, not from a transaction boundary or a phase, so the three
///      collapse into one call that can be made at any moment.
///
/// @dev ONE ASSET PER CALL, deliberately. Each asset crosses its threshold on its own schedule, prices
///      its slippage floor against its own pool and holds its own per-block cooldown, so a call that
///      tried to serve the whole set would need a floor per asset and would pay a transfer per asset per
///      holder. A keeper batches per asset instead, and the assets never contend.
///
/// @dev NOTHING HERE REVERTS FOR BEING EARLY. A distribution can land at any moment and simply credits
///      the accumulator. The only reverts are for a call that could accomplish NOTHING — an empty push
///      list against an unfundable buffer — and they are there so a keeper's simulation gets a reason
///      rather than a silent success.
///
/// @dev A mixin of `RealmTaxableToken`, separate from `DividendDistribution` only so the test harnesses
///      can build the hot half alone. Adds NO storage.
abstract contract DividendDistributionLogic is DividendDistribution, KeeperGated, ReentrancyGuardTransient {
    /// @notice The eligible supply is under `MIN_DIVIDEND_SUPPLY`: there is nobody to credit, so the
    ///         buffer stays where it is until a holder shows up.
    error NoDividendSupply();

    /// @notice What `_fundDividends` found. A return value rather than a flag because the caller has to
    ///         distinguish "wait for earnings" from "the earnings are here and the swap is broken".
    enum FundOutcome {
        /// @dev Nothing buffered, or not enough of it yet. The quiet, normal answer.
        NotReady,
        /// @dev Holders are credited with `out` of the payout asset.
        Funded,
        /// @dev Something was buffered and the conversion did not happen. The buffer is untouched.
        ConversionFailed
    }

    //////////////////////// the distribution //////////////////////

    /// @notice Converts whatever has accrued to ONE payout asset, credits it to that asset's holders,
    ///         and pushes its payouts to `holders`. The only entry point a keeper needs, called once per
    ///         asset.
    ///
    /// @dev Idempotent and unforgeable in the part that matters: the amounts are read from each holder's
    ///      own accrued balance, so a duplicate pays 0, an unknown address pays 0, and an omitted holder
    ///      loses nothing at all — their accrual keeps sitting there for the next batch or for their own
    ///      `claimDividends()`. A keeper is free to push only to holders above whatever size threshold
    ///      it likes; the small ones are not forfeiting anything by being skipped.
    ///
    /// @dev The caller supplies which asset, how much of its buffer to convert and the slippage floor.
    ///
    /// @param assetIndex Which configured payout asset to service. Reverts past the configured count.
    /// @param fund False for a push-only call: skips the conversion (no block claimed, no
    ///        `DividendsFunded`); `holders` must then be non-empty, or it reverts `NoDividendWork`.
    /// @param amount Native to convert, capped by the buffer and `MAX_DIVIDEND_PER_CONVERSION`; 0 means
    ///        "up to the cap". Lets a keeper slice a buffer a thin pool cannot take in one go. Ignored
    ///        by a payout that does not swap.
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
    function processDividends(uint8 assetIndex, bool fund, uint256 amount, uint256 minOut, address[] calldata holders)
        public
        nonReentrant
        nonReentrantDividends
    {
        _processDividends(assetIndex, fund, amount, minOut, holders);
    }

    /// @dev The body of `processDividends`, without its locks, so a venue can service the same asset
    ///      out of a buffer the shared machine does not know — an ERC20 quote's — under locks of its own
    ///      (`RealmTaxableTokenUniV4.processDividends(uint8,address,uint256,uint256,address[])`).
    function _processDividends(uint8 assetIndex, bool fund, uint256 amount, uint256 minOut, address[] calldata holders)
        internal
    {
        require(fund || holders.length != 0, NoDividendWork());
        require(assetIndex < _dividendAssetCount(), DividendAssetOutOfRange());
        DivAsset storage asset = dividendAssets[assetIndex];
        require(asset.lastDistribution != 0, DividendsNotActive());

        // KEEPER-GATED. The conversion below takes its slippage floor from the caller, so a
        // permissionless caller could manipulate the payout pool, call in with a zero floor and unwind,
        // all in one transaction — see `RealmKeepersRegistry`, whose admins can open the gate to
        // everyone if the keeper set is ever retired. Holders never depend on a keeper to be PAID:
        // `claimDividends()` is open to everyone and pays in full.
        _requireKeeper();

        // Once per block PER ASSET, for exactly the reason `processBurn` and `processLiquidity` are: the
        // per-call cap only bounds what a manipulated block can yield if the block allows ONE conversion.
        // Without it a caller re-enters at the same distorted price until the buffer is gone, paying the
        // manipulation cost once instead of once per block. Per asset because the manipulation is of one
        // asset's pool and buys nothing in the others.
        // The gate is on the FUNDING leg ALONE. Pushing payouts is not rate-limited and must not be: a
        // keeper splitting a large holder set across several transactions in one block is ordinary, and
        // those calls read a buffer this one already resolved.
        // `fund == false` is a push-only call: it never funds, so it neither claims the block nor emits
        // `DividendsFunded` — a keeper pushing already-credited payouts must not convert buffer dust.
        bool cooldown = block.number <= asset.lastProcessBlock;

        FundOutcome outcome = FundOutcome.NotReady;
        uint256 nativeIn;
        uint256 out;
        bool fellBack;
        if (fund && !cooldown) {
            // A retired payout asset is not bought: the native buffer goes to the native fallback pot.
            if (_retiredPayout(asset.token)) {
                uint256 buffered = asset.pendingNative;
                if (buffered != 0) {
                    asset.pendingNative = 0;
                    _creditFallback(assetIndex, 0, address(0), buffered);
                    (outcome, fellBack) = (FundOutcome.Funded, true);
                }
            } else {
                (outcome, nativeIn, out) = _fundDividends(assetIndex, amount, minOut);
            }
            // Claimed only when the buffer actually MOVED. A call that found nothing fundable, or whose
            // swap failed, spent nothing and must not lock the block against an honest keeper.
            if (outcome == FundOutcome.Funded) {
                // forge-lint: disable-next-line(unsafe-typecast)
                asset.lastProcessBlock = uint40(block.number);
            }
        }

        if (outcome == FundOutcome.Funded && !fellBack) {
            _creditDividends(assetIndex, out);
            emit DividendsFunded(address(0), asset.token, nativeIn, out);
        }

        if (holders.length != 0) {
            _pushDividends(assetIndex, holders);
            _pushFallbacks(holders);
        } else if (cooldown) {
            // Distinct from the two below on purpose: this keeper has to wait a block, not wait for
            // earnings or re-price a floor.
            revert DividendProcessCooldown();
        } else if (outcome == FundOutcome.NotReady) {
            // Two different situations, two different errors: a keeper that sees `BelowDividendThreshold`
            // has to wait for earnings, one that sees `DividendConversionFailed` has the earnings and a
            // swap problem — a `minOut` the pool has moved past, or a pool that is gone.
            // The name predates the funding floor's removal: "nothing to fund" means an EMPTY buffer.
            revert BelowDividendThreshold();
        } else if (outcome == FundOutcome.ConversionFailed) {
            revert DividendConversionFailed();
        }
        // A call carrying holders never reverts for the buffer being short or the swap being broken: it
        // asked to push payouts, and it pushed them.
    }

    /// @notice The pre-multi-asset signature, servicing asset 0. Kept so keepers and scripts written
    ///         against single-asset tokens — which is what every token with one payout asset still is —
    ///         keep working unchanged.
    function processDividends(uint256 minOut, address[] calldata holders) external {
        processDividends(0, true, 0, minOut, holders);
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
        require(n != 0 && dividendAssets[0].lastDistribution != 0, DividendsNotActive());

        for (uint256 i; i < n; ++i) {
            DivAsset storage a = dividendAssets[i];
            _reduceDividendsOwed(i, _payHolder(msg.sender, i, a.token, a.rewardPerTokenStored, gasleft()));
        }
        uint256 mask = _dividendFallbackMask();
        for (uint256 q; mask != 0; ++q) {
            if (mask & 1 != 0) _payFallback(msg.sender, q, gasleft());
            mask >>= 1;
        }
    }

    //////////////////////// fallback pots //////////////////////

    /// @dev Whether the registry has retired `asset`. Fails OPEN (false) against a registry that cannot
    ///      answer — codeless, or an implementation older than the flag — which is the behaviour every
    ///      token had before retirement existed: keep trying to convert.
    function _isRetired(address asset) internal view returns (bool) {
        (bool ok, bytes memory ret) = REALM_SWAPPER.staticcall(abi.encodeCall(IRealmSwapper.isRetired, (asset)));
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }

    /// @dev Whether `payout` is a THIRD asset the registry retired. Native and the token itself are never
    ///      bought through the registry, so there is nothing for a retirement of them to stop.
    function _retiredPayout(address payout) internal view returns (bool) {
        return payout != address(0) && payout != address(this) && _isRetired(payout);
    }

    /// @dev Credits `amount` of `currency` (`quotes(q)`) to the balances held right now, through pot `q`:
    ///      `_creditDividends` for a fallback. The first credit opens the pot — its scale from the
    ///      currency's decimals, its bit in the mask so transfers start settling it.
    function _creditFallback(uint256 i, uint256 q, address currency, uint256 amount) internal {
        uint256 supply = _dividendEligibleSupply();
        require(supply >= MIN_DIVIDEND_SUPPLY, NoDividendSupply());
        FallbackPot storage pot = dividendFallbacks[q];
        uint256 mask = _dividendFallbackMask();
        if (mask & (1 << q) == 0) {
            uint256 decimals = currency == address(0) ? 18 : IERC20Metadata(currency).decimals();
            // forge-lint: disable-next-line(unsafe-typecast)
            pot.precisionExp =
                decimals >= DIVIDEND_PRECISION_DECIMALS ? 0 : uint8(DIVIDEND_PRECISION_DECIMALS - decimals);
            _setDividendFallbackMask(mask | (1 << q));
        }
        // Bounds as `_creditDividends`'s: `MIN_DIVIDEND_SUPPLY` caps the accumulator, and `amount` is a
        // buffer that was itself a `uint128` at most.
        // forge-lint: disable-next-line(unsafe-typecast)
        pot.rewardPerTokenStored = uint128(pot.rewardPerTokenStored + amount * 10 ** pot.precisionExp / supply);
        uint256 owed = pot.owed + amount;
        // forge-lint: disable-next-line(unsafe-typecast)
        pot.owed = owed > type(uint120).max ? type(uint120).max : uint120(owed);
        emit DividendFallbackFunded(i, currency, amount);
    }

    /// @dev Pushes every existing pot to `holders`. All pots, whichever leg the call serviced, so a
    ///      keeper's ordinary native batches also deliver the quote pots.
    function _pushFallbacks(address[] calldata holders) internal {
        uint256 mask = _dividendFallbackMask();
        for (uint256 q; mask != 0; ++q) {
            if (mask & 1 != 0) {
                uint256 stipend = _fallbackCurrency(q) == address(0) ? NATIVE_PAYOUT_GAS : ASSET_PAYOUT_GAS;
                for (uint256 h; h < holders.length; ++h) {
                    _payFallback(holders[h], q, stipend);
                }
            }
            mask >>= 1;
        }
    }

    /// @dev `_payHolder` for pot `q`: settle, send, and only then zero the banked amount and the debt.
    function _payFallback(address holder, uint256 q, uint256 gasStipend) internal {
        if (_dividendExcluded(holder)) return;
        FallbackPot storage pot = dividendFallbacks[q];
        Acct storage acct = fallbackAccounts[holder][q];
        _settleAcct(acct, holder, pot.rewardPerTokenStored, 10 ** pot.precisionExp);
        uint256 amount = acct.rewards;
        address currency = _fallbackCurrency(q);
        if (amount == 0 || !_payDividend(currency, holder, amount, gasStipend)) return;
        acct.rewards = 0;
        uint256 owed = pot.owed;
        // Saturating, as `_reduceDividendsOwed`.
        // forge-lint: disable-next-line(unsafe-typecast)
        pot.owed = amount >= owed ? 0 : uint120(owed - amount);
        emit DividendFallbackPaid(holder, currency, amount);
    }

    /// @dev The currency of pot `q`: the token's `quotes(q)`.
    function _fallbackCurrency(uint256 q) internal view virtual returns (address);

    /// @dev Writes the token's `dividendFallbackMask`.
    function _setDividendFallbackMask(uint256 mask) internal virtual;

    //////////////////////// internal //////////////////////

    /// @dev Credits `amount` of asset `i` to the balances held right now: the accumulator grows by
    ///      `amount / eligibleSupply` and every holder's next settle banks their share of it.
    /// @dev The supply is read HERE and nowhere else — every balance change settles before it moves, so
    ///      the supply at this instant is exactly the one the credited balances sum to.
    /// @dev Integer division leaves a residue the accumulator cannot carry, which stays in `owed` and
    ///      simply never leaves the balance — dust (under `supply / 10**precisionExp` units, i.e. under a
    ///      gwei for an 18-decimal asset), and dust that errs towards holders rather than towards a sweep.
    function _creditDividends(uint256 i, uint256 amount) internal {
        DivAsset storage a = dividendAssets[i];
        uint256 supply = _dividendEligibleSupply();
        require(supply >= MIN_DIVIDEND_SUPPLY, NoDividendSupply());

        // Bounded by `MIN_DIVIDEND_SUPPLY`: the accumulator's lifetime growth cannot exceed the total
        // ever distributed times `1e18 / MIN_DIVIDEND_SUPPLY`, which is 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.rewardPerTokenStored = uint128(uint256(a.rewardPerTokenStored) + amount * _dividendPrecision(i) / supply);
        // `uint128` holds 3.4e38 payout-asset units; `amount` is bounded by the conversion cap.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.owed = uint128(uint256(a.owed) + amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        a.lastDistribution = uint40(block.timestamp);
    }

    /// @dev Saturating on purpose. The accumulator truncates in the holders' favour at every step, so
    ///      `Σ payouts <= owed` holds by construction — but this runs in a non-upgradeable clone, and a
    ///      rounding surprise must degrade into a stale counter rather than into payouts that revert
    ///      forever.
    function _reduceDividendsOwed(uint256 i, uint256 paid) internal {
        if (paid == 0) return;
        uint256 owed = dividendAssets[i].owed;
        // forge-lint: disable-next-line(unsafe-typecast)
        dividendAssets[i].owed = paid >= owed ? 0 : uint128(owed - paid);
    }

    /// @dev Pushes every holder's accrued payout in asset `i`. Reads the accumulator AFTER whatever the
    ///      caller just credited, so the push includes that distribution.
    function _pushDividends(uint256 i, address[] calldata holders) internal {
        DivAsset storage asset = dividendAssets[i];
        // The asset leg gets its own, far larger stipend: `NATIVE_PAYOUT_GAS` is sized for a wallet's
        // `receive()` and would starve an ordinary ERC20 `transfer`.
        address payoutAsset = asset.token;
        uint256 stipend = payoutAsset == address(0) ? NATIVE_PAYOUT_GAS : ASSET_PAYOUT_GAS;
        uint256 rpt = asset.rewardPerTokenStored;
        uint256 paid;
        for (uint256 h; h < holders.length; ++h) {
            paid += _payHolder(holders[h], i, payoutAsset, rpt, stipend);
        }
        _reduceDividendsOwed(i, paid);
    }

    /// @dev Turns asset `i`'s accrued buffer into payout-asset units, or reports why it could not.
    ///      Overridable so a venue can source the payout from somewhere other than the native buffer
    ///      (the V2 self-token payout, which is carved from tax tokens).
    function _fundDividends(uint256 i, uint256 amount, uint256 minOut)
        internal
        virtual
        returns (FundOutcome, uint256 nativeIn, uint256 out)
    {
        DivAsset storage a = dividendAssets[i];
        uint256 buffered = a.pendingNative;
        if (buffered == 0) return (FundOutcome.NotReady, 0, 0);

        // NO SIZE FLOOR. Any non-zero buffer converts. "Is this worth its gas" is the caller's question,
        // not the contract's: the path is keeper-gated, so the only party this could restrain is a
        // keeper spending its own gas on a call whose whole cost it can see.
        address asset = a.token;
        // Only a payout that SWAPS is capped, and only it honours `amount`. Native is already
        // denominated in the payout asset, so it has no swap to sandwich and nothing to slice.
        uint256 spend = buffered;
        if (asset != address(0)) {
            uint256 cap = amount == 0 || amount > MAX_DIVIDEND_PER_CONVERSION ? MAX_DIVIDEND_PER_CONVERSION : amount;
            if (spend > cap) spend = cap;
        }
        (out, nativeIn) = _acquireDividendAsset(asset, spend, minOut);

        // A conversion that did not happen leaves the buffer untouched: the swap can fail for reasons
        // outside anyone's control — a floor the pool has moved past, a route not set yet or a pool
        // that drained — and the next call retries, after the registry's route is fixed if need be.
        if (out == 0) return (FundOutcome.ConversionFailed, 0, 0);

        // Debits only what the conversion CONSUMED: native a partial fill handed back stays owed to
        // holders. Re-read rather than reuse `buffered`: the swap is an external call, and earnings that
        // arrived during it (`_accrueDividends` is not behind the dividend lock) must survive this write.
        // Bounded by the value read, which is already a `uint88`.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.pendingNative = uint88(a.pendingNative - nativeIn);
        return (FundOutcome.Funded, nativeIn, out);
    }

    /// @dev Converts `nativeIn` into `asset`. Native needs no conversion; a third ERC20 is bought on the
    ///      pool the registry resolves for it. The token itself is venue-specific, handled by an override.
    /// @dev The route is the registry's, never the caller's: `processDividends` is permissionless, so a
    ///      route supplied there would let any caller send the token's earnings through a pool they
    ///      control.
    /// @return out asset actually received, measured as a balance delta so a fee-on-transfer asset is
    ///         counted for what it delivered. 0 when the conversion did not happen — see
    ///         `_fundDividends`.
    /// @return spent native the conversion consumed. The registry takes all of `nativeIn` or reverts.
    function _acquireDividendAsset(address asset, uint256 nativeIn, uint256 minOut)
        internal
        virtual
        returns (uint256 out, uint256 spent)
    {
        if (asset == address(0)) return (nativeIn, nativeIn); // native: the buffer already IS the payout

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        if (!_swapNativeToDividendAsset(asset, nativeIn, minOut)) return (0, 0);
        return (IERC20(asset).balanceOf(address(this)) - balanceBefore, nativeIn);
    }

    /// @dev Hands the conversion to the registry, which re-checks eligibility, swaps and forwards the
    ///      asset back here in one call. Nothing about the route is stored on the token: the registry
    ///      resolves it, so a token created before a venue existed can still use it.
    /// @dev A LOW-LEVEL call, on purpose. The registry reverts on a missing route, a dead pool or a missed
    ///      floor, and this caller is a distribution that must not lose its
    ///      buffer to any of those — a reverted call leaves the native exactly where it was, and
    ///      `false` here becomes `ConversionFailed` rather than a reverted distribution.
    /// @dev The `extcodesize` check is what makes the low-level call fail CLOSED. A raw `call` to an
    ///      address with no code succeeds, so against a misconfigured (or not-yet-deployed) registry
    ///      constant it would hand the buffer over and report success while `_acquireDividendAsset`
    ///      measured a zero delta — burning the native on every call instead of reverting once.
    function _swapNativeToDividendAsset(address asset, uint256 nativeIn, uint256 minOut) private returns (bool ok) {
        if (REALM_SWAPPER.code.length == 0) return false;
        (ok,) = REALM_SWAPPER.call{value: nativeIn}(
            abi.encodeCall(IRealmSwapper.swapNativeToAsset, (asset, minOut, address(this)))
        );
    }

    /// @dev Pays one holder everything they have accrued in asset `i`, or nothing.
    /// @dev The banked accrual is zeroed AFTER the send succeeds, never before. A failed send therefore
    ///      costs the holder nothing — the amount stays accrued and the next batch (or their own claim)
    ///      pays it. This is what a reverting `receive()` or a payout-asset blacklist degrades into.
    /// @dev Settling before reading is not optional: this holder's share of every distribution since
    ///      they last moved is only in `Acct.rewards` after this.
    /// @param gasStipend Gas forwarded to the payout call: `NATIVE_PAYOUT_GAS` or `ASSET_PAYOUT_GAS` from
    ///        a keeper batch, `gasleft()` from `claimDividends` (which, under EIP-150's 63/64 rule, is an
    ///        uncapped call).
    /// @return The amount actually delivered, 0 if the holder was skipped or the send failed.
    function _payHolder(address holder, uint256 i, address asset, uint256 rpt, uint256 gasStipend)
        internal
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
