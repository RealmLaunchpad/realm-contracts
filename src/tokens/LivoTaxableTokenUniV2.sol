// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableTokenUniV2Base} from "src/tokens/LivoTaxableTokenUniV2Base.sol";
import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {LivoDividendLogicUniV2} from "src/tokens/LivoDividendLogicUniV2.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigs} from "src/interfaces/ILivoTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet} (ARC: `WETH` is the 6-decimal USDC ERC-20 V2 quote).
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
// Aliased so the `chain-arc-*` recipe can import-swap it for the ARC venue: swap-back sells tax tokens
// for USDC (token→USDC) instead of ETH, since ARC has no wrappable WETH. See UniswapV2VenueArc.
import {UniswapV2Venue as UniswapV2Venue} from "src/libraries/UniswapV2Venue.sol";

/// @title LivoTaxableTokenUniV2
/// @notice ERC20 token implementation with time-limited buy/sell taxes for tokens that graduate to
///         a Uniswap V2 pair. Uniswap V2 has no swap callbacks, so taxes are taken **intrinsically**:
///         a portion of every pair-touching transfer is diverted to this contract's balance, then
///         periodically swapped to ETH on the V2 router and pushed to the master fee handler via
///         the same `accrueFees` path that V4 uses.
/// @dev Auto-swap-back fires inside `_update` on sells once the contract holds at least
///      `SWAP_THRESHOLD` tokens — or, after the tax window expires, any non-zero residual — and
///      never swaps more than `2 * SWAP_THRESHOLD` per sell so the per-sell price impact stays
///      bounded; excess carries to the next qualifying sell. Recursion is guarded by `_inSwap`.
///      At most `MAX_SWAPBACKS_PER_BLOCK` swap-backs per block: the counter resets on a new
///      block and silent-no-ops on overflow. Counter shape mirrors a reference token that passes
///      Go+'s "trading cooldown" heuristic; see `_processCollectedTokens`.
///      `swapBack(amountOutMinWei)` lets the owner trigger a slippage-bounded swap via a private
///      mempool. Factory-deployed tokens have `owner == address(0)`, so this entry point is
///      reachable only via the launchpad owner; the auto-trigger remains the live path.
/// @dev The out-of-band dividend entry points (`processDividends`, `claimDividends`) are thin
///      `delegatecall` stubs into `DIVIDEND_LOGIC`; only their
///      bodies live elsewhere, and nothing on the transfer hot path does. See `DividendDistributionLogic`.
contract LivoTaxableTokenUniV2 is LivoTaxableTokenUniV2Base {
    /// @notice The `LivoDividendLogicUniV2` extension the dividend entry points `delegatecall` into.
    /// @dev Deployed by THIS constructor rather than passed in or read from a manifest: the two are
    ///      storage-layout-coupled, so pairing them at deploy time is one more thing that can be wired
    ///      wrong for no benefit. Deploying it here makes the pair atomic, keeps every deploy script and
    ///      test unchanged (`new LivoTaxableTokenUniV2()` still takes no arguments), and costs only
    ///      creation-code size on the implementation — which EIP-170 does not bound, and EIP-3860 bounds
    ///      far above what this needs. Immutable, so clones read it straight from the implementation.
    address public immutable DIVIDEND_LOGIC;

    /// @notice Thrown by the manual `swapBack` before graduation (no tax accrues / no pair yet), and by
    ///         `processLiquidity` (no pool to add to before graduation).
    error NotGraduated();

    /// @notice Thrown by `processLiquidity` when there is no accrued liquidity ETH to add.
    error NothingToAdd();

    /// @notice Thrown by `processLiquidity` when it already ran this block (once-per-block cooldown).
    error ProcessCooldown();

    //////////////////////////////////////////////////////

    /// @notice Creates a new LivoTaxableTokenUniV2 instance which will be used as implementation for clones
    /// @dev Token configuration is set during initialization, not in constructor
    constructor() LivoToken() {
        require(block.chainid == DeploymentAddresses.BLOCKCHAIN_ID, "configuration for wrong chainId");
        DIVIDEND_LOGIC = address(new LivoDividendLogicUniV2());
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

    /// @inheritdoc LivoTaxableToken
    /// @dev Adds a one-shot infinite approval to the V2 router so `_processCollectedTokens` doesn't have to
    ///      re-approve every call. OZ ERC20 v5 skips allowance decrement when value is `type(uint256).max`.
    function _initializeLivoTaxableToken(ILivoToken.InitializeParams memory params, TaxConfigs memory taxCfg)
        internal
        override
        onlyInitializing
    {
        super._initializeLivoTaxableToken(params, taxCfg);
        _approve(address(this), address(UNISWAP_V2_ROUTER), type(uint256).max);
    }

    /// @notice Manually triggers a swap of `swapAmount` tax tokens for ETH and forwards the
    ///         proceeds to the fee handler. Callable by the token owner OR the launchpad owner;
    ///         primary use is MEV-protected execution via a private mempool.
    /// @param swapAmount Amount to swap. The auto path's `2 * SWAP_THRESHOLD` cap is NOT enforced
    ///        here so a private-mempool caller can drain a larger residual in one shot. The router
    ///        reverts if `swapAmount` exceeds the contract's balance.
    /// @param amountOutMinWei Minimum native proceeds the swap must yield, in QUOTE decimals: 18-dec
    ///        ETH on ETH-family builds, 6-dec USDC on ARC builds (where the swap sells to USDC, which
    ///        IS native balance). Caller's slippage budget. Applies to the post-burn, post-liquidity
    ///        remainder actually swapped, not to `swapAmount`.
    /// @dev If the per-block cap is hit, `_processCollectedTokens` silently no-ops (no event, no revert).
    /// @dev Post-graduation only: no tax accrues (and there is no pair to swap against) before
    ///      graduation, so a pre-graduation swap-back is always meaningless — reverting closes the
    ///      edge where a 100%-burn token could burn donated tokens before graduation.
    function swapBack(uint256 swapAmount, uint256 amountOutMinWei) external {
        require(msg.sender == owner || msg.sender == launchpad.owner(), NotTokenOwner());
        require(graduated, NotGraduated());
        _processCollectedTokens(swapAmount, amountOutMinWei, _sweepableAsset(address(this)));
    }

    /// @notice Turns the buffered liquidity TOKENS into a locked V2 LP position: sells half for ETH,
    ///         pairs the retained half with that ETH, and sends the LP to the dead address (permanent
    ///         depth). Permissionless, out-of-band (batches accruals off the swap hot path), mirroring the
    ///         V4 `processLiquidity` and the burn `processBurn` async pattern. Processes at most
    ///         `2 * SWAP_THRESHOLD` tokens per call, once per block (`ProcessCooldown`), capping what a
    ///         sandwich of the half-sell can extract per block; the remainder stays buffered.
    /// @param amountOutMinWei Slippage floor for the half-sell, in QUOTE decimals (18-dec ETH on
    ///        ETH-family builds, 6-dec USDC on ARC) — the swap reverts if it yields less. Keepers
    ///        should set it from the current price (via a private mempool); 0 invites sandwiching of
    ///        the half-sell, bounded by the current buffer. Only a keeper can reach this at all — the
    ///        floor is the keeper's own discipline, not a bound the contract can enforce.
    /// @dev Token-native: the token side is KEPT (not bought back — a V2 pair reverts INVALID_TO when
    ///      asked to send a token to its own address), only half is sold for the ETH side. Post-graduation
    ///      only. The sell + add run under `_inSwap` so the intrinsic tax / auto-swap-back don't fire on
    ///      the router's transfers. Unused tokens go back to the liquidity buffer they were carved from.
    ///      Unused ETH does NOT: `_processCollectedTokens` clamps its split to `_sweepableNative()`, so a
    ///      refund never folds into the next swap-back — `sweepStrayEth()` is what routes it, and on V2
    ///      (no native-side burn or liquidity handler) both slices fall through to the fund wallets.
    /// @dev `nonReentrant` on top of `_inSwap`, matching the V4 twin. `_inSwap` is a TAX suppressor, not
    ///      a serializer: a re-entrant call would find it already true — taxes and the auto swap-back
    ///      silently off — with `liquidityPendingTokens` already debited. Nothing reachable calls back
    ///      here today; the guard is what keeps that true when a venue or payout asset later does.
    function processLiquidity(uint256 amountOutMinWei) external nonReentrant {
        require(graduated, NotGraduated());
        // Keeper-gated: the caller supplies the floor for the half-sell, so a permissionless caller could
        // set it to zero around their own price manipulation and keep almost the whole sell. See
        // `LivoKeepersRegistry`.
        _requireKeeper();
        // Once per block + capped at the swap-back's own per-sell size: bounds what a sandwich of the
        // half-sell can extract per manipulated block once the caller can no longer choose the floor.
        require(block.number > lastLiquidityProcessBlock, ProcessCooldown());
        lastLiquidityProcessBlock = uint48(block.number);

        uint256 tokenIn = liquidityPendingTokens;
        require(tokenIn > 0, NothingToAdd());
        if (tokenIn > 2 * SWAP_THRESHOLD) tokenIn = 2 * SWAP_THRESHOLD;
        liquidityPendingTokens -= tokenIn;

        _inSwap = true;

        // Sell half the buffered tokens for native (native to self is fine; a token to self would revert).
        // Keep the other half for the LP token side.
        uint256 tokensToSell = tokenIn / 2;
        uint256 tokensForLp = tokenIn - tokensToSell;
        // note: we could swap the portion of tokens for liquidity as part of the _swapback function,
        // but as token price changes, that could break the expected token/eth ratio. So a safer move
        // is to swap here right before adding liquidity, even if that means one extra swap
        uint256 ethBefore = address(this).balance;
        if (tokensToSell > 0) {
            UniswapV2Venue.swapTaxToNative(UNISWAP_V2_ROUTER, WETH, tokensToSell, amountOutMinWei);
        }
        // 18-dec native on both chains: on ARC the swap's 6-dec USDC output IS native balance.
        uint256 ethFromSell = address(this).balance - ethBefore;

        // Pair the retained tokens with the native just obtained, via the per-chain venue: WETH
        // `addLiquidityETH` on ETH-family, two-ERC20 `addLiquidity` against the 6-dec USDC on ARC.
        // Accept any ratio (priority: don't revert); the router refunds the excess side to this contract.
        // The event reports the router's ACTUAL amounts, not the requested ones: the refunded remainder
        // never reached the pool (on ARC, so does the sub-1e-6-USDC flooring dust).
        uint256 ethAdded;
        uint256 tokensAdded;
        uint256 liquidity;
        if (tokensForLp > 0 && ethFromSell > 0) {
            (tokensAdded, ethAdded, liquidity) = UniswapV2Venue.supplyLiquidity(
                UNISWAP_V2_ROUTER, address(this), WETH, tokensForLp, ethFromSell, DEAD_ADDRESS
            );
        }

        // Whatever the router did not take stays earmarked for liquidity. `liquidityPendingTokens` was
        // debited by the full `tokenIn` above, so without this the unpaired remainder silently rejoins
        // the tax pool and gets re-split into the burn / dividend / fund buckets, spending an allocation
        // meant for liquidity. Two ways to get one: the half-sell produced no native (a 1-token buffer
        // sells 0) so nothing was paired at all, or the pool moved since the sell and `addLiquidity`
        // refunded the token side down to the live ratio.
        if (tokensForLp > tokensAdded) liquidityPendingTokens += tokensForLp - tokensAdded;

        _inSwap = false;

        emit LiquidityAdded(ethAdded, tokensAdded, liquidity);
    }

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @dev Intrinsic taxation hook. Order:
    ///      1. If `_inSwap`, bypass — the router's `transferFrom(this, pair, ...)` must be a plain
    ///         transfer, otherwise we recurse.
    ///      2. Inherited pre-graduation gate.
    ///      3. On a sell with accumulated balance, fire `_processCollectedTokens` capped at `2 * SWAP_THRESHOLD`.
    ///         Trigger fires at `balance >= SWAP_THRESHOLD`, OR — after the tax window expires —
    ///         on any non-zero residual (no fresh tax can push a sub-threshold balance across).
    ///         The per-block cap lives inside `_processCollectedTokens`; this outer branch deliberately does NOT
    ///         read `block.number` so static analyzers don't flag a trading cooldown.
    ///      4. In the tax window, on a pair-touching transfer from a non-graduator source, divert
    ///         `amount * bps / 10_000` to this contract and forward the rest.
    ///      The graduator exclusion is load-bearing: `markGraduated() → safeTransfer(pair) →
    ///      addLiquidityETH` runs with `to == pair` while `graduated == true` and (typically) the tax
    ///      window is still open, so without it the initial liquidity would be taxed.
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (_inSwap) {
            super._update(from, to, amount);
            return;
        }

        // Cache `pair` and `graduated` once. Both are packed in the same storage slot in
        // `LivoToken`, so this is a single SLOAD; the locals also let the buy/sell branches
        // below avoid re-reading them.
        address _pair = pair;
        bool _graduated = graduated;

        if ((!_graduated) && (to == _pair)) {
            revert TransferToPairBeforeGraduationNotAllowed();
        }

        bool isSell = (to == _pair);
        bool isBuy = (from == _pair);

        // Auto swap-back on sells. `from != graduator` is load-bearing: the graduator's initial
        // `addLiquidityETH` triggers `_update(graduator, pair, ...)` while the pair has zero
        // reserves, so firing `_processCollectedTokens` then would revert graduation (and could be griefed by
        // pre-funding `address(this)`). Per-block cap is enforced inside `_processCollectedTokens` to keep
        // `block.number` out of the transfer hook (Go+ flags such reads as a trading cooldown).
        if (isSell && from != graduator) {
            // Only the UNCOMMITTED balance is tax. `_sweepableAsset` is the single place that knows
            // which buckets share this balance (liquidity buffer, self-token dividend buffer, an
            // undelivered self-token dividend pot); a token with no allocation short-circuits inside it
            // to a plain `balanceOf` plus one warm SLOAD.
            uint256 contractBalance = _sweepableAsset(address(this));
            if (contractBalance >= SWAP_THRESHOLD) {
                uint256 swapAmount = contractBalance > 2 * SWAP_THRESHOLD ? 2 * SWAP_THRESHOLD : contractBalance;
                _processCollectedTokens(swapAmount, 0, contractBalance);
            } else if (contractBalance > 0 && !_taxWindowActive()) {
                // Post-window drain: window's closed, no fresh tax will ever flow in, so a residual
                // stuck below SWAP_THRESHOLD would otherwise sit forever. No 2*SWAP_THRESHOLD cap
                // needed: this branch only fires when contractBalance < SWAP_THRESHOLD, so the swap
                // is already small.
                // This path can only be reached if graduated==true. No risk of calling _processCollectedTokens before graduation
                _processCollectedTokens(contractBalance, 0, contractBalance);
            }
        }

        // charging the tax: only if graduated, only on pair-touching transfers, only while the
        // tax window is active (anchored at launch or graduation per `startTaxFromLaunch`). The rate is
        // the EFFECTIVE rate `max(decay, static)`, so a decaying launch tax is charged here too (and a
        // decay-only token, whose static bps are 0, still taxes during its decay window).
        if (_graduated && (isBuy || isSell) && _taxWindowActive() && from != graduator) {
            uint16 bps = _effectiveTaxBps(isBuy);
            if (bps > 0) {
                uint256 taxAmount = amount * bps / 10_000;
                if (taxAmount > 0) {
                    super._update(from, address(this), taxAmount);
                    super._update(from, to, amount - taxAmount);
                    return;
                }
            }
        }
        // no tax applied if we reached here
        super._update(from, to, amount);
    }

    /// @dev Processes `tokenAmount` of collected tax tokens through the earnings buckets in TOKEN-space:
    ///      burns the burn-share, sets the liquidity-share aside for `processLiquidity`, swaps the rest to
    ///      ETH on the V2 router, then routes that ETH through `_allocateEthEarnings` (dividends / fund).
    ///      `_inSwap` short-circuits `_update` during the router pull so it's a plain transfer (no
    ///      recursive tax / auto-trigger). Caller must size `tokenAmount` against the balance and any
    ///      per-sell cap.
    /// @dev Per-block cap: resets `swapbacksThisBlock` on a new block, increments on success;
    ///      same-block overflow silently no-ops (tx succeeds, no event, no balance change). Both
    ///      auto and manual paths go through here. The gate lives in `_processCollectedTokens` (not in
    ///      `_update`'s sell branch) so `block.number` stays out of the transfer hook — Go+ flags
    ///      such reads as a per-user trading cooldown.
    /// @param avail The caller's already-computed `_sweepableAsset(address(this))`. Passed in rather than
    ///        re-read: the auto path in `_update` needs it to decide whether to fire at all, and it is
    ///        the single most expensive read on that path (a `balanceOf` plus the allocation branches).
    function _processCollectedTokens(uint256 tokenAmount, uint256 amountOutMinWei, uint256 avail) internal {
        if (tokenAmount == 0) return;

        // Cache the counter so the post-router writes to `swapbacksThisBlock` and
        // `lastSwapbackBlock` (same packed slot) coalesce into a single SSTORE, and the
        // new-block reset doesn't pay for its own pre-router write.
        uint8 count = swapbacksThisBlock;
        if (block.number > uint256(lastSwapbackBlock)) {
            count = 0;
        }
        if (count >= MAX_SWAPBACKS_PER_BLOCK) return;

        // Never process a committed buffer as tax: the liquidity and self-token-dividend buffers share
        // this contract's token balance but are already earmarked. Clamp so the manual `swapBack` can't
        // reach them either.
        if (tokenAmount > avail) tokenAmount = avail;
        if (tokenAmount == 0) return;

        _inSwap = true;

        // Burn the burn-share in token-space FIRST — no ETH→token round trip. `_inSwap` keeps this a
        // plain transfer through `_update`. Applies to the amount processed this swap-back; 0 for
        // tokens without a burn allocation.
        uint256 burnAmount = tokenAmount * burnBps / BPS_TOTAL;
        if (burnAmount > 0) {
            _burn(address(this), burnAmount);
            // `ethSpent` is 0: the burn happens in token-space, with no ETH→token round trip.
            emit CreatorTaxBurn(0, burnAmount);
        }

        // Set aside the liquidity-share as TOKENS — kept on this contract (tracked by
        // `liquidityPendingTokens`), not swapped — for a later `processLiquidity`. 0 without a liquidity
        // allocation.
        uint256 liquidityAmount = tokenAmount * liquidityBps / BPS_TOTAL;
        if (liquidityAmount > 0) liquidityPendingTokens += liquidityAmount;

        // Set aside a SELF-TOKEN dividend leg's share as TOKENS too, for the same reason: it cannot be
        // bought back with ETH on V2. `_tokenSpaceDividendBps` is 0 unless such a leg is configured, and
        // `_splitEthEarnings` excludes the same share from the ETH it later routes, so the slice is
        // taken exactly once.
        uint256 dividendAmount = tokenAmount * _tokenSpaceDividendBps() / BPS_TOTAL;
        if (dividendAmount > 0) dividendPendingTokens += dividendAmount;

        uint256 swapAmount = tokenAmount - burnAmount - liquidityAmount - dividendAmount;

        // Sell the remainder for native via the per-chain venue: token→ETH on ETH-family, token→USDC on
        // ARC. On ARC the received 6-dec USDC IS native balance, so the balance reads below reflect the
        // proceeds with no unwrap. `amountOutMinWei` is in quote decimals (18-dec ETH / 6-dec USDC); the
        // auto path passes 0. See UniswapV2Venue.
        // Measured as a DELTA, not as the closing balance: the contract may already hold router refunds
        // from an earlier `processLiquidity`, and the event must report this swap's own proceeds so an
        // indexer can match it against the pair's `Swap`.
        uint256 ethBefore = address(this).balance;
        if (swapAmount > 0) {
            UniswapV2Venue.swapTaxToNative(UNISWAP_V2_ROUTER, WETH, swapAmount, amountOutMinWei);
        }
        uint256 ethFromSwap = address(this).balance - ethBefore;

        _inSwap = false;
        unchecked {
            ++count;
        }
        swapbacksThisBlock = count;
        lastSwapbackBlock = uint48(block.number);

        // Route THIS SWAP'S PROCEEDS, and only those. Pass `0, 0`: both the burn AND the liquidity
        // slices were already taken above in TOKEN-space, so `_splitEthEarnings` carves no native
        // burn/liquidity slice and renormalizes dividends/fund over the leftover.
        //
        // Stray native — router refunds from an earlier `processLiquidity`, a force-fed balance — is
        // deliberately NOT swept in here, even though it sits in the same balance. It had no token-space
        // peel, so renormalizing it over that same reduced denominator would pay the dividend pot the
        // share earmarked for burning and liquidity. `sweepStrayEth()` routes that population with the
        // `(burnBps, liquidityBps)` it deserves, and keeping the two apart is also what makes this
        // event's `ethAmount`/`ethToFund` pair describe one swap exactly.
        //
        // Clamped to `_sweepableNative()`: the swap is an external call, so a callback that accrues into
        // the dividend buffers mid-swap would otherwise be counted once there and once in this delta.
        uint256 sweepable = _sweepableNative();
        uint256 ethToFund = _splitEthEarnings(ethFromSwap < sweepable ? ethFromSwap : sweepable, 0, 0);

        // Emitted after the split (so the fund slice is known) but BEFORE the deposit, preserving the
        // historical on-chain order `CreatorTaxSwapback` → `CreatorFeesDeposited` the indexer relies on.
        // `ethFromSwap` (this swap) and `ethToFund` (what reaches the fee handler) are equal for a token
        // with no earnings allocation.
        emit CreatorTaxSwapback(swapAmount, ethFromSwap, ethToFund);
        if (ethToFund > 0) _depositToFund(ethToFund);
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

    /// @notice Same, for one of the payout assets of a token that pays in several. `assetIndex` selects
    ///         which; each asset crosses its own threshold, prices its own floor and holds its own
    ///         per-block cooldown, so a keeper services them one call at a time.
    /// @param assetIndex Which configured payout asset to service, `0 .. dividendAssetCount() - 1`.
    /// @param minOut Slippage floor for that asset's conversion, in its own decimals.
    /// @param holders Addresses to push that asset's accrued payouts to. May be empty.
    function processDividends(uint8 assetIndex, uint256 minOut, address[] calldata holders) external {
        assetIndex;
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
