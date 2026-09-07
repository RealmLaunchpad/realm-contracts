// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title EarningsAllocation
/// @notice Splits a taxable token's post-graduation earnings — swap taxes AND the creator's share of
///         LP fees, which converge on the same ETH stream — into up to four buckets: the fund wallets
///         (the existing fee-handler distribution), buy-back-and-burn, holder dividends, and liquidity
///         additions.
/// @dev This is the routing PRIMITIVE only: the fund leg is live today; the other three are `virtual`
///      seams that currently FALL BACK to the fund wallets until their module ships (steps 2–4). The
///      fallback is deliberate: allocation shares are chosen at token creation, so a token launched
///      today with a non-zero `burnBps` safely routes that slice to the fund wallets now and
///      auto-activates once a concrete token overrides `_handleBurn` — no re-config, and no way to
///      create a token that bricks on its first post-graduation earnings.
///
/// @dev ⚠️ GAS BUDGET — READ BEFORE IMPLEMENTING A BUCKET. Earnings reach this split via
///      `LivoToken.accrueFees`. On the V4 LP-fee route that call is made by `LivoLpFeeRouter` from
///      inside `LivoSwapHook`'s `try { ... } { gas: ROUTER_GAS_LIMIT }` (≈1M gas) during a swap; if it
///      runs out of gas the hook drops the LP fee to the treasury. The split therefore MUST stay cheap:
///      each `_handle*` leg may only ACCRUE its slice (ideally a single SSTORE) for OUT-OF-BAND
///      processing — a keeper- or threshold-triggered swap / burn / liquidity-add in a separate tx with
///      full gas, mirroring the V2 swap-back pattern. A `_handle*` leg must NEVER perform a Uniswap
///      swap or `modifyLiquidity` synchronously: it would not fit the budget and, on the V4 route,
///      would also reenter the pool mid-swap. `_allocateEthEarnings` collapses every fund-bound slice into
///      ONE `_depositToFund`, so the whole path stays well within budget.
///
/// @dev Venue-agnostic and ETH-space: it divides whatever ETH it is handed by the configured bps and
///      dispatches each slice. Uniswap-V2/V4-specific mechanics (e.g. V2 burning tax tokens before the
///      swap-back to avoid an ETH→token round trip) live in the concrete token's override of
///      `_handle*`, not here. The fund bucket receives the integer-division remainder plus any slice a
///      leg leaves unconsumed, so no wei is ever stranded or double-counted.
/// @dev Storage: the three bps fields occupy a single dedicated slot placed before the taxable token's
///      packed tax slot, so the per-trade tax read stays a single warm SLOAD; the allocation bps are
///      only read on the (cold) earnings-routing path.
abstract contract EarningsAllocation {
    uint256 internal constant BPS_TOTAL = 10_000;

    /// @notice Post-graduation earnings share (bps) routed to buy-back-and-burn. 0 = disabled.
    ///         The fund-wallet share is the remainder after the three configurable buckets.
    uint16 public burnBps;

    /// @notice Post-graduation earnings share (bps) routed to holder dividends. 0 = disabled.
    uint16 public dividendsBps;

    /// @notice Post-graduation earnings share (bps) routed to liquidity additions. 0 = disabled.
    uint16 public liquidityBps;

    /// @notice Emitted once, at token creation, when a non-zero earnings allocation is configured.
    event EarningsAllocationInitialized(uint16 burnBps, uint16 dividendsBps, uint16 liquidityBps);

    /// @notice Thrown when the configured buckets sum to more than 100%.
    error InvalidEarningsAllocation();

    /// @dev Stores the creation-time allocation split. Called once by the token during initialization.
    ///      Validates only that the three buckets sum to at most 100%; the fund wallets take the rest.
    function _initializeEarningsAllocation(uint16 _burnBps, uint16 _dividendsBps, uint16 _liquidityBps) internal {
        require(uint256(_burnBps) + _dividendsBps + _liquidityBps <= BPS_TOTAL, InvalidEarningsAllocation());
        burnBps = _burnBps;
        dividendsBps = _dividendsBps;
        liquidityBps = _liquidityBps;
        emit EarningsAllocationInitialized(_burnBps, _dividendsBps, _liquidityBps);
    }

    /// @dev The ETH-space earnings split — the shared "phase 2" for both venues: given `amount` of ETH,
    ///      it routes the burn / dividends / liquidity / fund slices. `burnShare` and `liquidityShare` say
    ///      which of those two slices this venue carves HERE, from this ETH, versus having already peeled
    ///      them upstream in token-space:
    ///      - V4 (ETH-native): passes `burnBps` and `liquidityBps` — both are taken from this ETH and
    ///        handed to `_handleBurn` / `_handleLiquidity`, which buffer ETH for their out-of-band jobs.
    ///      - V2 (token-native): passes `0` and `0` — the burn was already done by burning tax TOKENS and
    ///        the liquidity slice was already set aside as tax TOKENS before the swap-back, so this ETH is
    ///        already net of both and nothing is carved here.
    ///      Dividends/fund are shares of the ORIGINAL earnings, but the ETH left after burn+liquidity is
    ///      only the `BPS_TOTAL - burnBps - liquidityBps` fraction (whether those left as ETH here or as
    ///      tokens upstream), so they are renormalized over that denom — making the two venues produce
    ///      identical splits for the same config. The fund wallets take the remainder plus any residual a
    ///      leg leaves unconsumed, folded into one deposit. Pre-graduation the whole amount goes to the
    ///      fund wallets unchanged.
    /// @return fundAmount The ETH actually deposited to the fund wallets — i.e. the slice that reaches
    ///         the fee handler and shows up as creator fees. Callers emit it so off-chain accounting can
    ///         separate creator fees from the token-earnings slices (burn / dividends / liquidity).
    function _allocateEthEarnings(uint256 amount, uint256 burnShare, uint256 liquidityShare)
        internal
        returns (uint256 fundAmount)
    {
        fundAmount = _splitEthEarnings(amount, burnShare, liquidityShare);
        if (fundAmount > 0) _depositToFund(fundAmount);
    }

    /// @dev `_allocateEthEarnings` minus the final fund deposit: dispatches the burn / liquidity /
    ///      dividends legs and RETURNS the fund slice without depositing it. Exists so a caller can emit
    ///      its own event between the split and the `CreatorFeesDeposited` the deposit emits (the V2
    ///      swap-back must keep `CreatorTaxSwapback` first for the indexer). The caller MUST deposit the
    ///      returned amount itself.
    function _splitEthEarnings(uint256 amount, uint256 burnShare, uint256 liquidityShare)
        internal
        returns (uint256 fundAmount)
    {
        if (!_earningsGraduated()) {
            return amount;
        }

        // First point at which a token is provably past graduation AND actually earning. Modules that
        // need a one-off "the token is live now" moment hook in here rather than into `markGraduated()`,
        // which still runs mid-graduation with the graduator holding the whole supply.
        // BEFORE the zero-amount exit, not after: a token whose every bucket is peeled upstream in token
        // space reaches here with `amount == 0` on EVERY earnings routing, and that is exactly the token
        // whose dividends would otherwise never open.
        _onGraduatedEarnings();

        if (amount == 0) return 0;

        // Carve the burn/liquidity slices this venue takes from the ETH here; a venue that peeled them
        // upstream in token-space passes 0 for that share.
        uint256 burn = amount * burnShare / BPS_TOTAL;
        uint256 liquidity = amount * liquidityShare / BPS_TOTAL;

        // `fund` accumulates the fund-wallet slice plus whatever each leg leaves unconsumed. Residuals
        // fold into FUND, never back into `remaining` — that would re-split them over dividends.
        // `denom == 0` means every bucket was already peeled, so `remaining` is whatever survived them
        // and belongs to the fund wallets whole — on V4 that is 0, on V2 (which peels in token space and
        // passes `burnShare == liquidityShare == 0`) it is the ETH left after the upstream peels.
        // A venue may also peel part of the DIVIDENDS slice upstream in token-space (the Uniswap-V2
        // self-token leg, which cannot be bought back with ETH); that share is out of both the numerator
        // and the denominator here, exactly like the burn/liquidity shares it sits beside.
        uint256 preCarvedDividends = _tokenSpaceDividendBps();
        uint256 denom = BPS_TOTAL - burnBps - liquidityBps - preCarvedDividends;
        uint256 remaining = amount - burn - liquidity;
        uint256 dividends;
        uint256 fund = remaining;
        if (denom != 0) {
            dividends = remaining * (dividendsBps - preCarvedDividends) / denom;
            fund = remaining - dividends;
        }

        if (burn > 0) fund += _handleBurn(burn);
        if (liquidity > 0) fund += _handleLiquidity(liquidity);
        if (dividends > 0) fund += _handleDividends(dividends);
        return fund;
    }

    /// @dev The share of `dividendsBps` a venue already peeled upstream in TOKEN space, so the ETH split
    ///      neither pays it again nor counts it in its denominator. 0 everywhere except the Uniswap-V2
    ///      self-token dividend payout (a V2 pair reverts `INVALID_TO` when asked to deliver a token to its
    ///      own address, so that leg is carved from the tax tokens instead of bought back).
    function _tokenSpaceDividendBps() internal view virtual returns (uint256) {
        return 0;
    }

    /// @dev Fires on every routing of post-graduation earnings, before any slice is carved. A no-op by
    ///      default; the dividend module uses it as the FALLBACK opener for its first round. The normal
    ///      opener is `markGraduated()` — the graduator's own supply transfer, later in that same
    ///      transaction, self-corrects the denominator via the min-balance rule — and this covers only
    ///      the token that graduates inside `createToken`, before its allocation has been configured.
    function _onGraduatedEarnings() internal virtual {}

    /// @dev True once the token has graduated (a live pool exists). Implemented by the token.
    function _earningsGraduated() internal view virtual returns (bool);

    /// @dev Routes the fund-wallet slice to the master fee handler. Implemented by the token.
    function _depositToFund(uint256 amount) internal virtual;

    /// @dev Buy-back-and-burn leg. Returns the amount it did NOT consume, which `_allocateEthEarnings`
    ///      folds back into the single fund deposit. The base consumes nothing (returns `amount`), so
    ///      until the burn module ships every configured burn share routes to the fund wallets. When
    ///      overridden it MUST only accrue for out-of-band processing (see the gas note above) and
    ///      return the residual it did not accrue (0 in the common full-accrual case).
    function _handleBurn(uint256 amount) internal virtual returns (uint256 unconsumed) {
        return amount;
    }

    /// @dev Holder-dividends leg. Same contract as `_handleBurn`: accrue-only, return the unconsumed
    ///      residual. Falls back to the fund wallets until the dividends module ships (step 3).
    function _handleDividends(uint256 amount) internal virtual returns (uint256 unconsumed) {
        return amount;
    }

    /// @dev Liquidity-additions leg. Same contract as `_handleBurn`: accrue-only, return the unconsumed
    ///      residual. Falls back to the fund wallets until the liquidity module ships (step 4).
    function _handleLiquidity(uint256 amount) internal virtual returns (uint256 unconsumed) {
        return amount;
    }
}
