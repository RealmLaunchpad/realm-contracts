// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmV4ExtensionBase} from "src/tokens/RealmV4ExtensionBase.sol";
import {IRealmV4Graduator} from "src/tokens/RealmTaxableTokenUniV4Base.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";

/// @title RealmDividendLogicUniV4
/// @notice The dividend extension `RealmTaxableTokenUniV4` `delegatecall`s its out-of-band entry
///         points into: the round machinery, the native -> payout-asset conversion, and the per-holder
///         push. Deployed alongside the token implementation and passed to its constructor.
/// @dev It shares `RealmTaxableTokenUniV4Base` with the token and adds NO state of its own, so the
///      compiler derives the same storage layout for both — the property the delegatecall depends on.
/// @dev Its PEER is `RealmEarningsLogicUniV4`, which carries the buy-back and liquidity processors:
///      once every buffer is keyed by quote the two halves no longer fit in one contract under
///      EIP-170. Neither delegates to the other, and `just check-dividend-layout` pins both against
///      the token.
///      Pinned by `just check-dividend-layout`.
contract RealmDividendLogicUniV4 is RealmV4ExtensionBase, DividendDistributionLogic {
    //////////////////////// DIVIDENDS //////////////////////    //////////////////////// DIVIDENDS //////////////////////

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

        address hook = IRealmV4Graduator(graduator).hookFor(address(0));
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
    // See `RealmV4ExtensionBase`, which carries the stub set both V4 extensions share.
}
