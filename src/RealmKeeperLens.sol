// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DividendDistribution} from "src/tokens/DividendDistribution.sol";

/// @dev Mirrors `DividendDistribution.MAX_DIVIDEND_ASSETS`. A file-level constant because an array
///      length must be one, and another contract's public constant is not. `RealmKeeperLens` re-exports
///      it so a test can assert the two have not drifted.
uint256 constant MAX_ASSETS = 3;

/// @dev The current, multi-asset generation: everything is addressed by asset index.
interface IDividendTokenMulti {
    function dividendAssetCount() external view returns (uint8);
    function dividendAssets(uint256 i) external view returns (DividendDistribution.DivAsset memory);
    function dividendsStale(uint256 i) external view returns (bool);
    function previewDividend(address holder, uint256 i) external view returns (uint256);
}

/// @dev The legacy single-asset generation. These also exist on the current one, where they answer
///      for asset 0 — which is why they are never used to tell the two apart.
interface IDividendTokenLegacy {
    function dividendToken() external view returns (address);
    function dividendsOwed() external view returns (uint128);
    function pendingNative() external view returns (uint88);
    function dividendsStale() external view returns (bool);
    function previewDividend(address holder) external view returns (uint256);
}

/// @dev Token-wide reads. `SWAP_THRESHOLD` / `*PendingTokens` exist only on V2, `*PendingEth` and the
///      quote getters only on V4 — which is exactly what makes them venue discriminators.
interface IDividendTokenCommon {
    function DIVIDEND_THRESHOLD() external view returns (uint256);
    function MAX_DIVIDEND_PER_CONVERSION() external view returns (uint256);
    function DIVIDEND_SWAP_REGISTRY() external view returns (address);
    function SWAP_THRESHOLD() external view returns (uint256);
    function dividendPendingTokens() external view returns (uint256);
    function liquidityPendingTokens() external view returns (uint256);
    function burnPendingEth() external view returns (uint256);
    function liquidityPendingEth() external view returns (uint256);
    function quoteBufferOf(address quote)
        external
        view
        returns (uint256 burnPending, uint256 liquidityPending, uint48 lastBurn, uint48 lastLiquidity);
    function quoteDividendPending(address quote) external view returns (uint128[MAX_ASSETS] memory);
}

