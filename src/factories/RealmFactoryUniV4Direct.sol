// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";

import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";

/// @notice The slice of `RealmDirectGraduatorUniV4` this factory drives. Kept as an interface rather
///         than the concrete type so the venue and the factory stay separately replaceable.
interface IRealmDirectGraduator {
    function prepare(address quote, int24 launchTick) external;
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
/// @dev ABI note: `createToken` carries its FINAL shape from the first deploy, including the fields the
///      later rollout phases activate — a `pairs` array (one entry today, up to `MAX_PAIRS` later), an
///      ERC20 `quote` per pair (native only today) and a `route` for the dev-buy zap (empty today).
///      Anything not yet supported is REJECTED rather than ignored, so a caller can never believe a
///      field took effect when it did not, and the signature never has to change to turn one on.
contract RealmFactoryUniV4Direct is RealmFactoryAbstract {
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
    /// @param quote The currency the token trades against. `address(0)` is native, the only value
    ///        supported today; ERC20 quotes are rejected until the money path is keyed by quote.
    /// @param weightBps Share of the circulating supply seeded into THIS pool, in bps. Must be 10,000
    ///        while a launch has exactly one pair; carried from the start so the multi-pair rollout adds
    ///        no ABI break.
    /// @param launchTick Opening price as QUOTE PER COIN (`price = 1.0001^launchTick`) — higher is
    ///        always a more expensive coin, whichever way the pair happens to sort. Must be a multiple
    ///        of the pool's tick spacing and strictly inside the usable band. VALIDATED, never rounded.
    struct DirectPair {
        address quote;
        uint16 weightBps;
        int24 launchTick;
    }

    /// @notice The creator's own first buy, settled inside the launch transaction against `msg.value`.
    ///         Pass an all-zero struct (and no value) for none.
    /// @param pairIndex Which of `pairs` the buy executes on. The buy runs against ONE pool, the one the
    ///        creator picks — splitting it would just be several worse-priced buys.
    /// @param route V4 hops taking native ETH to the pair's quote before the buy itself. Empty for a
    ///        native pair, where there is nothing to convert; rejected as non-empty until ERC20 quotes
    ///        are supported.
    /// @param minQuoteOut Slippage floor for that conversion, in the quote's own decimals. The buy leg
    ///        itself needs none: the pool did not exist before this transaction and nobody else can have
    ///        traded it, so its output is a pure function of the launch tick and the supply seeded.
    /// @param recipients How the tokens bought are split, in bps summing to 10,000. Validated exactly as
    ///        the curve venue's deploy-buy shares are, and paid out through the same `BuyOnDeploy` event.
    struct DevBuy {
        uint8 pairIndex;
        PoolKey[] route;
        uint256 minQuoteOut;
        SupplyShare[] recipients;
    }

    /// @notice Max pools one token may launch into. One today; the cap is what the `pairs` array is
    ///         validated against once the money path can key its buffers by quote.
    uint256 public constant MAX_PAIRS = 3;

    /// @notice Pools a launch may open TODAY. Raised to `MAX_PAIRS` when the multi-pair phase lands.
    uint256 public constant SUPPORTED_PAIRS = 1;

    error InvalidLpFeeBps();
    /// @notice Thrown when `pairs` is empty, longer than `SUPPORTED_PAIRS`, carries a weight other than
    ///         the full 10,000, or names the same quote twice.
    error InvalidPairs();
    /// @notice Thrown when a pair names an ERC20 quote. Native only until the token's burn / liquidity /
    ///         dividend buffers are keyed by quote — a token whose earnings arrive in an asset it cannot
    ///         account for would silently strand them.
    error QuoteNotSupported();
    /// @notice Thrown when the dev buy names a pair that does not exist, carries a conversion route
    ///         while no route is needed, or sets a floor for a conversion that will not happen.
    error InvalidDevBuy();

    constructor(TokenImpls memory impls, address graduator, address masterFeeHandler, address creatorVaultFactory)
        // No launchpad: this venue has no pre-graduation phase at all. The zero propagates into every
        // token's `launchpad`, which is what makes `RealmToken` mint to the graduator instead — and
        // what keeps the launchpad's infinite, unspendable allowance over every holder out of here.
        RealmFactoryAbstract(address(0), impls, graduator, masterFeeHandler, creatorVaultFactory)
    {}

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Deploys a Realm token straight onto a Uniswap V4 pool and opens it for trading, all in
    ///         this call. In order: the token is cloned and initialized (which creates the pool at
    ///         `pairs[0].launchTick`), the creator vaults are funded, the fee split is registered, the
    ///         graduator seeds the remaining supply as a single-sided band, and `msg.value` — if any —
    ///         buys the first tokens and is split across `devBuy.recipients`.
    /// @dev Event order, which indexers depend on: `TokenCreated` → the token's own init events
    ///      (`PairInitialized`, `LaunchpadFeesInitialized`, `RealmTaxableTokenInitialized`,
    ///      `SniperProtectionInitialized`) → `CreatorVaultsCreated` → `SharesUpdated` → `Graduated` →
    ///      `PoolSeeded` → the dev buy's own swap events → `TokenGraduated` → `BuyOnDeploy` →
    ///      `LpFeeBpsSet` → `TokenReferral`.
    /// @param referral Relayer that forwarded the creation, or `address(0)`. Emitted as an off-chain
    ///        signal only; nothing on-chain pays it.
    function createToken(
        DirectTokenSetup calldata setup,
        DirectPair[] calldata pairs,
        TaxConfigs calldata taxConfigs,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults,
        DevBuy calldata devBuy,
        address referral
    ) external payable returns (address token) {
        _validateDirectInputs(setup, pairs, devBuy);
        _validateInputs(setup.name, setup.symbol, setup.feeShares, devBuy.recipients);
        _validateAntiSniperConfig(antiSniperConfigs);
        _validateTaxConfig(taxConfigs);
        _validateTotalFee(setup.lpFeeBps, taxConfigs);

        token = _launch(setup, pairs[0], taxConfigs, antiSniperConfigs, creatorVaults, devBuy.recipients);

        emit LpFeeBpsSet(token, setup.lpFeeBps);
        if (referral != address(0)) emit TokenReferral(token, referral);
    }

    /// @notice Returns which token implementation `createToken(...)` would clone for the given inputs,
    ///         so a frontend can compute the initcode hash before mining a `0xeeaa` salt.
    /// @dev Mirrors the dispatch-relevant inputs minus the identity fields, exactly as the unified
    ///      factory's does. Today only `taxCfg` participates; `antiSniperCfg` is accepted so the ABI
    ///      stays stable if that ever changes.
    /// @dev The salt is namespaced by the CALLER (`keccak256(msg.sender, salt)`), so a frontend mining
    ///      an address must apply the same derivation with the account that will send `createToken`.
    function previewTokenImplementation(TaxConfigs calldata taxCfg, AntiSniperConfigs calldata antiSniperCfg)
        external
        view
        returns (address)
    {
        _validateAntiSniperConfig(antiSniperCfg);
        _validateTaxConfig(taxCfg);
        return _previewTokenImplementation(taxCfg, antiSniperCfg);
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev Creation body, split out of `createToken` purely to keep its stack shallow enough to compile
    ///      without `via_ir`.
    function _launch(
        DirectTokenSetup calldata setup,
        DirectPair calldata pair,
        TaxConfigs calldata taxConfigs,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults,
        SupplyShare[] calldata devBuyRecipients
    ) private returns (address token) {
        (, uint256 vaultAllocation) = _validateCreatorVaults(creatorVaults);

        // Stages the launch price for the `initialize` the token is about to make on the graduator from
        // inside its own initializer — the one call in the flow that cannot take it as an argument.
        // Transient, so it cannot outlive this transaction. See `RealmDirectGraduatorUniV4`.
        IRealmDirectGraduator(address(GRADUATOR)).prepare(pair.quote, pair.launchTick);

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

        // Vaults BEFORE the seed, as on the curve venue and for the same reason: `vaultAllocation` was
        // minted to this factory and it must end the call holding none of it.
        if (vaultAllocation > 0) _deployAndFundVaults(token, creatorVaults, vaultAllocation);
        IRealmToken(token).registerFees(setup.feeShares);

        // Everything not locked in a vault was minted to the graduator, which now puts all of it in the
        // pool and settles the dev buy. Read rather than computed so a future mint-target change cannot
        // leave this seeding an amount the graduator does not hold.
        GRADUATOR.graduateToken{value: msg.value}(token, IERC20(token).balanceOf(address(GRADUATOR)));

        // The graduator hands the dev buy back here; the split and its event are the curve venue's.
        if (msg.value > 0) {
            _distributeDeployBuy(token, devBuyRecipients, IERC20(token).balanceOf(address(this)));
        }
    }

    /// @dev Venue-specific validation: the V4 fee tier, the pair set, and the dev buy's consistency with
    ///      it. Everything not yet supported is rejected explicitly — see the ABI note on the contract.
    function _validateDirectInputs(DirectTokenSetup calldata setup, DirectPair[] calldata pairs, DevBuy calldata devBuy)
        internal
        pure
    {
        require(setup.lpFeeBps == 100 || setup.lpFeeBps == 50, InvalidLpFeeBps());
        require(pairs.length > 0 && pairs.length <= SUPPORTED_PAIRS, InvalidPairs());
        require(pairs[0].weightBps == BASIS_POINTS, InvalidPairs());
        require(pairs[0].quote == address(0), QuoteNotSupported());
        require(devBuy.pairIndex < pairs.length, InvalidDevBuy());
        // A native pair needs no conversion, so a route or a floor for one is a caller who believes
        // something is happening that is not.
        require(devBuy.route.length == 0 && devBuy.minQuoteOut == 0, InvalidDevBuy());
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
