// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IRealmDividendSwapRegistry} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";

/// @title DividendInitLogic
/// @notice The creation-time half of the dividend machine: validating a payout set and writing it to the
///         token's storage. Runs once per token, at creation.
/// @dev Adds NO storage: every write lands in `DividendDistribution`'s declarations.
abstract contract DividendInitLogic is DividendDistribution {
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
        // Safe cast: `n <= MAX_DIVIDEND_ASSETS`.
        // forge-lint: disable-next-line(unsafe-typecast)
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
            // Safe cast: result is below `DIVIDEND_PRECISION_DECIMALS`.
            // forge-lint: disable-next-line(unsafe-typecast)
            assetDecimals >= DIVIDEND_PRECISION_DECIMALS ? 0 : uint8(DIVIDEND_PRECISION_DECIMALS - assetDecimals);
            dividendWeightsBps[i] = weights[i];
            emit DividendAssetInitialized(i, token, weights[i]);
        }
        require(weightSum == DIVIDEND_BPS_TOTAL, InvalidDividendAssetSet());

        // Kept for the indexers and integrators written against the single-asset shape, which read the
        // payout asset off this event. Emitted last so the per-asset events describe the whole set first.
        emit DividendsInitialized(dividendAssets[0].token);
    }
}