/// @title RealmKeeperLens
/// @notice Collapses one dividend-keeper pass over a token set into a handful of `eth_call`s. Every
///         read the keeper makes before it sends a transaction is here, batched over an ARRAY of
///         tokens rather than one token at a time, so a run's read latency stops scaling with the
///         number of dividend tokens on the chain.
///
/// @dev Stateless, `view`-only, no owner, no storage, no upgrade path, no immutables. It is NOT part
///      of the money path and nothing on the money path knows it exists: it only calls the same
///      public getters an RPC client could call itself. A wrong answer here costs a keeper run, never
///      a holder's balance. Deployed once per chain; deploy a new one rather than "upgrading" it.
///
/// @dev Deliberately NOT a change to the token contracts. Tokens are non-upgradeable clones already
///      pressed against EIP-170, so the read-side ergonomics live out here where they cost nothing
///      and can be redeployed freely.
///
/// @dev EVERY external read goes through `_word` / low-level `staticcall` with the failure kept, not
///      bubbled. That is the same contract `Multicall3`'s `allowFailure: true` gave the keeper, and
///      it is load-bearing three times over: it tells the two on-chain generations apart, it tells
///      the V2 and V4 venues apart, and it lets an address that is not a Realm token at all come back
///      as a zeroed row instead of reverting the whole batch.
contract RealmKeeperLens {
    /// @notice Version of the Realm stack this contract belongs to.
    string public constant VERSION = "2.0";

    /// @notice The lens's copy of the token's payout-asset cap. Asserted equal to the token's in the
    ///         lens tests, so a token that grows its set cannot silently outgrow this.
    uint256 public constant MAX_DIVIDEND_ASSETS = MAX_ASSETS;

    /// @notice One payout asset's machine. Independent of its siblings by construction — its own
    ///         buffer, accumulator and staleness clock — so the keeper services each on its own.
    struct AssetState {
        /// @notice The payout asset: `address(0)` native, the token itself self-paying, else an ERC20.
        address asset;
        /// @notice Payout-asset units owed to holders and not yet delivered. The `payableHolders` floor
        ///         is a share of this.
        uint256 owed;
        /// @notice Native earnings buffered against this asset, awaiting a conversion.
        uint256 pendingNative;
        /// @notice When this asset last distributed. 0 = dividends have not activated yet.
        uint40 lastDistribution;
        /// @notice Whether this asset has aged past `STALE_DIVIDEND_WINDOW`, i.e. is treated as dead.
        bool stale;
    }

    /// @notice Everything one token contributes to a keeper pass.
    /// @dev A row whose `isDividendToken` is false is a zeroed placeholder: the address answered
    ///      nothing a Realm taxable token answers. The keeper skips it; the batch does not revert.
    struct TokenState {
        /// @notice `dividendToken()` answered, so this is a Realm taxable token of either generation.
        bool isDividendToken;
        /// @notice `dividendAssetCount()` answered, so this is the CURRENT generation and the indexed
        ///         entry points apply. False means the legacy single-asset one.
        bool multiAsset;
        /// @notice Venue discriminators, from which buffers answer. Replaces the keeper's revert-probing.
        bool isV2;
        bool isV4;
        /// @notice Configured payout assets. 1 on a legacy token, which is all it can have.
        uint8 assetCount;
        /// @notice Compile-time constants of the implementation this token was cloned from. Identical
        ///         across every token of that impl, so a keeper is free to cache them per impl and
        ///         ignore them here.
        /// @dev `dividendThreshold` is NOT a funding floor — it is the yardstick the permissionless
        ///      stale hatch measures a swapping asset's buffer against. Do not gate a keeper's own
        ///      "worth its gas" decision on it.
        uint256 dividendThreshold;
        uint256 swapThreshold;
        uint256 maxPerConversion;
        address swapRegistry;
        /// @notice V4 native buffers.
        uint256 burnPendingEth;
        uint256 liquidityPendingEth;
        /// @notice V2 token-space buffers.
        uint256 dividendPendingTokens;
        uint256 liquidityPendingTokens;
        /// @notice One entry per configured asset, in index order. Empty when `isDividendToken` is false.
        AssetState[] assets;
    }

    /// @notice One ERC20-quote leg's buffers on the direct venue.
    struct QuoteLeg {
        /// @notice False when the token does not carry this quote (or is not a V4 direct-venue token);
        ///         the keeper drops the leg for this run, exactly as a failed multicall entry did.
        bool ok;
        uint256 burnPending;
        uint256 liquidityPending;
        uint128[MAX_ASSETS] dividendPending;
    }

    /// @notice The whole read half of a keeper pass, for many tokens, in one call.
    /// @param tokens The tokens to inspect. Unknown, non-Realm or wrong-generation addresses come back
    ///        as zeroed rows rather than reverting the batch.
    /// @return states One row per input token, positionally.
    function keeperState(address[] calldata tokens) external view returns (TokenState[] memory states) {
        states = new TokenState[](tokens.length);
        for (uint256 t = 0; t < tokens.length; ++t) {
            states[t] = _tokenState(tokens[t]);
        }
    }

    /// @notice The holders of `token` worth pushing asset `assetIndex` to: those whose accrual is
    ///         non-zero AND at least `floorBps` of what that asset still owes.
    /// @dev Collapses the keeper's per-holder `previewDividend` multicall (up to several hundred
    ///      entries) into one call that hands back a batch ready to send. The floor is a SHARE of
    ///      `owed` rather than a wei amount so it scales itself across payout assets and decimals.
    ///      Holders under it are not forfeiting anything: they keep accruing and can always self-claim.
    /// @param floorBps Share of `owed`, in bps, a holder must have accrued. 0 keeps everyone non-zero.
    /// @return payable_ The qualifying subset, in the order given.
    function payableHolders(address token, uint8 assetIndex, address[] calldata holders, uint256 floorBps)
        external
        view
        returns (address[] memory payable_)
    {
        // Probed ONCE for the whole list rather than per holder: 600 holders must not mean 600 reverted
        // calls before the lens works out which generation it is talking to.
        (bool multiAsset,) = _word(token, abi.encodeCall(IDividendTokenMulti.dividendAssetCount, ()));
        uint256 floor;
        {
            (bool haveOwed, uint256 owed) = multiAsset
                ? _assetOwed(token, assetIndex)
                : _word(token, abi.encodeCall(IDividendTokenLegacy.dividendsOwed, ()));
            if (!haveOwed || owed == 0) return new address[](0);
            floor = (owed * floorBps) / 10_000;
        }

        address[] memory hits = new address[](holders.length);
        uint256 n;
        for (uint256 i = 0; i < holders.length; ++i) {
            // Both conditions matter: `floorBps == 0` makes the floor 0, and a zero accrual must still
            // be dropped — pushing to it would spend gas paying nothing.
            uint256 accrued = _accrued(token, multiAsset, assetIndex, holders[i]);
            if (accrued > 0 && accrued >= floor) hits[n++] = holders[i];
        }

        payable_ = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            payable_[i] = hits[i];
        }
    }

    /// @notice The ERC20-quote legs' buffers, batched across tokens. `tokens` and `quotes` are PARALLEL:
    ///         entry `i` is the pair `(tokens[i], quotes[i])`, so one call covers every leg of a run.
    /// @dev Native is not a quote leg — it is the machine `keeperState` already reports. Passing
    ///      `address(0)` here is meaningless and comes back `ok: false`.
    function quoteLegs(address[] calldata tokens, address[] calldata quotes)
        external
        view
        returns (QuoteLeg[] memory legs)
    {
        require(tokens.length == quotes.length, LengthMismatch());
        legs = new QuoteLeg[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            (bool okBuf, bytes memory buf) =
                tokens[i].staticcall(abi.encodeCall(IDividendTokenCommon.quoteBufferOf, (quotes[i])));
            (bool okDiv, bytes memory div) =
                tokens[i].staticcall(abi.encodeCall(IDividendTokenCommon.quoteDividendPending, (quotes[i])));
            if (!okBuf || buf.length < 128 || !okDiv || div.length < 32 * MAX_ASSETS) continue;
            (uint256 burnPending, uint256 liquidityPending,,) = abi.decode(buf, (uint256, uint256, uint48, uint48));
            legs[i] = QuoteLeg({
                ok: true,
                burnPending: burnPending,
                liquidityPending: liquidityPending,
                // `abi.decode` wants a literal length, so this is the one place `MAX_ASSETS` cannot be
                // used. The `div.length` guard above is what actually checks the two agree.
                dividendPending: abi.decode(div, (uint128[3]))
            });
        }
    }

    error LengthMismatch();

    /// @dev One token's whole row. Venue and generation are inferred from WHICH getters answer, never
    ///      from an address list, so a token deployed after this lens is read correctly too.
    function _tokenState(address token) private view returns (TokenState memory s) {
        (s.isDividendToken,) = _word(token, abi.encodeCall(IDividendTokenLegacy.dividendToken, ()));
        if (!s.isDividendToken) return s;

        uint256 count;
        (s.multiAsset, count) = _word(token, abi.encodeCall(IDividendTokenMulti.dividendAssetCount, ()));
        // A legacy token has exactly one asset and no count to read. A current-generation count above
        // the cap cannot happen, but clamping keeps a garbage answer from sizing the loop below.
        s.assetCount = uint8(s.multiAsset ? (count > MAX_ASSETS ? MAX_ASSETS : count) : 1);

        (, s.dividendThreshold) = _word(token, abi.encodeCall(IDividendTokenCommon.DIVIDEND_THRESHOLD, ()));
        (, s.maxPerConversion) = _word(token, abi.encodeCall(IDividendTokenCommon.MAX_DIVIDEND_PER_CONVERSION, ()));
        (, uint256 registry) = _word(token, abi.encodeCall(IDividendTokenCommon.DIVIDEND_SWAP_REGISTRY, ()));
        // casting to 'uint160' is safe because the word came back from an `address` getter; a wider
        // value means the callee is not what it claims, and truncating it to a junk address is exactly
        // as useful to the keeper as reverting the whole batch would be harmful.
        // forge-lint: disable-next-line(unsafe-typecast)
        s.swapRegistry = address(uint160(registry));

        (, s.swapThreshold) = _word(token, abi.encodeCall(IDividendTokenCommon.SWAP_THRESHOLD, ()));
        (, s.dividendPendingTokens) = _word(token, abi.encodeCall(IDividendTokenCommon.dividendPendingTokens, ()));
        (s.isV2, s.liquidityPendingTokens) =
            _word(token, abi.encodeCall(IDividendTokenCommon.liquidityPendingTokens, ()));
        (s.isV4, s.burnPendingEth) = _word(token, abi.encodeCall(IDividendTokenCommon.burnPendingEth, ()));
        (, s.liquidityPendingEth) = _word(token, abi.encodeCall(IDividendTokenCommon.liquidityPendingEth, ()));

        s.assets = s.multiAsset ? _multiAssets(token, s.assetCount) : _legacyAsset(token);
    }

    /// @dev Current generation: one `dividendAssets(i)` per configured asset, plus its staleness flag.
    ///      The struct is decoded through the REAL `DivAsset` type rather than by field position, so a
    ///      layout change is a compile error here instead of a silent misread at runtime.
    function _multiAssets(address token, uint8 count) private view returns (AssetState[] memory assets) {
        assets = new AssetState[](count);
        for (uint256 i = 0; i < count; ++i) {
            (bool ok, bytes memory out) = token.staticcall(abi.encodeCall(IDividendTokenMulti.dividendAssets, (i)));
            if (!ok || out.length == 0) continue;
            DividendDistribution.DivAsset memory a = abi.decode(out, (DividendDistribution.DivAsset));
            (, uint256 stale) = _word(token, abi.encodeCall(IDividendTokenMulti.dividendsStale, (i)));
            assets[i] = AssetState({
                asset: a.token,
                owed: a.owed,
                pendingNative: a.pendingNative,
                lastDistribution: a.lastDistribution,
                stale: stale != 0
            });
        }
    }

    /// @dev Legacy generation: its one asset's state, from the un-indexed getters that are all it has.
    function _legacyAsset(address token) private view returns (AssetState[] memory assets) {
        assets = new AssetState[](1);
        (, uint256 asset) = _word(token, abi.encodeCall(IDividendTokenLegacy.dividendToken, ()));
        (, uint256 owed) = _word(token, abi.encodeCall(IDividendTokenLegacy.dividendsOwed, ()));
        (, uint256 pending) = _word(token, abi.encodeCall(IDividendTokenLegacy.pendingNative, ()));
        (, uint256 stale) = _word(token, abi.encodeCall(IDividendTokenLegacy.dividendsStale, ()));
        // ponytail: `lastDistribution` is left 0 on this branch. The legacy activation marker is
        // `dividendPeriodFinish()`, which means something else entirely; the keeper reads it itself.
        assets[0] = AssetState({
            // casting to 'uint160' is safe because `dividendToken()` returns an address; see the note
            // on `swapRegistry` above for why a malformed answer is truncated rather than rejected.
            // forge-lint: disable-next-line(unsafe-typecast)
            asset: address(uint160(asset)),
            owed: owed,
            pendingNative: pending,
            lastDistribution: 0,
            stale: stale != 0
        });
    }

    /// @dev One holder's accrual on one asset, through whichever generation's entry point applies.
    ///      A failed read is 0, i.e. "not worth pushing to", which is the safe direction: the holder
    ///      keeps the accrual and can self-claim.
    function _accrued(address token, bool multiAsset, uint8 i, address holder) private view returns (uint256) {
        bytes memory data = multiAsset
            ? abi.encodeCall(IDividendTokenMulti.previewDividend, (holder, i))
            : abi.encodeCall(IDividendTokenLegacy.previewDividend, (holder));
        (bool ok, uint256 accrued) = _word(token, data);
        return ok ? accrued : 0;
    }

    /// @dev `owed` for one asset of a current-generation token, without the rest of the struct.
    function _assetOwed(address token, uint8 i) private view returns (bool ok, uint256 owed) {
        bytes memory out;
        (ok, out) = token.staticcall(abi.encodeCall(IDividendTokenMulti.dividendAssets, (i)));
        if (!ok || out.length == 0) return (false, 0);
        return (true, abi.decode(out, (DividendDistribution.DivAsset)).owed);
    }

    /// @dev A single-word `view` read whose failure is a RESULT, not a revert.
    /// @dev The length check is what makes this safe against an address with no code: a `staticcall`
    ///      to one succeeds with empty returndata, and decoding that would either revert or invent a
    ///      value. Anything that does not answer exactly one word is "did not answer".
    function _word(address token, bytes memory data) private view returns (bool ok, uint256 value) {
        bytes memory out;
        (ok, out) = token.staticcall(data);
        if (!ok || out.length != 32) return (false, 0);
        return (true, abi.decode(out, (uint256)));
    }
}
