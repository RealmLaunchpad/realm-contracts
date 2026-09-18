// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";

import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {
    IRealmTaxableToken,
    TaxConfigs,
    TaxConfigsWithDirectAllocation,
    EarningsAllocationMultiConfig
} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {RealmLaunchPricing} from "src/libraries/RealmLaunchPricing.sol";

/// @notice The slice of `RealmDirectGraduatorUniV4` this factory drives. Kept as an interface rather
///         than the concrete type so the venue and the factory stay separately replaceable.
interface IRealmDirectGraduator {
    function prepare(address quote, int24 launchTick, uint16 weightBps) external;
    function initializePool(address token, address quote, int24 launchTick) external;
    function seedPool(address token, address quote, int24 launchTick, uint256 tokenAmount, uint16 weightBps)
        external
        returns (uint128 liquidity);
    function devBuy(address token, address quote) external payable;
    function burnSeedDust(address token) external;
}

/// @title RealmFactoryUniV4Direct
/// @notice Factory for the DIRECT-launch venue: a Realm token that goes straight to a Uniswap V4 pool
///         at a price its creator picks, with no bonding curve in between. One transaction creates the
///         token, creates the pool, seeds the whole circulating supply into it as a single-sided band,
///         and settles the creator's own first buy.
///
/// @dev Extends `RealmFactoryAbstract` — NOT `RealmFactoryCurveAbstract`. Everything the curve layer
///      holds (21 curve immutables, `_resolveBondingCurve`, `LAUNCHPAD.launchToken()`, the curve deploy
///      buy and its quotes) is meaningless here, and inheriting it would leave this factory carrying a
///      launchpad it must never call. What it does inherit is everything that makes a token a Realm
///      token: the validation rules, the salt-namespaced `0xeeaa` clone, the tax/anti-sniper dispatch,
///      the creator vaults, the fee registration and the shared events.
///
/// @dev The token this deploys is an ORDINARY graduated Realm token. `LAUNCHPAD` is `address(0)` — so
///      `TokenCreated.launchpad` being zero is the on-chain marker that a token came from this venue —
///      and the supply is minted to the graduator instead (`RealmToken`'s mint-target fallback).
///
/// @dev ABI note: `createToken` carries its FINAL shape from the first deploy, including a `route` and a
///      `minQuoteOut` for a dev-buy zap that is not supported yet: both must be empty/zero. Anything not
///      supported is REJECTED rather than ignored, so a caller can never believe a field took effect
///      when it did not, and the signature never has to change to turn one on.
contract RealmFactoryUniV4Direct is RealmFactoryAbstract {
    using SafeERC20 for IERC20;

    /// @notice Token-identity bundle for `createToken`. Mirrors `TokenSetupTiered` minus the liquidity
    ///         tier — there is no curve here, so there is no tier — plus the two V4 knobs the unified
    ///         factory carries in its own `UniV4Configs`.
    /// @dev `lpFeeBps` is the per-swap LP fee the hook charges post-graduation, stored on the token and
    ///      read back through `getSwapFees`. Only `100` (1%) and `50` (0.5%) are accepted.
    struct DirectTokenSetup {
        string name;
        string symbol;
        bytes32 salt;
        FeeShare[] feeShares;
        bool renounceOwnership;
        uint16 lpFeeBps;
    }

    /// @notice One pool to launch the token into.
    /// @param quote The currency the token trades against: `address(0)` for native, or an ERC20 (see
    ///        `_validateQuote`).
    /// @param weightBps Share of the circulating supply seeded into THIS pool, in bps. Non-zero; the
    ///        weights of all pairs sum to 10,000.
    /// @param launchTick Opening price as QUOTE PER COIN (`price = 1.0001^launchTick`) — higher is
    ///        always a more expensive coin, whichever way the pair happens to sort. Must be a multiple
    ///        of the pool's tick spacing, strictly inside the usable band, and imply a market cap inside
    ///        the launch bounds (`LaunchPriceOutOfBounds`). VALIDATED, never rounded.
    struct DirectPair {
        address quote;
        uint16 weightBps;
        int24 launchTick;
    }

    /// @notice The creator's own first buy, settled inside the launch transaction against `msg.value`.
    ///         Pass an all-zero struct (and no value) for none.
    /// @param pairIndex Which of `pairs` the buy executes on. The buy runs against ONE pool, the one the
    ///        creator picks — splitting it would just be several worse-priced buys.
    /// @param route V4 hops taking native ETH to the pair's quote before the buy itself. Not supported
    ///        yet: must be empty — a creator buying on an ERC20 pair brings that currency instead.
    /// @param minQuoteOut Slippage floor for that conversion, in the quote's own decimals. The buy leg
    ///        itself needs none: the pool did not exist before this transaction and nobody else can have
    ///        traded it, so its output is a pure function of the launch tick and the supply seeded.
    /// @param quoteAmount For a buy on an ERC20-quoted pair, how much of that quote to spend. PULLED
    ///        from the caller, who must have approved this factory. Zero on a native pair, where the buy
    ///        is `msg.value` instead — a creator buying on an ERC20 pair brings that currency rather
    ///        than having the launch convert for them, which needs no route, no oracle and no floor.
    /// @param recipients How the tokens bought are split, in bps summing to 10,000. Validated exactly as
    ///        the curve venue's deploy-buy shares are, and paid out through the same `BuyOnDeploy` event.
    struct DevBuy {
        uint8 pairIndex;
        PoolKey[] route;
        uint256 minQuoteOut;
        uint256 quoteAmount;
        SupplyShare[] recipients;
    }

    /// @notice Max pools one token may launch into, any mix of native and ERC20 quotes. One less than
    ///         `RealmToken.MAX_QUOTES`, whose index 0 is native on every token, so three ERC20 pairs fit
    ///         with no native pair at all.
    uint256 public constant MAX_PAIRS = 3;

    /// @notice Lowest opening market cap an ERC20 pair may launch at: 0.001 WHOLE units of its quote,
    ///         scaled by 1e18. Whole units, so the bound means the same for a 6-, 18- or 27-decimal quote.
    ///         Native pairs are held to `MIN_NATIVE_LAUNCH_MARKET_CAP_X18` instead.
    /// @dev With `MAX_LAUNCH_MARKET_CAP_X18` it admits $1k-$100B launches for quotes worth anywhere from
    ///      ~$1e6 down to ~$1e-9 per unit, and rejects the prices only a mistake produces: a decimals slip
    ///      (1e12x on a 6-decimal quote) or a tick near the ends of the range. Only a typo guard: an
    ///      ERC20's value is unknown on-chain, so no economic bound fits every quote.
    uint256 public constant MIN_LAUNCH_MARKET_CAP_X18 = 1e15;

    /// @notice Highest opening market cap an ERC20 pair may launch at: 1e20 WHOLE units of its quote,
    ///         scaled by 1e18. See `MIN_LAUNCH_MARKET_CAP_X18`.
    /// @dev Uniswap's per-tick liquidity ceiling can bind first on a quote with more than ~22 decimals:
    ///      that launch reverts `SeedLiquidityOutOfRange` in the graduator.
    uint256 public constant MAX_LAUNCH_MARKET_CAP_X18 = 1e38;

    /// @notice Lowest opening market cap a NATIVE pair may launch at: 1 ETH.
    /// @dev The seed is single-sided, so the opening market cap is the pool's virtual quote reserve: the
    ///      price 4x's after buys of about that much. A tiny one hands the dev buy most of the supply for
    ///      almost nothing. 1 ETH sits just under the THIN curve's own opening (~1.1 ETH) and ~6x under
    ///      its 6.125 ETH graduation, so no direct launch sells cheaper than the curve venue's first buy.
    ///      Native is ETH on every chain this venue deploys to; one with another native needs its own.
    uint256 public constant MIN_NATIVE_LAUNCH_MARKET_CAP_X18 = 1 ether;

    /// @notice Highest opening market cap a NATIVE pair may launch at: 250 ETH, ~10x the THICK tier's
    ///         24.5 ETH graduation market cap.
    /// @dev Harmless on-chain (nobody has to buy), but aggregators display it as a market cap from block
    ///      zero, with no volume behind it. See `MIN_NATIVE_LAUNCH_MARKET_CAP_X18`.
    uint256 public constant MAX_NATIVE_LAUNCH_MARKET_CAP_X18 = 250 ether;

    /// @notice The chain's wrapped native token, which a pair may NOT be quoted against. See
    ///         `_validateQuote`.
    address public immutable WRAPPED_NATIVE;

    error InvalidLpFeeBps();
    /// @notice Thrown when `pairs` is empty, longer than `MAX_PAIRS`, carries a zero weight or weights
    ///         that do not sum to 10,000, or names the same quote twice.
    error InvalidPairs();
    /// @notice Thrown when a pair names a quote the venue refuses: the chain's wrapped native (use the
    ///         native pair instead — two pools for the same value would split the token's own liquidity
    ///         against itself), or something with no `decimals()` (or more than 36).
    error QuoteNotSupported();
    /// @notice Thrown when the dev buy names a pair that does not exist, carries a conversion route
    ///         while no route is needed, or sets a floor for a conversion that will not happen.
    error InvalidDevBuy();
    /// @notice `quoteRoutes` names more entries than there are pairs, a route for a native pair, or a
    ///         route while the allocation has no dividends share.
    error InvalidQuoteRoutes();
    /// @notice A pair's `launchTick` implies an opening market cap outside
    ///         [`MIN_LAUNCH_MARKET_CAP_X18`, `MAX_LAUNCH_MARKET_CAP_X18`] in whole units of its quote, or
    ///         outside [`MIN_NATIVE_LAUNCH_MARKET_CAP_X18`, `MAX_NATIVE_LAUNCH_MARKET_CAP_X18`] on a native pair.
    error LaunchPriceOutOfBounds();

    constructor(
        TokenImpls memory impls,
        address graduator,
        address masterFeeHandler,
        address creatorVaultFactory,
        address wrappedNative
    )
        // No launchpad: this venue has no pre-graduation phase at all. The zero propagates into every
        // token's `launchpad`, which is what makes `RealmToken` mint to the graduator instead — and
        // what keeps the launchpad's infinite, unspendable allowance over every holder out of here.
        RealmFactoryAbstract(address(0), impls, graduator, masterFeeHandler, creatorVaultFactory)
    {
        WRAPPED_NATIVE = wrappedNative;
    }

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Deploys a Realm token straight onto Uniswap V4 pools and opens it for trading, all in this
    ///         call. In order: the token is cloned and initialized (which creates the pool at
    ///         `pairs[0].launchTick`), its extra quotes are registered, the creator vaults are funded, the
    ///         fee split is registered, the earnings allocation is configured, the graduator opens and
    ///         seeds every pool, and the creator's dev buy — if any — is settled and split across
    ///         `devBuy.recipients`. `taxAllocationConfigs` carries the tax, the optional launch-tax decay,
    ///         the earnings-allocation split (burn / dividends / liquidity bps, the payout assets and their
    ///         routes) and the routes of the token's ERC20 quotes. Any tax config is accepted, zero
    ///         included: the creator's LP-fee share is a permanent earnings stream on this venue, so a
    ///         token with an allocation is cloned from the taxable implementation whatever its tax, and a
    ///         token with neither tax nor allocation from the base one (see `previewTokenImplementation`).
    /// @dev The allocation is configured BEFORE the pools are seeded, so `markGraduated()` — which the
    ///      first seed triggers — activates the dividend machine the normal way. Configured after, the
    ///      token would graduate with `hasDividends` unset and only start accruing on its first earnings.
    /// @dev Event order, which indexers depend on (full detail in `docs/events-per-entry-point.md` §1.3):
    ///      `TokenCreated` → the token's own init events (`PairInitialized`, `PoolIdRegistered`,
    ///      `LaunchpadFeesInitialized`, `RealmTaxableTokenInitialized`, `SniperProtectionInitialized`) →
    ///      `QuotesRegistered` → `CreatorVaultsCreated` → `SharesUpdated` → the allocation's events
    ///      (`EarningsAllocationInitialized`, `DividendAssetInitialized` per payout asset,
    ///      `DividendsInitialized`, the registry's `DividendRouteRegistered` per route) →
    ///      `PoolIdRegistered` per extra pool → `Graduated` → `PoolSeeded` (first pool) →
    ///      `TokenGraduated` → `PoolSeeded` per extra pool → the dev buy's own swap events → the
    ///      seed-remainder burn → `BuyOnDeploy` → `LpFeeBpsSet` → `TokenReferral`.
    /// @param referral Relayer that forwarded the creation, or `address(0)`. Emitted as an off-chain
    ///        signal only; nothing on-chain pays it.
    function createToken(
        DirectTokenSetup calldata setup,
        DirectPair[] calldata pairs,
        TaxConfigsWithDirectAllocation calldata taxAllocationConfigs,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults,
        DevBuy calldata devBuy,
        address referral
    ) external payable returns (address token) {
        _validateDirectInputs(setup, pairs, devBuy);
        _validateInputs(
            setup.name, setup.symbol, setup.feeShares, devBuy.recipients, msg.value > 0 ? msg.value : devBuy.quoteAmount
        );
        _validateAntiSniperConfig(antiSniperConfigs);
        bool hasAllocation = _validateAllocation(taxAllocationConfigs, pairs);

        token =
            _createWithAllocation(setup, pairs, taxAllocationConfigs, antiSniperConfigs, creatorVaults, hasAllocation);
        _open(token, pairs, devBuy);

        emit LpFeeBpsSet(token, setup.lpFeeBps);
        if (referral != address(0)) emit TokenReferral(token, referral);
    }

    /// @notice Returns which token implementation `createToken` would clone for the same arguments, so a
    ///         frontend can compute the initcode hash before mining a `0xeeaa` salt. Takes EXACTLY
    ///         `createToken`'s arguments, so the ABI stays stable whichever inputs dispatch reads later;
    ///         today only the tax config and whether any allocation bucket is set matter.
    /// @dev The salt is namespaced by the CALLER (`keccak256(msg.sender, salt)`), so a frontend mining
    ///      an address must apply the same derivation with the account that will send `createToken`.
    function previewTokenImplementation(
        DirectTokenSetup calldata, /* setup */
        DirectPair[] calldata, /* pairs */
        TaxConfigsWithDirectAllocation calldata taxAllocationConfigs,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata, /* creatorVaults */
        DevBuy calldata, /* devBuy */
        address /* referral */
    ) external view returns (address) {
        _validateAntiSniperConfig(antiSniperConfigs);
        TaxConfigs memory cfg = _toTaxConfigs(taxAllocationConfigs);
        _validateTaxConfig(cfg);
        EarningsAllocationMultiConfig calldata alloc = taxAllocationConfigs.earningsAllocation;
        return _previewTokenImplementation(cfg, _hasAllocation(alloc.burnBps, alloc.dividendsBps, alloc.liquidityBps));
    }

    /// @notice What a `launchTick` actually means: the opening price of one whole coin in whole units
    ///         of `quote`, and the market cap that implies across the fixed supply — both scaled by 1e18.
    /// @dev The reader that stops a creator launching at ten times the price they meant. A tick is
    ///      `1.0001^n` on RAW units, so the answer depends on the quote's decimals, which is exactly the
    ///      conversion that is easy to get wrong by hand. Pure, and callable before the token exists.
    /// @param quoteDecimals Decimals of the pair's quote currency; pass 18 for the native pair.
    function previewLaunchPrice(int24 launchTick, uint8 quoteDecimals)
        external
        pure
        returns (uint256 priceX18, uint256 marketCapX18)
    {
        return RealmLaunchPricing.priceAtTick(launchTick, quoteDecimals);
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev The allocation overload's creation body, split out of `createToken` to keep its stack
    ///      shallow enough to compile without `via_ir`: the token, then its allocation, in that order and
    ///      before `_open` seeds the pools (see the overload's docstring for why).
    function _createWithAllocation(
        DirectTokenSetup calldata setup,
        DirectPair[] calldata pairs,
        TaxConfigsWithDirectAllocation calldata c,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults,
        bool hasAllocation
    ) private returns (address token) {
        TaxConfigs memory taxConfigs = _toTaxConfigs(c);
        _validateTaxConfig(taxConfigs);
        _validateTotalFee(setup.lpFeeBps, taxConfigs);
        _allocationPending = hasAllocation;
        token = _launch(setup, pairs, taxConfigs, antiSniperConfigs, creatorVaults);
        if (hasAllocation) _initializeAllocation(token, c, pairs);
    }

    /// @dev Its own frame purely for the stack: seven calldata arguments do not fit beside the launch's.
    function _initializeAllocation(
        address token,
        TaxConfigsWithDirectAllocation calldata c,
        DirectPair[] calldata pairs
    ) private {
        bytes[] memory quoteRoutes = _quoteRoutes(c.quoteRoutes, pairs);
        EarningsAllocationMultiConfig calldata alloc = c.earningsAllocation;
        IRealmTaxableToken(payable(token))
            .initializeEarningsAllocation(
                alloc.burnBps,
                alloc.dividendsBps,
                alloc.liquidityBps,
                alloc.dividendTokens,
                alloc.dividendWeightsBps,
                alloc.dividendRoutes,
                quoteRoutes
            );
    }

    /// @dev Creation body up to the point the token exists and is configured: clone, quotes, vaults,
    ///      fee shares. Split from `_open` so the allocation overload can configure the token in
    ///      between, and out of `createToken` to keep its stack shallow enough to compile without
    ///      `via_ir`.
    function _launch(
        DirectTokenSetup calldata setup,
        DirectPair[] calldata pairs,
        TaxConfigs memory taxConfigs,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults
    ) private returns (address token) {
        (, uint256 vaultAllocation) = _validateCreatorVaults(creatorVaults);

        // Stages the launch price of the FIRST pool for the `initialize` the token is about to make on
        // the graduator from inside its own initializer — the one call in the flow that cannot take it
        // as an argument. Transient, so it cannot outlive this transaction. Every later pool is opened
        // by this factory directly. See `RealmDirectGraduatorUniV4`.
        IRealmDirectGraduator(address(GRADUATOR)).prepare(pairs[0].quote, pairs[0].launchTick, pairs[0].weightBps);

        token = _dispatchAndInitialize(
            setup.name,
            setup.symbol,
            setup.salt,
            setup.renounceOwnership ? address(0) : msg.sender,
            address(GRADUATOR),
            setup.lpFeeBps,
            vaultAllocation,
            taxConfigs,
            antiSniperConfigs
        );

        _registerExtraQuotes(token, pairs);

        // Vaults BEFORE the seed, as on the curve venue and for the same reason: `vaultAllocation` was
        // minted to this factory and it must end the call holding none of it.
        if (vaultAllocation > 0) _deployAndFundVaults(token, creatorVaults, vaultAllocation);
        IRealmToken(token).registerFees(setup.feeShares);
    }

    /// @dev The rest of the launch: seed the pools — which graduates the token — and settle the dev buy.
    function _open(address token, DirectPair[] calldata pairs, DevBuy calldata devBuy) private {
        _seedPools(token, pairs);
        _settleDevBuy(token, pairs[devBuy.pairIndex].quote, devBuy);
    }

    /// @dev The allocation overload's own checks. Returns whether any bucket is configured.
    function _validateAllocation(TaxConfigsWithDirectAllocation calldata c, DirectPair[] calldata pairs)
        private
        pure
        returns (bool hasAllocation)
    {
        EarningsAllocationMultiConfig calldata alloc = c.earningsAllocation;
        hasAllocation = _hasAllocation(alloc.burnBps, alloc.dividendsBps, alloc.liquidityBps);
        // Naming payout assets with a zero share would leave dividends silently OFF, forever: clones
        // are not upgradeable and `initializeEarningsAllocation` only ever runs here, at creation.
        require(alloc.dividendTokens.length == 0 || alloc.dividendsBps != 0, DividendAssetWithoutShare());
        uint256 n = c.quoteRoutes.length;
        require(n <= pairs.length, InvalidQuoteRoutes());
        // A route on a native pair, or with no dividends to convert into, is a caller who believes
        // something is being converted that is not: the token only registers routes for a dividends leg.
        for (uint256 i = 0; i < n; ++i) {
            require(
                c.quoteRoutes[i].length == 0 || (pairs[i].quote != address(0) && alloc.dividendsBps != 0),
                InvalidQuoteRoutes()
            );
        }
    }

    /// @dev Compacts the per-PAIR `quoteRoutes` into the per-ERC20-QUOTE list the token takes: same
    ///      order as `_registerExtraQuotes` registers them, native pairs skipped, missing entries empty.
    function _quoteRoutes(bytes[] calldata routes, DirectPair[] calldata pairs)
        private
        pure
        returns (bytes[] memory out)
    {
        uint256 n = pairs.length;
        out = new bytes[](n);
        uint256 count;
        for (uint256 i = 0; i < n; ++i) {
            if (pairs[i].quote == address(0)) continue;
            if (i < routes.length) out[count] = routes[i];
            ++count;
        }
        assembly ("memory-safe") {
            mstore(out, count)
        }
    }

    /// @dev Tells the token which ERC20 currencies it will earn in, so its buffers and its
    ///      `accrueFees(asset, …)` gate know them. The native quote is already index 0 on every token.
    function _registerExtraQuotes(address token, DirectPair[] calldata pairs) private {
        uint256 n = pairs.length;
        address[] memory extras = new address[](n);
        uint256 count;
        for (uint256 i = 0; i < n; ++i) {
            if (pairs[i].quote != address(0)) {
                extras[count] = pairs[i].quote;
                ++count;
            }
        }
        if (count == 0) return;
        assembly ("memory-safe") {
            mstore(extras, count)
        }
        IRealmToken(token).registerQuotes(extras);
    }

    /// @dev Opens every pool after the first — the token's own initializer opened that one — and seeds
    ///      all of them, splitting the circulating supply by `weightBps`. The LAST pool absorbs the
    ///      rounding remainder, so the graduator ends holding only what no band could take.
    function _seedPools(address token, DirectPair[] calldata pairs) private {
        IRealmDirectGraduator grad = IRealmDirectGraduator(address(GRADUATOR));
        uint256 n = pairs.length;
        for (uint256 i = 1; i < n; ++i) {
            grad.initializePool(token, pairs[i].quote, pairs[i].launchTick);
        }

        // Everything not locked in a vault was minted to the graduator. Read rather than computed so a
        // future mint-target change cannot leave this seeding an amount the graduator does not hold.
        uint256 total = IERC20(token).balanceOf(address(GRADUATOR));
        uint256 seeded;
        for (uint256 i = 0; i < n; ++i) {
            uint256 share = i == n - 1 ? total - seeded : total * pairs[i].weightBps / BASIS_POINTS;
            seeded += share;
            if (i == 0) {
                // The `IRealmGraduator` entry point: it also marks the token graduated, which has to
                // happen before any supply can reach the pool manager.
                GRADUATOR.graduateToken(token, share);
            } else {
                grad.seedPool(token, pairs[i].quote, pairs[i].launchTick, share, pairs[i].weightBps);
            }
        }
    }

    /// @dev Runs the creator's own first buy on the pool they picked, then burns the seed remainder,
    ///      which also closes the launch on the graduator — so `burnSeedDust` is always its last call.
    function _settleDevBuy(address token, address quote, DevBuy calldata devBuy) private {
        IRealmDirectGraduator grad = IRealmDirectGraduator(address(GRADUATOR));
        uint256 spend = quote == address(0) ? msg.value : devBuy.quoteAmount;
        if (spend == 0) {
            grad.burnSeedDust(token);
            return;
        }

        if (quote != address(0)) {
            // Pulled through this factory rather than approved straight to the graduator, so a creator
            // grants an allowance to ONE address and the graduator never needs one of its own.
            IERC20(quote).safeTransferFrom(msg.sender, address(GRADUATOR), spend);
        }
        grad.devBuy{value: msg.value}(token, quote);
        grad.burnSeedDust(token);

        // The graduator hands the dev buy back here; the split and its event are the curve venue's.
        _distributeDeployBuy(token, devBuy.recipients, IERC20(token).balanceOf(address(this)));
    }

    /// @dev Venue-specific validation: the V4 fee tier, the pair set, and the dev buy's consistency
    ///      with it. Everything not yet supported is rejected explicitly — see the ABI note above.
    function _validateDirectInputs(DirectTokenSetup calldata setup, DirectPair[] calldata pairs, DevBuy calldata devBuy)
        internal
        view
    {
        require(setup.lpFeeBps == 100 || setup.lpFeeBps == 50, InvalidLpFeeBps());

        uint256 n = pairs.length;
        require(n > 0 && n <= MAX_PAIRS, InvalidPairs());
        uint256 totalWeight;
        for (uint256 i = 0; i < n; ++i) {
            require(pairs[i].weightBps > 0, InvalidPairs());
            totalWeight += pairs[i].weightBps;
            // Two pools against the same currency would split the token's own liquidity against itself
            // and give it two buffers for one quote.
            for (uint256 j = i + 1; j < n; ++j) {
                require(pairs[i].quote != pairs[j].quote, InvalidPairs());
            }
            if (pairs[i].quote == address(0)) {
                _validateLaunchPrice(
                    pairs[i].launchTick, 18, MIN_NATIVE_LAUNCH_MARKET_CAP_X18, MAX_NATIVE_LAUNCH_MARKET_CAP_X18
                );
            } else {
                _validateLaunchPrice(
                    pairs[i].launchTick,
                    _validateQuote(pairs[i].quote),
                    MIN_LAUNCH_MARKET_CAP_X18,
                    MAX_LAUNCH_MARKET_CAP_X18
                );
            }
        }
        require(totalWeight == BASIS_POINTS, InvalidPairs());

        require(devBuy.pairIndex < n, InvalidDevBuy());
        // The creator brings the pair's own currency; there is nothing here to convert, so a route or a
        // floor for one is a caller who believes something is happening that is not.
        require(devBuy.route.length == 0 && devBuy.minQuoteOut == 0, InvalidDevBuy());
        // Value belongs to a native buy and `quoteAmount` to an ERC20 one; crossing them would leave
        // one of the two sitting in this contract with nobody to return it to.
        bool nativeBuy = pairs[devBuy.pairIndex].quote == address(0);
        require(nativeBuy ? devBuy.quoteAmount == 0 : msg.value == 0, InvalidDevBuy());
    }

    /// @dev What a quote currency has to be for this venue to launch against it. Deliberately thin: the
    ///      creator picks the pair and the market prices it, so this rejects only the shapes that would
    ///      break the token's own accounting rather than judging the asset.
    ///      - It must be a contract with `decimals()`, which is what an integrator needs to display any
    ///        of it and what every downstream quote assumes exists.
    ///      - It must not be the chain's WRAPPED native token: a pool holding wrapped native and a pool
    ///        holding native are the same market, and a token with both would have its own liquidity
    ///        split across two pools for no gain. Creators use the native pair instead.
    /// @dev FEE-ON-TRANSFER QUOTES ARE NOT SUPPORTED. `RealmHookAnyPair.settleFees` forwards the nominal
    ///      amounts it redeemed and the token's `accrueFees` credits its buffers with the nominal amount,
    ///      so a quote that delivers less than it is sent makes fee settlement revert and strands that
    ///      token's fees in the hook. Not rejected here because it cannot usefully be: a transfer fee can
    ///      be switched on after launch, so a creation-time probe proves nothing.
    function _validateQuote(address quote) internal view returns (uint8 dec) {
        require(quote.code.length > 0 && quote != WRAPPED_NATIVE, QuoteNotSupported());
        try IERC20Metadata(quote).decimals() returns (uint8 d) {
            dec = d;
        } catch {
            revert QuoteNotSupported();
        }
        require(dec <= 36, QuoteNotSupported());
    }

    /// @dev Bounds the opening market cap to [`minCapX18`, `maxCapX18`] WHOLE quote units. Compared on
    ///      the per-coin price, which stays inside 256 bits at every tick, rather than on the market cap,
    ///      which does not.
    function _validateLaunchPrice(int24 launchTick, uint8 quoteDecimals, uint256 minCapX18, uint256 maxCapX18)
        internal
        pure
    {
        uint256 priceX18 = RealmLaunchPricing.pricePerCoin(launchTick, quoteDecimals);
        require(
            priceX18 >= minCapX18 / RealmLaunchPricing.WHOLE_SUPPLY
                && priceX18 <= maxCapX18 / RealmLaunchPricing.WHOLE_SUPPLY,
            LaunchPriceOutOfBounds()
        );
    }

    /// @dev No launchpad, so no pre-graduation LP fee. The token still carries the field (every token
    ///      does); it is read only by `getLaunchpadFees`, which nothing calls on a token that never
    ///      trades pre-graduation.
    function _launchpadLpFeeBps(
        address /* graduator */
    )
        internal
        pure
        override
        returns (uint16)
    {
        return 0;
    }

    /// @inheritdoc RealmFactoryAbstract
    /// @dev Same reasoning as `_launchpadLpFeeBps`: there is no pre-graduation fee to split.
    function _launchpadTreasuryShareBps() internal pure override returns (uint16) {
        return 0;
    }
}
