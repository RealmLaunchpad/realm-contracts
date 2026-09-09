// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmToken} from "src/tokens/RealmToken.sol";
import {EarningsAllocation} from "src/tokens/EarningsAllocation.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmTaxableToken, TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

/// @title RealmTaxableToken
/// @notice Abstract base for Realm taxable tokens shared by the Uniswap V2 and V4 variants.
///         Owns the tax-config storage, the post-graduation timestamp, the standard `markGraduated`
///         + `getTaxConfig` overrides, the dev-supplied init plumbing and the owner-only
///         `rescueTokens` path. Variant-specific behavior (intrinsic V2 taxation, V4 pool-manager
///         pair check) lives in the concrete subclasses.
/// @dev Storage layout: this contract's 8 packed tax fields (buyTaxBps, sellTaxBps, taxDurationSeconds,
///      startTaxFromLaunch, buyTaxDecayStartBps, sellTaxDecayStartBps, taxDecayDuration,
///      graduationTimestamp) share one slot with the three `EarningsAllocation` bps that inheritance
///      lays out just before them (48 + 192 = 240 bits), so the per-trade tax read stays a single warm
///      SLOAD — and the earnings-split read hits the same (warm) slot. That fills the slot enough that
///      the V2 subclass's swap-back counters now occupy the FOLLOWING slot (a negligible extra cold
///      SLOAD only in the swap-back path). Subclasses that add their own state must do so AFTER these
///      fields to preserve clone-storage layout.
/// @dev ⚠️ `DividendDistribution` is listed BEFORE `EarningsAllocation` on purpose: inheritance lays
///      base storage out in declaration order, so putting it after would wedge its state between the
///      allocation bps and the tax fields and break the packing described above.
/// @dev `ReentrancyGuardTransient` is last and holds NO regular storage (its flag lives in transient
///      storage), so it adds nothing to the layout above and is safe wherever it sits. It is inherited
///      here, rather than per venue, because `sweepStrayEth` needs it on both.
abstract contract RealmTaxableToken is
    RealmToken,
    IRealmTaxableToken,
    DividendDistribution,
    EarningsAllocation,
    KeeperGated,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    /// @notice Where `processLiquidity` locks LP tokens, and an address users sometimes send tokens to by
    ///         hand. Excluded from dividends for the latter reason only — the token's own burns go to
    ///         `address(0)` via `_burn`, so this is not a burn sink.
    address internal constant DEAD_ADDRESS = address(0xdEaD);

    //////////////////////// potentially immutable //////////////////

    /// @notice Buy tax rate in basis points. Set during initialization; the owner can lower it later
    ///         via `setTaxBps` (decrease-only — increases revert).
    uint16 public buyTaxBps;

    /// @notice Sell tax rate in basis points. Set during initialization; the owner can lower it later
    ///         via `setTaxBps` (decrease-only — increases revert).
    uint16 public sellTaxBps;

    /// @notice Duration in seconds of the tax window, measured from the anchor selected by
    ///         `startTaxFromLaunch` (`launchTimestamp` if true, else `graduationTimestamp`). Set
    ///         during initialization, cannot be changed.
    uint40 public taxDurationSeconds;

    /// @notice Anchor for the tax window. `true`: the window starts at token creation
    ///         (`launchTimestamp`) and spans graduation transparently. `false`: the window starts at
    ///         graduation (`graduationTimestamp`) and no tax is charged before graduation. Set during
    ///         initialization, cannot be changed.
    bool public startTaxFromLaunch;

    /// @notice Buy-tax rate at the anchor for the optional linear decay (bps). The buy decay rate falls
    ///         linearly from this value to the long-term static `buyTaxBps` (0 for a decay-only token) over
    ///         `taxDecayDuration`, from the same anchor `startTaxFromLaunch` selects. 0 disables buy decay.
    ///         Set during init, cannot be changed.
    uint16 public buyTaxDecayStartBps;

    /// @notice Sell-tax rate at the anchor for the optional linear decay (bps). Mirror of
    ///         `buyTaxDecayStartBps` for sells. 0 disables sell decay. Set during init, cannot be changed.
    uint16 public sellTaxDecayStartBps;

    /// @notice Duration in seconds over which the decay rates fall from their start values to the
    ///         long-term static rates (0 for a decay-only token), measured from the same anchor as the
    ///         static window. 0 disables decay. The effective tax a trade pays is `max(decay, static)` per
    ///         direction, so a token may set ONLY these decay fields (static bps + duration zero) for a
    ///         pure decaying launch tax. Set during init.
    uint40 public taxDecayDuration;

    /////////////////////////// pure storage ///////////////////////

    /// @notice Timestamp when token graduated (0 if not graduated)
    uint40 public graduationTimestamp;

    //////////////////////// Events //////////////////////

    /// @notice Emitted once during init with the dev-supplied tax config. `startTaxFromLaunch` selects
    ///         the tax-window anchor (creation vs graduation). The three `*Decay*` fields configure the
    ///         optional linear launch-tax decay (start rate + duration, anchored as `startTaxFromLaunch`
    ///         selects); all 0 when no decay is configured.
    event RealmTaxableTokenInitialized(
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint40 taxDurationSeconds,
        bool startTaxFromLaunch,
        uint16 buyTaxDecayStartBps,
        uint16 sellTaxDecayStartBps,
        uint40 taxDecayDuration
    );

    /// @notice Emitted whenever `setTaxBps` successfully updates the buy/sell tax rates. Only the
    ///         new values are carried; indexers can resolve old values from the prior
    ///         `RealmTaxableTokenInitialized` event or the most recent prior `TaxBpsUpdated`.
    event TaxBpsUpdated(uint16 newBuyTaxBps, uint16 newSellTaxBps);

    /// @notice Emitted when a token's liquidity earnings allocation is turned into a locked LP position by
    ///         `processLiquidity`. Shared by both venues; a few fields carry a slightly venue-specific
    ///         meaning:
    ///         - V4: `ethIn` is the ETH deposited single-sided just below the price, `tokensAdded` is
    ///           always 0 (an ETH-only bid wall), and `liquidity` is the Uniswap-V4 liquidity units minted.
    ///         - V2: `ethIn`/`tokensAdded` are the ETH and tokens paired into the V2 LP (half the buffered
    ///           tokens are sold for the ETH side), and `liquidity` is the V2 LP tokens minted (locked at
    ///           the dead address).
    event LiquidityAdded(uint256 ethIn, uint256 tokensAdded, uint256 liquidity);

    /// @notice Emitted when a token's burn earnings allocation removes supply. Shared by both venues;
    ///         `ethSpent` is venue-specific:
    ///         - V4: the buffered ETH spent buying the tokens back before burning them (`processBurn`).
    ///         - V2: always 0 — the burn share is taken in TOKEN-space during the swap-back, before the
    ///           sell, so no ETH round trip happens and no ETH is spent to burn.
    ///         Summing `ethSpent` across both venues therefore gives the protocol-wide ETH actually
    ///         spent on buy-backs.
    event CreatorTaxBurn(uint256 ethSpent, uint256 tokensBurned);

    //////////////////////// Errors //////////////////////

    error NotTokenOwner();
    error CannotRescueSelfToken();
    error TaxBpsCanOnlyDecrease();
    /// @notice A dividends allocation was configured without the payout asset that makes it payable.
    error DividendsRequirePayoutConfig();

    //////////////////////////////////////////////////////

    /// @notice Allows the contract to receive ETH (V2: from the router during tax swap-backs;
    ///         V4: defensive — the V4 token is not expected to hold ETH).
    receive() external payable {}

    /// @notice Marks the token as graduated and records the timestamp.
    /// @dev Can only be called by the pre-set graduator contract. Overrides `RealmToken` to add
    ///      timestamp tracking. `graduationTimestamp` is the tax-window anchor for tokens configured
    ///      with `startTaxFromLaunch == false`; for `startTaxFromLaunch == true` tokens it is only the
    ///      V4 hook's "has graduated?" guard via `getTaxConfig` (the window is creation-anchored).
    /// @dev Also STARTS the dividend accumulator, right here, so holders begin earning the moment the
    ///      token goes live rather than whenever the first earnings happen to arrive.
    ///
    ///      The graduator still holds the whole graduating supply at this instant, which under the old
    ///      round machinery would have poisoned an opening denominator. It cannot here: there is no
    ///      opening denominator. The eligible supply is read only when a distribution lands, and none
    ///      can before the graduator has moved its supply into the pool — the buffer is empty — so its
    ///      balance never dilutes anyone.
    ///
    ///      `_onGraduatedEarnings` stays as the fallback and is NOT redundant: a deploy buy large enough
    ///      to graduate the token inside `createToken` runs this before the factory has called
    ///      `initializeEarningsAllocation`, so `hasDividends` is still false here and the accumulator
    ///      starts on the first earnings instead.
    function markGraduated() external virtual override(IRealmToken, RealmToken) {
        require(msg.sender == graduator, OnlyGraduatorAllowed());

        graduated = true;
        graduationTimestamp = uint40(block.timestamp);
        emit Graduated();
        // After `Graduated`, never before: the indexer reads `DividendsActivated` as following it.
        if (hasDividends) _activateDividends();
    }

    /// @notice Allows the token owner OR the launchpad owner to rescue stuck ERC20 balances (never the
    ///         token's own balance; ETH is intentionally not rescuable — see below).
    /// @dev Two rules:
    ///      (1) Self-token rescue is disallowed — the caller must NEVER siphon accrued tax balance
    ///          ahead of a swap-back.
    ///      (2) ETH is intentionally NOT rescuable. The token legitimately holds ETH (e.g. the V4 burn
    ///          buffer awaiting `processBurn`), and dropping the sweep path avoids racing that buffer;
    ///          any stray ETH is simply left in the contract, effectively benefiting holders. Passing
    ///          `address(0)` reverts.
    /// @dev The launchpad owner is included so the protocol admin can sweep stuck ERC20s on
    ///      factory-deployed tokens where `owner == address(0)` makes the token-owner path unreachable.
    ///      Rescued ERC20s go to `owner` (which may be `address(0)`, in which case the transfer reverts —
    ///      acceptable, as a stuck-balance rescue with no recipient is a no-op anyway).
    /// @param token ERC20 to rescue. `address(this)` and `address(0)` both revert.
    /// @dev ⚠️ Rescues only what `_sweepableAsset` says is unclaimed. A dividend payout asset sits in
    ///      this same balance, and handing an undistributed pot to the owner would not lose it — it would
    ///      TRANSFER it from holders to the owner, which is worse. Never open-code
    ///      `IERC20(token).balanceOf(address(this))` on a sweep path.
    function rescueTokens(address token) external virtual {
        require(msg.sender == owner || msg.sender == launchpad.owner(), NotTokenOwner());
        // disallow rescuing the token's own balance to prevent siphoning accrued taxes
        require(token != address(this), CannotRescueSelfToken());
        IERC20(token).safeTransfer(owner, _sweepableAsset(token));
    }

    /// @notice Updates `buyTaxBps` and/or `sellTaxBps`. Today this is decrease-only — any attempt
    ///         to raise either rate reverts with `TaxBpsCanOnlyDecrease`. Passing a value equal to
    ///         the current one is allowed (no-op for that side). `taxDurationSeconds` and
    ///         `graduationTimestamp` are untouched.
    /// @dev The function name is intentionally generic (`setTaxBps`) even though the body enforces
    ///      a narrower decrease-only rule. This keeps the ABI stable if the policy is ever relaxed.
    /// @dev Callable by the token owner OR the launchpad owner — same dual-auth pattern as
    ///      `swapBack` / `rescueTokens`. On factory-deployed tokens (`owner == address(0)`) only
    ///      the launchpad-owner branch is reachable, which is intentional.
    /// @param newBuyTaxBps New buy tax rate in basis points. Must be `<= buyTaxBps`.
    /// @param newSellTaxBps New sell tax rate in basis points. Must be `<= sellTaxBps`.
    function setTaxBps(uint16 newBuyTaxBps, uint16 newSellTaxBps) external virtual {
        require(msg.sender == owner || msg.sender == launchpad.owner(), NotTokenOwner());
        require(newBuyTaxBps <= buyTaxBps && newSellTaxBps <= sellTaxBps, TaxBpsCanOnlyDecrease());

        emit TaxBpsUpdated(newBuyTaxBps, newSellTaxBps);

        buyTaxBps = newBuyTaxBps;
        sellTaxBps = newSellTaxBps;
    }

    //////////////////////// EARNINGS ALLOCATION //////////////////////

    /// @notice Factory-only, creation-time setter for the earnings-allocation split (burn / dividends /
    ///         liquidity bps; the fund wallets take the remainder). Callable exactly once, during the
    ///         deploy tx, by the factory that initialized this token — guarded by the transient
    ///         `tokenFactory`, which is zero outside that tx (same pattern as `registerFees`).
    /// @dev A non-zero `_dividendsBps` is REFUSED here: this overload configures no payout asset and
    ///      never sets `hasDividends`, so the slice would be carved out of every post-graduation earning
    ///      and buffered into `pendingNative` with nothing to credit it and no `processDividends` that
    ///      does not revert `DividendsNotActive`. Worse, `_reservedNative()` returns 0 without
    ///      `hasDividends`, so the permissionless `sweepStrayEth()` would keep recycling that buffer
    ///      through the split. A dividends allocation must come in through the 5-argument overload.
    function initializeEarningsAllocation(uint16 _burnBps, uint16 _dividendsBps, uint16 _liquidityBps)
        external
        virtual
    {
        require(msg.sender == tokenFactory, Unauthorized());
        require(_dividendsBps == 0, DividendsRequirePayoutConfig());
        _initializeEarningsAllocation(_burnBps, _dividendsBps, _liquidityBps);
    }

    /// @notice Same as the three-bps overload, plus the single asset the dividends slice buys. Kept as a
    ///         separate overload so the original signature stays untouched.
    /// @dev `hasDividends` is what actually turns the feature on. It lives on `RealmToken`, packed into
    ///      the `pair` slot `_update` already loads, so a token that leaves `_dividendsBps` at 0 pays
    ///      nothing for the feature on any transfer.
    function initializeEarningsAllocation(
        uint16 _burnBps,
        uint16 _dividendsBps,
        uint16 _liquidityBps,
        address _dividendToken
    ) external virtual {
        // Named for the ABI, unread here: the extension decodes them straight out of calldata.
        _burnBps;
        _dividendsBps;
        _liquidityBps;
        _dividendToken;
        // Runs in the extension: the payout configuration is validated once, at creation, and the
        // validation is the same ~0.9 KB of bytecode a clone would otherwise carry forever. Delegated
        // rather than duplicated, so there is exactly one copy of the rules.
        _delegateToDividendLogic();
    }

    /// @notice Same again, for a token paying in UP TO `MAX_DIVIDEND_ASSETS` assets: the payout set, the
    ///         bps split of the dividends slice between its members, and the swap route each asset is
    ///         bought through. `dividendWeightsBps` must sum to 10,000 and hold no zero; the assets must
    ///         be distinct; `DIVIDEND_SELF_TOKEN` is only legal on its own. The single-asset overload
    ///         above is exactly this with a one-entry set and no route.
    /// @dev The routes are the creator's choice and are fixed here for the token's life — the registry
    ///      records them against this token and refuses to rewrite them. It checks the pools they name
    ///      exist and hold liquidity; it cannot check the price those pools quote is the asset's real
    ///      one, and nobody reviews that afterwards either.
    function initializeEarningsAllocation(
        uint16 _burnBps,
        uint16 _dividendsBps,
        uint16 _liquidityBps,
        address[] calldata _dividendTokens,
        uint16[] calldata _dividendWeightsBps,
        bytes[] calldata _dividendRoutes
    ) external virtual {
        // Named for the ABI, unread here: the extension decodes them straight out of calldata.
        _burnBps;
        _dividendsBps;
        _liquidityBps;
        _dividendTokens;
        _dividendWeightsBps;
        _dividendRoutes;
        _delegateToDividendLogic();
    }

    /// @notice Routes ETH earnings (post-graduation swap tax + LP-fee creator share) through the
    ///         earnings-allocation split before they reach the fund wallets. Overrides the base
    ///         passthrough; see `EarningsAllocation`.
    function accrueFees() external payable virtual override(IRealmToken, RealmToken) {
        // V4 is ETH-native, so it carves both the burn and liquidity slices from this ETH. (On V2 this
        // path is only hit pre-graduation — where it short-circuits to the fund wallets — or by stray ETH,
        // which with no ETH-side burn/liquidity handlers simply folds to the fund wallets.)
        _allocateEthEarnings(msg.value, burnBps, liquidityBps);
    }

    /// @dev Earnings split routes each slice post-graduation only; pre-graduation the whole amount
    ///      goes to the fund wallets. Reads the base `RealmToken.graduated` flag.
    function _earningsGraduated() internal view override returns (bool) {
        return graduated;
    }

    /// @dev Routes the fund-wallet slice to this token's master fee handler — the same path all
    ///      earnings took before the allocation split was introduced.
    function _depositToFund(uint256 amount) internal override {
        IRealmMasterFeeHandler(feeHandler).depositFees{value: amount}(address(this));
    }

    /// @dev Dividends accrue as native into the packed per-leg buffer — one SSTORE for all three legs,
    ///      well inside the router gas budget — and are converted out-of-band by `processDividends`.
    ///      A token with no dividend configuration has a zero native weight total, so this consumes
    ///      nothing and the slice folds back to the fund wallets.
    function _handleDividends(uint256 amount) internal override returns (uint256 unconsumed) {
        return _accrueDividends(amount);
    }

    /// @inheritdoc EarningsAllocation
    /// @dev FALLBACK activator. The normal path is `markGraduated()`, which starts the accumulator the
    ///      moment the token goes live; this covers the one case that misses it — a deploy buy large
    ///      enough to graduate the token INSIDE `createToken`, where `markGraduated()` runs before the
    ///      factory has called `initializeEarningsAllocation` and `hasDividends` is therefore still
    ///      false. Such a token starts accruing on the first earnings it routes instead.
    /// @dev Hooked HERE rather than in `_handleDividends` so the Uniswap-V2 self-token leg is covered
    ///      too: that leg is carved in token space and never reaches `_handleDividends`, so a token
    ///      paying only in itself would otherwise never start.
    /// @dev One-off cost: one SSTORE per configured asset, once per token, inside the router's gas
    ///      budget. If it ever ran out of gas the fee falls through to the treasury and the next accrual
    ///      activates instead — self-healing, not a one-shot.
    function _onGraduatedEarnings() internal override {
        if (hasDividends && dividendAssets[0].lastDistribution == 0) _activateDividends();
    }

    //////////////////////// DIVIDEND LOGIC EXTENSION //////////////////////

    /// @notice The `DividendDistributionLogic` extension this token's four out-of-band dividend entry
    ///         points execute in, against this token's own storage.
    /// @dev Declared here and implemented by each concrete token (which deploys its own alongside
    ///      itself), so a venue that forgets to wire one does not compile.
    function dividendLogic() public view virtual returns (address);

    /// @dev Runs the extension's copy of the entry point against THIS contract's storage, balance and
    ///      transient slots, forwarding calldata and returndata untouched. The extension exists for one
    ///      reason: the conversion, the venue routing and the payout loop are ~8.6 KB of bytecode a
    ///      cloned token cannot afford under EIP-170, and they only ever run out-of-band. Nothing on the
    ///      transfer hot path goes through here.
    /// @dev ⚠️ The extension MUST have byte-identical storage layout to this token — it writes round
    ///      state and pots directly. That is guaranteed structurally (both inherit the same venue base,
    ///      neither adds state) and pinned by `just check-dividend-layout`.
    /// @dev The assembly is the standard proxy forward and it is load-bearing, not an optimisation: the
    ///      delegated entry points revert with distinct custom errors a keeper decodes
    ///      (`BelowDividendThreshold` vs `DividendConversionFailed`), so the returndata has to be
    ///      bubbled verbatim — `(bool ok,) = logic.delegatecall(msg.data); require(ok)` would erase it,
    ///      and OZ's `Address.functionDelegateCall` buys the same behaviour for bytecode this clone does
    ///      not have.
    /// @dev NOT annotated `memory-safe`, deliberately: `calldatacopy(0, 0, calldatasize())` overwrites
    ///      the free-memory pointer at 0x40 and the zero slot at 0x60, which the annotation forbids.
    ///      Harmless because the block always ends in `return`/`revert`, but promising the optimizer
    ///      otherwise is not. OpenZeppelin's `Proxy._delegate` leaves the identical body unannotated for
    ///      exactly this reason.
    function _delegateToDividendLogic() internal {
        address logic = dividendLogic();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), logic, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    //////////////////////// DIVIDEND HOOKS //////////////////////

    /// @inheritdoc RealmToken
    function _onBalanceChange(address from, address to, uint256) internal override {
        _onDividendTransfer(from, to);
    }

    /// @inheritdoc DividendDistribution
    /// @dev Reads the `RealmToken` field packed into the `pair` slot, which `_update` has already loaded
    ///      by the time the transfer hook asks — so the loop bound costs a warm SLOAD, not a cold one.
    function _dividendAssetCount() internal view override returns (uint256) {
        return dividendAssetCount;
    }

    /// @inheritdoc DividendDistribution
    function _dividendBalanceOf(address account) internal view override returns (uint256) {
        return balanceOf(account);
    }

    /// @inheritdoc DividendDistribution
    /// @dev Exactly four addresses. Three are free to test — `address(this)`, the `DEAD_ADDRESS`
    ///      constant, and `pair`, which is in the slot `_update` has already loaded. `launchpad` is the
    ///      one that costs: it lives in its own slot (no address fits beside `pair` and the three warm
    ///      flags), so it is a cold SLOAD on the first of the two calls per transfer and warm on the
    ///      second. It is ordered last so the pair side of a swap short-circuits before reaching it.
    /// @dev It is not droppable. The hot tracking path and `_dividendEligibleSupply` must name the SAME
    ///      set: the denominator already subtracts the launchpad's balance, so a launchpad that earned
    ///      shares here would be paid out of a pot that never counted it — over-drawing the round.
    /// @dev Nothing else needs listing, and that is the minimum rule paying for itself: the V4 position
    ///      manager, the routers, the liquidity adder and the GRADUATOR all hold a balance only within a
    ///      single transaction, and an address that is empty when a round opens is worth zero for that
    ///      whole round however much it holds in between. The exclusion list only has to name addresses
    ///      that hold a balance CONTINUOUSLY across a round. (This is also why the first round opens on
    ///      the first earnings rather than inside `markGraduated()` — see `_handleDividends`.)
    /// @dev Creator vaults are deliberately NOT here: they hold a real, merely-vested team allocation
    ///      continuously across rounds, so they are ordinary holders (and `RealmCreatorVault` accepts and
    ///      can sweep whatever it is paid).
    function _dividendExcluded(address account) internal view override returns (bool) {
        return account == address(this) || account == pair || account == DEAD_ADDRESS || account == address(launchpad);
    }

    /// @inheritdoc DividendDistribution
    function _dividendEligibleSupply() internal view override returns (uint256) {
        return totalSupply() - balanceOf(pair) - balanceOf(address(this)) - balanceOf(address(launchpad))
            - balanceOf(DEAD_ADDRESS);
    }

    //////////////////////// COMMITTED FUNDS //////////////////////

    /// @notice Routes stray native — whatever this token holds beyond the buffers and pots it owes —
    ///         back through the earnings-allocation split. Permissionless: stray native is not
    ///         recoverable by whoever sent it under any design, so it becomes token earnings (fund /
    ///         dividends / liquidity, plus its own burn slice) instead of sitting dead. No-ops when
    ///         there is nothing stray, and pre-graduation it deposits the whole balance to the fund
    ///         wallets — the destination `rescueTokens(address(0))` used to send it to.
    /// @dev Shares are `(burnBps, liquidityBps)` because stray native had NO upstream token-space peel:
    ///      its burn and liquidity slices have to be carved here or not at all. On V4 they land in the
    ///      buy-back and bid-wall buffers. On V2 neither bucket has a native-side handler — a V2 pair
    ///      reverts `INVALID_TO` when asked to deliver a token to its own address, which is the same
    ///      constraint that forces a self-token dividend payout into token space — so both slices fall
    ///      through to the fund wallets, exactly as `accrueFees` already does with native on that venue.
    ///      Passing `(0, 0)` here instead would renormalize those slices into the dividend pot, paying
    ///      holders money earmarked for burning.
    /// @dev `_sweepableNative` is what keeps the dividend buffers, the undelivered pots and each venue's
    ///      own buffers out of the sweep. This entry point is permissionless and repeatable, so
    ///      open-coding the subtraction would let anyone recycle the dividend pot through the split and
    ///      hand its fund-wallet slice to the creator's receivers on every call.
    /// @dev `virtual` for the same reason `accrueFees` is: it is the only other entry point that
    ///      reaches `_allocateEthEarnings`, and the dividend extension must be able to stub it out or
    ///      the whole earnings split is linked into the extension's bytecode, where it is dead weight it
    ///      has no room for.
    function sweepStrayEth() external virtual nonReentrant {
        _allocateEthEarnings(_sweepableNative(), burnBps, liquidityBps);
    }

    /// @notice Native balance that is genuinely stray — not owed to anyone — and may therefore be swept
    ///         back through the earnings split.
    /// @dev Every sweep and swap-back path MUST route through this instead of reading
    ///      `address(this).balance`. Three call sites used to subtract their own buckets by hand; a
    ///      fourth bucket (the dividend pots) is exactly the kind of addition that gets forgotten in one
    ///      of them, and the failure mode is not a lost balance but a silent transfer of holders' money
    ///      to the creator's fee receivers.
    function _sweepableNative() internal view returns (uint256) {
        uint256 reserved = _reservedNative();
        uint256 balance = address(this).balance;
        return balance > reserved ? balance - reserved : 0;
    }

    /// @notice ERC20 balance of `asset` that is not owed to dividend holders.
    function _sweepableAsset(address asset) internal view virtual returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (!hasDividends) return balance;
        uint256 reserved = committedDividends(asset);
        return balance > reserved ? balance - reserved : 0;
    }

    /// @dev Native this contract holds on someone else's behalf. Venues extend it with their own
    ///      buffers; the base covers EVERY asset's native buffer plus the undelivered pot of whichever
    ///      asset is the native one.
    /// @dev The loop is not optional. `sweepStrayEth()` is permissionless and repeatable, so an asset
    ///      whose buffer this forgot would be recycled through the earnings split on every call, handing
    ///      its fund-wallet slice to the creator's receivers out of holders' money.
    function _reservedNative() internal view virtual returns (uint256 reserved) {
        if (!hasDividends) return 0;
        uint256 n = dividendAssetCount;
        for (uint256 i; i < n; ++i) {
            DivAsset storage a = dividendAssets[i];
            reserved += a.pendingNative;
            if (a.token == address(0)) reserved += a.owed;
        }
    }

    //////////////////////// VIEW FUNCTIONS //////////////////////

    /// @notice Pre-graduation fee policy. Same LP fee as the base, plus the effective tax for this
    ///         direction — `max(decay, static)` — which is 0 outside both windows. For
    ///         `startTaxFromLaunch == true` tokens the launchpad charges the exact rate the V4 hook /
    ///         V2 `_update` apply post-graduation; for graduation-anchored tokens neither window has
    ///         started pre-graduation, so the tax here is 0.
    function getLaunchpadFees(IRealmToken.LaunchpadTrade calldata trade)
        external
        view
        virtual
        override(IRealmToken, RealmToken)
        returns (IRealmToken.LaunchpadFees memory)
    {
        uint16 taxBps = _effectiveTaxBps(trade.isBuy);
        return IRealmToken.LaunchpadFees({lpFeeBps: lpFeeBps, treasuryShareBps: treasuryShareBps, taxBps: taxBps});
    }

    /// @notice Returns the effective tax configuration for the PREVIOUSLY-deployed `RealmSwapHook` (and
    ///         off-chain readers). Reports the CURRENT effective rates — `max(decay, static)` per direction,
    ///         which change every second while the decay window is open — so that hook, which re-reads this
    ///         on every swap, applies the right (possibly decaying) rate.
    /// @dev LEGACY, kept for backwards compatibility — do not remove. The CURRENT `RealmSwapHook` reads
    ///      `getSwapFees(isBuy)` below instead. This stays live for two readers that cannot be migrated:
    ///      off-chain integrators, and the older hook still serving every token already graduated onto it
    ///      (dropping this would break their swaps). That older hook applies the tax expiry itself, hence
    ///      the both-directions + synthetic-duration shape retained here.
    /// @dev That hook expires tax when `block.timestamp > graduationTimestamp + taxDurationSeconds`. Both
    ///      windows are anchored per `startTaxFromLaunch` (at `launchTimestamp` or `graduationTimestamp`),
    ///      so the returned `taxDurationSeconds` is SYNTHETIC: the seconds from `graduationTimestamp` to
    ///      the latest window end (`anchor + max(static, decay) duration`), keeping the hook open for the
    ///      whole effective window regardless of anchor. Once both windows close this returns a fully
    ///      zeroed tax (rates AND duration), so the hook stops taxing; the zeroed rates also cover the
    ///      edge where the window expires before graduation and a swap lands in the graduation block.
    function getTaxConfig() external view virtual override(IRealmToken, RealmToken) returns (TaxConfig memory config) {
        uint40 graduationTs = graduationTimestamp;
        (uint16 effBuy, uint16 effSell) = _effectiveTaxBps();

        // No active tax — both windows closed, not yet anchored, or the decay floored to 0 at its tail.
        // Report zeros so the deployed hook stops taxing; `graduationTimestamp` is surfaced for reference.
        // Both directions share one decay schedule and one static window (see `_effectiveTaxBps`), so a
        // single `effBuy == 0 && effSell == 0` check settles "is anything still owed" for the whole token.
        if (effBuy == 0 && effSell == 0) {
            return TaxConfig({buyTaxBps: 0, sellTaxBps: 0, taxDurationSeconds: 0, graduationTimestamp: graduationTs});
        }

        // Active: report a duration that, added to `graduationTimestamp`, lands exactly on the latest
        // window end — so the deployed hook's `block.timestamp > graduationTimestamp + taxDurationSeconds`
        // expiry tracks the true window even for a decay-only token (whose static `taxDurationSeconds` is
        // 0). Before graduation the hook is never invoked (swaps revert), and `graduationTimestamp == 0`,
        // so the tax anchor stands in as the reference — a creation-anchored token then reports its
        // configured duration (`windowEnd - launchTimestamp`). A non-zero effective rate implies the
        // window is open, so `windowEnd >= block.timestamp >= referenceTime` and the subtraction cannot
        // underflow.
        uint256 anchor = _taxAnchor();
        uint256 referenceTime = graduationTs != 0 ? graduationTs : anchor;
        config = TaxConfig({
            buyTaxBps: effBuy,
            sellTaxBps: effSell,
            taxDurationSeconds: uint40(anchor + _maxWindowDuration() - referenceTime),
            graduationTimestamp: graduationTs
        });
    }

    /// @notice Returns the fees `RealmSwapHook` charges on a V4 swap in direction `isBuy` right now (see
    ///         `IRealmToken`): the always-on post-graduation LP fee, plus the CURRENT effective tax —
    ///         `max(decay, static)` for that direction, which changes every second while the decay window
    ///         is open — so the hook, which re-reads this on every swap, applies the right (possibly
    ///         decaying) rate.
    /// @dev The tax-window (and decay) logic lives here, in `_effectiveTaxBps(isBuy)`, so the hook stays
    ///      agnostic to the schedule: it gets zero tax once the window closes (or before a
    ///      graduation-anchored token graduates). The LP fee is always effective.
    function getSwapFees(bool isBuy)
        external
        view
        virtual
        override(IRealmToken, RealmToken)
        returns (IRealmToken.RealmTradeFees memory)
    {
        return IRealmToken.RealmTradeFees({taxBps: _effectiveTaxBps(isBuy), lpFeeBps: swapLpFeeBps});
    }

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @dev Shared initializer body for taxable tokens. Subclasses override to add variant-specific
    ///      setup (e.g. router approval for V2, pool-manager pair check for V4) by chaining via
    ///      `super._initializeRealmTaxableToken(...)`.
    function _initializeRealmTaxableToken(IRealmToken.InitializeParams memory params, TaxConfigs memory taxCfg)
        internal
        virtual
        onlyInitializing
    {
        // Initialize the RealmToken state, and the graduator
        _initializeRealmToken(params);
        // there are no requirements at the token level. They are imposed at the factory level, so that this token implementation stays flexible
        _initializeTaxConfig(taxCfg);
    }

    /// @notice Internal helper to store tax configuration (static rates + window, anchor, and the
    ///         optional linear-decay rates + duration).
    /// @dev Tax-bps and duration bounds are enforced upstream in the factory. The
    ///      `RealmTaxableTokenInitialized` event carries `startTaxFromLaunch` plus the three `*Decay*`
    ///      fields configuring the linear launch-tax decay.
    function _initializeTaxConfig(TaxConfigs memory cfg) internal {
        emit RealmTaxableTokenInitialized(
            cfg.buyTaxBps,
            cfg.sellTaxBps,
            uint40(cfg.taxDurationSeconds),
            cfg.startTaxFromLaunch,
            cfg.buyTaxDecayStartBps,
            cfg.sellTaxDecayStartBps,
            uint40(cfg.taxDecayDuration)
        );

        buyTaxBps = cfg.buyTaxBps;
        sellTaxBps = cfg.sellTaxBps;
        taxDurationSeconds = uint40(cfg.taxDurationSeconds);
        startTaxFromLaunch = cfg.startTaxFromLaunch;
        buyTaxDecayStartBps = cfg.buyTaxDecayStartBps;
        sellTaxDecayStartBps = cfg.sellTaxDecayStartBps;
        taxDecayDuration = uint40(cfg.taxDecayDuration);
    }

    /// @dev True while EITHER the static or the decay window is open. Used by the V2 `_update` swap-back
    ///      drain to detect that no further tax can ever flow. The anchor is `startTaxFromLaunch`-dependent:
    ///      - `true`: anchored at `launchTimestamp` (creation-anchored, spans graduation). Non-zero after
    ///        init, so the window is live from launch.
    ///      - `false`: anchored at `graduationTimestamp` (graduation-anchored). Before graduation
    ///        `graduationTimestamp == 0`, so this returns false and no tax is charged pre-graduation.
    ///      The window length is the longer of the static and decay durations.
    function _taxWindowActive() internal view returns (bool) {
        uint256 anchor = _taxAnchor();
        if (anchor == 0) return false;
        return block.timestamp <= anchor + _maxWindowDuration();
    }

    /// @dev Anchor timestamp shared by both the static and decay windows: `launchTimestamp` if
    ///      `startTaxFromLaunch`, else `graduationTimestamp` (0 before graduation ⇒ no tax yet).
    function _taxAnchor() internal view returns (uint256) {
        return startTaxFromLaunch ? launchTimestamp : graduationTimestamp;
    }

    /// @dev The longer of the static and decay window durations (seconds).
    function _maxWindowDuration() internal view returns (uint256) {
        uint256 staticDuration = taxDurationSeconds;
        uint256 decayDuration = taxDecayDuration;
        return staticDuration > decayDuration ? staticDuration : decayDuration;
    }

    /// @dev Effective tax (bps) for ONE direction — the hot path. `getLaunchpadFees` (pre-graduation
    ///      launchpad) and the V2 intrinsic `_update` both know the trade direction, so they read and
    ///      compute ONLY the side they need: the opposite direction's `*TaxDecayStartBps` / `*TaxBps` are
    ///      never touched and its decay arithmetic is never run. `max(decay, static)`, with the decay
    ///      falling linearly from `*TaxDecayStartBps` at the anchor to the long-term `*TaxBps` at
    ///      `elapsed == taxDecayDuration` (decay-only token: `*TaxBps == 0`, the familiar start->0 ramp).
    /// @dev Curve is intentionally inlined rather than shared with `_effectiveTaxBps()` below via a helper:
    ///      a non-inlined internal helper costs call/arg overhead on every trade, so both readers keep their
    ///      own copy. ⚠️ KEEP THE TWO IN SYNC — any change to the `max(decay, static)` formula here must be
    ///      mirrored in `_effectiveTaxBps()` (covered by the `test/tokens/taxDecay.t.sol` curve tests).
    function _effectiveTaxBps(bool isBuy) internal view returns (uint16 bps) {
        uint256 anchor = _taxAnchor();
        if (anchor == 0) return 0; // graduation-anchored and not graduated yet ⇒ no tax
        uint256 elapsed = block.timestamp - anchor; // anchor is always in the past, so no underflow

        // Read only the requested direction's rates.
        (uint16 decayStartBps, uint16 staticBps) =
            isBuy ? (buyTaxDecayStartBps, buyTaxBps) : (sellTaxDecayStartBps, sellTaxBps);

        uint256 decayDuration = taxDecayDuration;
        if (decayDuration != 0 && elapsed < decayDuration) {
            uint256 remaining = decayDuration - elapsed;
            // (start*remaining + static*elapsed) / duration — exact at both endpoints
            bps = uint16((uint256(decayStartBps) * remaining + uint256(staticBps) * elapsed) / decayDuration);
        }
        if (elapsed <= taxDurationSeconds && staticBps > bps) bps = staticBps;
    }

    /// @dev Effective tax for BOTH directions, for `getTaxConfig` (the V4 hook read, which must surface buy
    ///      AND sell). Same `max(decay, static)` curve as `_effectiveTaxBps(bool)` above, run for each side
    ///      with the shared anchor/elapsed and decay/static DURATIONS read once. ⚠️ KEEP IN SYNC with the
    ///      single-direction reader above.
    /// @dev ⚠️ ASSUMPTION baked into `getTaxConfig`: buy and sell share one decay schedule
    ///      (`taxDecayDuration`) and one static window (`taxDurationSeconds`) — only the rate differs — so
    ///      both directions reach 0 at the SAME time. `getTaxConfig` relies on this: it derives a single
    ///      window end and treats `buy == 0 && sell == 0` as "tax fully over". If a future change gives the
    ///      two directions DIFFERENT durations, revisit `getTaxConfig` (per-direction window ends) and any
    ///      "both zero ⇒ inactive" logic.
    function _effectiveTaxBps() internal view returns (uint16 buyBps, uint16 sellBps) {
        uint256 anchor = _taxAnchor();
        if (anchor == 0) return (0, 0); // graduation-anchored and not graduated yet ⇒ no tax
        uint256 elapsed = block.timestamp - anchor; // anchor is always in the past, so no underflow

        // Static rates double as the decay's floor/target (the decay interpolates DOWN to them).
        uint16 buyStatic = buyTaxBps;
        uint16 sellStatic = sellTaxBps;

        uint256 decayDuration = taxDecayDuration;
        if (decayDuration != 0 && elapsed < decayDuration) {
            uint256 remaining = decayDuration - elapsed;
            buyBps = uint16((uint256(buyTaxDecayStartBps) * remaining + uint256(buyStatic) * elapsed) / decayDuration);
            sellBps =
                uint16((uint256(sellTaxDecayStartBps) * remaining + uint256(sellStatic) * elapsed) / decayDuration);
        }
        // After the decay window the static rate holds for the rest of its window; the max() also guards
        // the degenerate config where the start rate is below the static rate.
        if (elapsed <= taxDurationSeconds) {
            if (buyStatic > buyBps) buyBps = buyStatic;
            if (sellStatic > sellBps) sellBps = sellStatic;
        }
    }
}
