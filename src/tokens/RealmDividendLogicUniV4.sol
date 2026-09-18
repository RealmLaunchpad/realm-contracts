// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmV4ExtensionBase} from "src/tokens/RealmV4ExtensionBase.sol";
import {IRealmV4Graduator} from "src/tokens/RealmTaxableTokenUniV4Base.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {IRealmDividendSwapRegistry} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RealmDividendLogicUniV4
/// @notice The dividend extension `RealmTaxableTokenUniV4` `delegatecall`s its out-of-band entry
///         points into: the round machinery, the native or quote -> payout-asset conversion, and the
///         per-holder push. Deployed alongside the token implementation and passed to its constructor.
///         The creation-time configuration lives in its peer `RealmEarningsLogicUniV4` — run once per
///         token, it takes the room where the hot entry points do not need it.
/// @dev It shares `RealmTaxableTokenUniV4Base` with the token and adds NO state of its own, so the
///      compiler derives the same storage layout for both — the property the delegatecall depends on.
/// @dev Its PEER is `RealmEarningsLogicUniV4`, which carries the buy-back and liquidity processors:
///      once every buffer is keyed by quote the two halves no longer fit in one contract under
///      EIP-170. Neither delegates to the other, and `just check-dividend-layout` pins both against
///      the token.
///      Pinned by `just check-dividend-layout`.
contract RealmDividendLogicUniV4 is RealmV4ExtensionBase, DividendDistributionLogic {
    using SafeERC20 for IERC20;

    //////////////////////// QUOTE-DENOMINATED DIVIDENDS //////////////////////

    /// @notice `processDividends` for a buffer held in one of this token's QUOTES: converts what asset
    ///         `assetIndex` has accrued from earnings on `quote`'s pool into that asset, credits it to
    ///         the holders, and pushes `holders` their accruals. `quote == address(0)` is the shared
    ///         native machine, exactly `processDividends(uint8,uint256,address[])`.
    /// @dev What differs from the native path, and why:
    ///      - NO absolute threshold: `DIVIDEND_THRESHOLD` is native-denominated and means nothing in a
    ///        currency the creator picked. The keeper pays the gas and decides when a buffer is worth
    ///        converting, as it does for `processBurn(quote, …)`.
    ///      - The per-call cap is `_maxSpend`'s FRACTION of the buffer, for the same units reason, and
    ///        only on a leg that SWAPS. A payout that IS the quote has no swap: nothing to sandwich, the
    ///        whole buffer credits at once.
    ///      - A leg that swaps is keeper-only, ALWAYS — the staleness hatch never opens it, because
    ///        without a threshold there is nothing that evidences an absent keeper rather than a quiet
    ///        token, and a zero-floor conversion handed to anyone is the sandwich the gate exists for.
    ///        The passthrough keeps the hatch: it moves no money through a pool.
    ///      - NO treasury sweep for a dead pool: a quote pool nobody can swap on strands that quote's
    ///        buffer, as it strands `processBurn`'s. The registry legs pivot through native, whose
    ///        liquidity the payout asset's own route already vouches for.
    ///      - The once-per-block cooldown is the ASSET's, shared with the native leg and the other
    ///        quotes: one conversion of asset `i` per block, whichever buffer feeds it.
    /// @param minOut Slippage floor in the PAYOUT asset's units, checked on the final amount however
    ///        many pools the conversion crosses. Ignored by the passthrough.
    function processDividends(uint8 assetIndex, address quote, uint256 minOut, address[] calldata holders)
        external
        nonReentrant
        nonReentrantDividends
    {
        if (quote == address(0)) {
            _processDividends(assetIndex, minOut, holders);
            return;
        }
        _processQuoteDividends(assetIndex, quote, minOut, holders);
    }

    /// @dev The quote path's body. Mirrors `_processDividends`'s shape — gate, fund once per block,
    ///      credit, push, then the error that tells a keeper what to do next — over `quoteBuffers`.
    function _processQuoteDividends(uint8 assetIndex, address quote, uint256 minOut, address[] calldata holders)
        private
    {
        require(assetIndex < _dividendAssetCount(), DividendAssetOutOfRange());
        DivAsset storage asset = dividendAssets[assetIndex];
        require(asset.lastDistribution != 0, DividendsNotActive());
        address payout = asset.token;
        if (payout != quote || !dividendsStale(assetIndex)) _requireKeeper();

        bool cooldown = block.number <= asset.lastProcessBlock;
        uint256 spend;
        uint256 spent;
        uint256 out;
        if (!cooldown) (spend, spent, out) = _fundFromQuote(assetIndex, quote, payout, minOut);
        if (out != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            asset.lastProcessBlock = uint40(block.number);
            _creditDividends(assetIndex, out);
            emit DividendsFunded(quote, payout, spent, out);
        }

        if (holders.length != 0) {
            _pushDividends(assetIndex, holders);
        } else if (cooldown) {
            revert DividendProcessCooldown();
        } else if (spend == 0) {
            revert BelowDividendThreshold();
        } else if (out == 0) {
            revert DividendConversionFailed();
        }
    }

    /// @dev Debits asset `i`'s buffer on `quote` — the whole of it for a passthrough, `_maxSpend`'s
    ///      slice for a leg that swaps — converts it, and re-earmarks whatever the conversion did not
    ///      consume. Debit-first, so the reserve a mid-swap accrual is measured against already excludes
    ///      the spend; re-earmarked with `+=` on the live slot, so an accrual that landed during the swap
    ///      (`accrueFees` takes no lock) survives the write.
    /// @return spend what was attempted, 0 when nothing was buffered.
    /// @return spent what the conversion consumed; the rest is back on the buffer.
    /// @return out payout-asset units actually acquired, 0 when the conversion did not happen.
    function _fundFromQuote(uint256 i, address quote, address payout, uint256 minOut)
        private
        returns (uint256 spend, uint256 spent, uint256 out)
    {
        uint128[MAX_DIVIDEND_ASSETS] storage pending = quoteBuffers[_quoteIndex(quote)].dividendPending;
        uint256 buffered = pending[i];
        if (buffered == 0) return (0, 0, 0);
        spend = payout == quote ? buffered : _maxSpend(quote, buffered);
        // forge-lint: disable-next-line(unsafe-typecast)
        pending[i] = uint128(buffered - spend);
        (out, spent) = _acquireFromQuote(quote, payout, spend, minOut);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (spent < spend) pending[i] += uint128(spend - spent);
    }

    /// @dev Turns `amountIn` of `quote` into `payout`. Three shapes:
    ///      - `payout == quote`: nothing to do, the buffer already IS the payout.
    ///      - `payout == this token`: a buy-back on `quote`'s own pool, the `processBurn` primitive; a
    ///        partial fill reports what the pool actually took.
    ///      - anything else: the registry, which walks `quote`'s route backwards to native and the
    ///        payout's forward (or stops at native). A LOW-LEVEL call for the same reason the native leg
    ///        makes one: a registry revert must become "not converted", never a reverted distribution.
    ///        The registry consumes the whole `amountIn` or reverts, so `spent` is all or nothing.
    /// @return out payout units received, measured as a balance delta.
    /// @return spent quote units the conversion consumed.
    function _acquireFromQuote(address quote, address payout, uint256 amountIn, uint256 minOut)
        private
        returns (uint256 out, uint256 spent)
    {
        if (payout == quote) return (amountIn, amountIn);
        if (payout == address(this)) {
            uint256 balanceBefore = balanceOf(address(this));
            uint256 quoteBefore = _quoteHoldings(quote);
            uint256 reservedBefore = _quoteReserved(quote);
            // Precursor marker, BEFORE the swap: see the native override below.
            emit DividendBuyBackInitiated(quote, amountIn);
            if (!_buyBackTokens(IRealmV4Graduator(graduator).hookFor(quote), quote, amountIn, minOut)) return (0, 0);
            out = balanceOf(address(this)) - balanceBefore;
            if (out == 0) return (0, 0);
            return (out, _spent(quote, quoteBefore, reservedBefore));
        }
        // Fail CLOSED against a codeless registry, as `_swapNativeToDividendAsset` does.
        if (DIVIDEND_SWAP_REGISTRY.code.length == 0) return (0, 0);
        IERC20(quote).forceApprove(DIVIDEND_SWAP_REGISTRY, amountIn);
        uint256 before = payout == address(0) ? address(this).balance : IERC20(payout).balanceOf(address(this));
        (bool ok,) = DIVIDEND_SWAP_REGISTRY.call(
            abi.encodeCall(
                IRealmDividendSwapRegistry.swapAssetToAsset, (quote, payout, amountIn, minOut, address(this))
            )
        );
        if (!ok) {
            // No standing allowance to an upgradeable registry for a spend that never happened.
            IERC20(quote).forceApprove(DIVIDEND_SWAP_REGISTRY, 0);
            return (0, 0);
        }
        uint256 after_ = payout == address(0) ? address(this).balance : IERC20(payout).balanceOf(address(this));
        return (after_ - before, amountIn);
    }

    //////////////////////// DIVIDENDS //////////////////////

    /// @dev Adds the SELF-TOKEN payout shape: a token paying dividends in itself buys itself back on its
    ///      own native pool — the same leg `_acquireFromQuote` runs for an ERC20 quote, with native as
    ///      the quote. Native and third-asset payouts fall through to the base.
    /// @dev Reports what the pool actually took: the base debits only that, so whatever a partial fill
    ///      handed back through the router's `SWEEP` stays on the dividend ledger instead of becoming
    ///      stray that `sweepStrayEth` would re-split into the burn / liquidity / fund buckets.
    function _acquireDividendAsset(address asset, uint256 nativeIn, uint256 minOut)
        internal
        override
        returns (uint256, uint256)
    {
        if (asset != address(this)) return super._acquireDividendAsset(asset, nativeIn, minOut);
        return _acquireFromQuote(address(0), address(this), nativeIn, minOut);
    }

    ////////////////// NOT A TOKEN //////////////////
    // See `RealmV4ExtensionBase`, which carries the stub set both V4 extensions share.
}
