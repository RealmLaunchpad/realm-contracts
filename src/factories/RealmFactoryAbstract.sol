// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmLaunchpad} from "src/interfaces/IRealmLaunchpad.sol";
import {IRealmGraduator} from "src/interfaces/IRealmGraduator.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmCreatorVaultFactory} from "src/interfaces/IRealmCreatorVaultFactory.sol";
import {
    IRealmTaxableToken,
    TaxConfigs,
    TaxConfigsWithMultiAllocation,
    TaxConfigsWithDirectAllocation
} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";

/// @notice Abstract base for EVERY Realm token factory: the parts that do not depend on how the token
///         is brought to market. Input validation, the deterministic clone + vanity-suffix rule, impl
///         dispatch, creator vaults, fee registration and the shared events all live here.
/// @dev    What is deliberately NOT here is the bonding curve. A curve is one venue's answer to "how
///         does supply reach the market", and `RealmFactoryCurveAbstract` is the layer that holds it —
///         the curve immutables, curve resolution, `LAUNCHPAD.launchToken()` and the launchpad deploy
///         buy. `RealmFactoryUniV4Direct` skips that layer entirely: it seeds a pool instead.
/// @dev    UUPS-upgradeable. The implementation contract sets its immutables in the constructor
///         (baked into bytecode) and calls `_disableInitializers()` to prevent direct init.
///         Proxies must call `initialize()` exactly once to claim ownership. Upgrade authorisation
///         lives in `_authorizeUpgrade`.
abstract contract RealmFactoryAbstract is IRealmFactory, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Max configurable tax duration. Capped at 120 years purely to prevent overflow —
    ///         the upper bound is driven by `TaxConfigs.taxDurationSeconds`'s `uint32` packing.
    ///         Any deployer can use any duration up to this cap; no fee-receiver or
    ///         ownership constraints are imposed beyond the standard validation.
    uint256 public constant MAX_TAX_DURATION_SECONDS = 120 * 365 days;

    /// @notice Max COMBINED start rate (bps) for the optional linear launch-tax decay: `buy + sell`.
    ///         Fixed at 20% — higher than the static `MAX_TOTAL_FEE_BPS` (5%) because the decay only
    ///         applies transiently at launch and falls to 0 within `MAX_TAX_DECAY_DURATION_SECONDS`. The
    ///         cap is on the sum, so any split is allowed (e.g. 10%/10%, 5%/15%, 20%/0%). A trade pays
    ///         only one direction and the effective tax is `max(decay, static)`, so the worst-case rate a
    ///         single trade sees at launch is at most this cap; the launchpad's own `MAX_TRADING_FEE_BPS`
    ///         (25%) absorbs it on top of the LP fee.
    uint256 public constant MAX_TAX_DECAY_START_COMBINED_BPS = 2_000;

    /// @notice Max duration (seconds) of the linear launch-tax decay: 20 minutes. The decay rate falls
    ///         from its start value to 0 over at most this window, from the same anchor the static tax uses.
    uint256 public constant MAX_TAX_DECAY_DURATION_SECONDS = 20 minutes;

    /// @notice Launchpad where tokens are registered after creation
    IRealmLaunchpad public immutable LAUNCHPAD;
    /// @notice Graduator contract that handles token graduation to Uniswap
    IRealmGraduator public immutable GRADUATOR;
    /// @notice Master fee handler for all token fee routing
    IRealmMasterFeeHandler public immutable MASTER_FEE_HANDLER;

    /// @notice Token implementation cloned for non-taxable tokens. Anti-sniper protection is a gated
    ///         feature of this same impl (enabled at init from `AntiSniperConfigs`), not a separate impl.
    address public immutable TOKEN_IMPL_BASE;
    /// @notice Token implementation cloned for taxable tokens (static tax and/or launch-tax decay).
    ///         Anti-sniper protection is a gated feature of this same impl, not a separate impl.
    address public immutable TOKEN_IMPL_TAX;

    /// @notice Factory that deploys the per-token creator-vault clones.
    IRealmCreatorVaultFactory public immutable CREATOR_VAULT_FACTORY;

    /// @notice Cap on the aggregate fee a swapper pays (LP fee + tax), in basis points. Fixed at 5%.
    ///         Enforced per call by `_validateTotalFee`. The tax headroom is venue-dependent because
    ///         the LP fee varies: V2 has no LP fee, so tax can reach the full 5%; V4 charges 50 or
    ///         100 bps in LP fees, leaving 450 or 400 bps for tax.
    uint256 public constant MAX_TOTAL_FEE_BPS = 500;

    /// @dev The V4 hooks' `MAX_OVERALL_FEE_BPS`: a swap whose LP fee + active tax exceeds it reverts.
    uint256 internal constant HOOK_MAX_OVERALL_FEE_BPS = 2_000;

    /// @notice Total token supply minted per token. Mirrors `RealmToken.TOTAL_SUPPLY`; used to size
    ///         creator-vault allocations from their bps.
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Max number of creator vaults a single token can have.
    uint256 public constant MAX_CREATOR_VAULTS = 5;

    /// @notice Creator-vault allocation granularity (5% in bps). Each vault must lock a multiple.
    uint256 public constant CREATOR_VAULT_BPS_STEP = 500;

    /// @notice Max total supply lockable across all creator vaults (30% in bps).
    uint256 public constant MAX_CREATOR_VAULT_TOTAL_BPS = 3_000;

    /// @notice Sets up the factory's immutables on the implementation. The implementation itself is
    ///         not meant to be used directly — `_disableInitializers()` locks its proxy storage so
    ///         only proxies pointing to this implementation can be initialized.
    /// @dev    Immutables are read from the implementation's bytecode through delegatecall, so they
    ///         work transparently behind the UUPS proxy. To change any of them, deploy a new impl
    ///         with different constructor args and call `upgradeTo` on the proxy.
    /// @param launchpad Launchpad tokens are registered with. `address(0)` on a venue that has none —
    ///        the direct-launch factory — which is what makes the token's mint target fall back to its
    ///        graduator and keeps the launchpad's infinite allowance out of that venue entirely.
    /// @param creatorVaultFactory Factory that deploys creator-vault clones
    constructor(
        address launchpad,
        TokenImpls memory impls,
        address graduator,
        address masterFeeHandler,
        address creatorVaultFactory
    ) {
        LAUNCHPAD = IRealmLaunchpad(launchpad);
        GRADUATOR = IRealmGraduator(graduator);
        MASTER_FEE_HANDLER = IRealmMasterFeeHandler(masterFeeHandler);
        TOKEN_IMPL_BASE = impls.base;
        TOKEN_IMPL_TAX = impls.tax;
        CREATOR_VAULT_FACTORY = IRealmCreatorVaultFactory(creatorVaultFactory);
        _disableInitializers();
    }

    /// @notice One-shot initializer for the proxy. Sets `msg.sender` as the initial owner.
    /// @dev    Must be called atomically with proxy deployment (via `ERC1967Proxy`'s constructor
    ///         init-data) so no one else can front-run ownership.
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    /// @dev UUPS upgrade gate: only the owner can swap the implementation.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev Validates a FeeShare array: non-empty, no zero accounts, no duplicates, every share > 0,
    ///      sum == 10 000, and at most one entry has `directFeesEnabled = true`. The factory caps
    ///      direct receivers at 1 here as a user-surface constraint
    function _validateFeeShares(FeeShare[] memory feeReceivers) internal pure {
        uint256 len = feeReceivers.length;
        require(len > 0, InvalidFeeReceiver());

        uint256 total;
        uint256 directCount;
        for (uint256 i = 0; i < len;) {
            require(feeReceivers[i].account != address(0), InvalidFeeReceiver());
            require(feeReceivers[i].shares > 0, InvalidShares());
            for (uint256 j = i + 1; j < len;) {
                require(feeReceivers[i].account != feeReceivers[j].account, InvalidFeeReceiver());
                unchecked {
                    ++j;
                }
            }
            total += feeReceivers[i].shares;
            if (feeReceivers[i].directFeesEnabled) {
                directCount++;
            }
            unchecked {
                ++i;
            }
        }
        require(total == BASIS_POINTS, InvalidShares());
        require(directCount <= 1, MultipleDirectFeeReceivers());
    }

    /// @dev Validates a SupplyShare array: non-empty, no zero accounts, no duplicates, every share > 0, sum == 10 000.
    function _validateSupplyShares(SupplyShare[] calldata supplyShares) internal pure {
        uint256 len = supplyShares.length;
        require(len > 0, InvalidSupplyShares());

        uint256 total;
        for (uint256 i = 0; i < len;) {
            require(supplyShares[i].account != address(0), InvalidSupplyShares());
            require(supplyShares[i].shares > 0, InvalidShares());
            for (uint256 j = i + 1; j < len;) {
                require(supplyShares[i].account != supplyShares[j].account, InvalidSupplyShares());
                unchecked {
                    ++j;
                }
            }
            total += supplyShares[i].shares;
            unchecked {
                ++i;
            }
        }
        require(total == BASIS_POINTS, InvalidShares());
    }

    /// @dev Splits `tokensBought` across `supplyShares` proportionally and emits `BuyOnDeploy`.
    ///      Rounding dust goes to the last recipient so no tokens remain in the factory.
    /// @param spent What the buy cost, in the pair's quote: wei on a native pair, the ERC20's raw units
    ///        otherwise. Reported as `BuyOnDeploy.quoteSpent`.
    /// @dev Shared by both venues because the split — and the event an indexer reads it from — must be
    ///      identical however the tokens were acquired: off a bonding curve on the curve factories, out
    ///      of the launch pool on the direct one.
    /// @dev deployer-buy receivers bypass the sniper-protection features (`from == tokenFactory`).
    function _distributeDeployBuy(
        address token,
        SupplyShare[] calldata supplyShares,
        uint256 tokensBought,
        uint256 spent
    ) internal {
        uint256 len = supplyShares.length;
        address[] memory recipients = new address[](len);
        uint256[] memory amounts = new uint256[](len);

        uint256 lastIdx = len - 1;
        uint256 distributed;
        for (uint256 i = 0; i < lastIdx;) {
            uint256 amount = tokensBought * supplyShares[i].shares / BASIS_POINTS;
            recipients[i] = supplyShares[i].account;
            amounts[i] = amount;
            distributed += amount;
            IERC20(token).safeTransfer(supplyShares[i].account, amount);
            unchecked {
                ++i;
            }
        }
        // last recipient absorbs rounding dust
        uint256 lastAmount = tokensBought - distributed;
        recipients[lastIdx] = supplyShares[lastIdx].account;
        amounts[lastIdx] = lastAmount;
        IERC20(token).safeTransfer(supplyShares[lastIdx].account, lastAmount);

        emit BuyOnDeploy(token, msg.sender, spent, tokensBought, recipients, amounts);
    }

    /// @dev Shared preamble for every factory's `createToken`: validates name/symbol and the fee
    ///      and supply share arrays. Single source of truth so both factories' `createToken`
    ///      have all input validation co-located at the top.
    function _validateInputs(
        string memory name,
        string memory symbol,
        FeeShare[] memory feeReceivers,
        SupplyShare[] calldata supplyShares
    ) internal {
        _validateInputs(name, symbol, feeReceivers, supplyShares, msg.value);
    }

    /// @dev Same, for a venue whose deploy buy is not necessarily paid in the chain's native currency.
    ///      `deployBuyAmount` is what the buy will actually spend — `msg.value` on the curve venues,
    ///      and on the direct one either that or the ERC20 amount the creator brought. What the check
    ///      is for is the pairing: recipients with nothing to give them, or a buy with nowhere to send
    ///      what it buys, are both a caller who believes something is configured that is not.
    function _validateInputs(
        string memory name,
        string memory symbol,
        FeeShare[] memory feeReceivers,
        SupplyShare[] calldata supplyShares,
        uint256 deployBuyAmount
    ) internal pure {
        _validateNameSymbol(name, symbol);
        _validateFeeShares(feeReceivers);
        if (deployBuyAmount > 0) _validateSupplyShares(supplyShares);
        else require(supplyShares.length == 0, InvalidSupplyShares());
    }

    /// @dev Enforces anti-sniper sentinel consistency. A zero window disables anti-sniper dispatch,
    ///      so all other anti-sniper inputs must also be empty/zero.
    function _validateAntiSniperConfig(AntiSniperConfigs calldata cfg) internal pure {
        if (cfg.protectionWindowSeconds == 0) {
            require(
                cfg.maxBuyPerTxBps == 0 && cfg.maxWalletBps == 0 && cfg.whitelist.length == 0, InvalidAntiSniperConfig()
            );
        }
    }

    /// @dev Validates the creator-vault array and returns the aggregate allocation.
    ///      Rules: at most `MAX_CREATOR_VAULTS` vaults; each `owner != 0`; each `supplyBps` a
    ///      non-zero multiple of `CREATOR_VAULT_BPS_STEP` (5%); the SUM `<= MAX_CREATOR_VAULT_TOTAL_BPS`
    ///      (30%). An empty array means no vaults (returns 0, 0). Cliff/vesting durations are
    ///      unconstrained here — any value is harmless and only affects the vault's own owner.
    function _validateCreatorVaults(CreatorVault[] memory creatorVaults)
        internal
        pure
        returns (uint256 totalBps, uint256 vaultAllocation)
    {
        uint256 len = creatorVaults.length;
        // exit with no-op
        if (len == 0) return (0, 0);

        require(len <= MAX_CREATOR_VAULTS, TooManyCreatorVaults());

        for (uint256 i = 0; i < len;) {
            CreatorVault memory v = creatorVaults[i];
            require(v.owner != address(0), InvalidCreatorVault());
            require(v.supplyBps != 0 && v.supplyBps % CREATOR_VAULT_BPS_STEP == 0, InvalidCreatorVault());
            totalBps += v.supplyBps;
            unchecked {
                ++i;
            }
        }

        require(totalBps <= MAX_CREATOR_VAULT_TOTAL_BPS, CreatorVaultAllocationTooHigh());
        vaultAllocation = TOTAL_SUPPLY * totalBps / BASIS_POINTS;
    }

    /// @dev Deploys one `RealmCreatorVault` per entry via the vault factory, which pulls each vault's
    ///      allocation from the supply minted to this factory during token init (hence the one-shot
    ///      approval). Asserts the factory ends with zero token balance, i.e. the per-vault amounts
    ///      summed to exactly `vaultAllocation` (they do by construction; the check guards against
    ///      future drift).
    function _deployAndFundVaults(address token, CreatorVault[] memory creatorVaults, uint256 vaultAllocation)
        internal
    {
        uint256 len = creatorVaults.length;
        address[] memory vaults = new address[](len);
        uint256[] memory amounts = new uint256[](len);

        IERC20(token).forceApprove(address(CREATOR_VAULT_FACTORY), vaultAllocation);
        for (uint256 i = 0; i < len;) {
            CreatorVault memory v = creatorVaults[i];
            uint256 amount = TOTAL_SUPPLY * v.supplyBps / BASIS_POINTS;
            address vault = CREATOR_VAULT_FACTORY.createVault(token, v.owner, amount, v.cliffSeconds, v.vestingSeconds);
            vaults[i] = vault;
            amounts[i] = amount;
            unchecked {
                ++i;
            }
        }

        require(IERC20(token).balanceOf(address(this)) == 0, CreatorVaultDistributionFailed());
        emit CreatorVaultsCreated(token, vaultAllocation, vaults, amounts);
    }

    /// @dev Shared name/symbol validation. Single source of truth — called once from `_validateInputs`
    ///      for both V2 and V4 factories.
    function _validateNameSymbol(string memory name, string memory symbol) internal pure {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 96, InvalidNameOrSymbol());
    }

    /// @notice Pre-graduation LP/trading fee (bps) the launchpad charges on bonding-curve trades for a
    ///         token whose post-graduation venue is `graduator`. A fixed per-venue rate, decoupled from the
    ///         post-graduation LP fee: V4 charges 1% regardless of the token's 50/100-bps post-graduation
    ///         hook fee; V2 has no post-graduation LP fee and returns its own fixed pre-graduation rate.
    ///         Split between treasury and creator by `_launchpadTreasuryShareBps`.
    function _launchpadLpFeeBps(address graduator) internal view virtual returns (uint16);

    /// @notice Share of the pre-graduation LP fee routed to the treasury (bps); the remainder goes to
    ///         the creator. Venue-specific protocol policy fixed at the factory level, not deployer-set.
    function _launchpadTreasuryShareBps() internal pure virtual returns (uint16);

    /// @dev Clones the resolved token implementation deterministically, enforces the `0xeeaa` vanity
    ///      suffix, emits `TokenCreated`, and returns the freshly-deployed token plus a fully-populated
    ///      `InitializeParams` for the caller to pass to the impl-specific `initialize()` overload.
    ///      `TokenCreated` is emitted BEFORE `initialize()` because the indexer creates the TokenData
    ///      entity from that event; events emitted inside `initialize()` depend on it.
    /// @dev The CREATE2 salt is namespaced by the deployer (`msg.sender`): the address is a function of
    ///      `(factory, impl, msg.sender, salt)`, not just `(factory, impl, salt)`. This gives every
    ///      deployer a private address space so a previewed/reserved address is reachable ONLY by the
    ///      account that reserved it. Without it, the token address is public-input-only and an attacker
    ///      could lift the salt from a pending `createToken` tx and front-run the deployment of a
    ///      pre-announced address with their own fee receivers. Namespacing lets the rest of the config
    ///      (fee receivers, anti-sniper, tax, …) stay deferred to reveal time with no front-running
    ///      window. Frontends MUST apply the same `keccak256(deployer, salt)` derivation when predicting
    ///      the address and mining the `0xeeaa` vanity suffix.
    function _cloneAndCreateToken(
        address impl,
        string memory name,
        string memory symbol,
        bytes32 salt,
        address tokenOwner,
        address graduator,
        uint16 swapLpFeeBps,
        uint256 vaultAllocation
    ) internal returns (address token, IRealmToken.InitializeParams memory params) {
        token = Clones.cloneDeterministic(impl, keccak256(abi.encodePacked(msg.sender, salt)));
        // forge-lint: disable-next-line(unsafe-typecast)
        require(uint16(uint160(token)) == 0xeeaa, InvalidTokenAddress());

        emit TokenCreated(token, name, symbol, tokenOwner, address(LAUNCHPAD), graduator, address(MASTER_FEE_HANDLER));

        params = IRealmToken.InitializeParams({
            name: name,
            symbol: symbol,
            tokenOwner: tokenOwner,
            graduator: graduator,
            launchpad: address(LAUNCHPAD),
            feeHandler: address(MASTER_FEE_HANDLER),
            vaultAllocation: vaultAllocation,
            // Pre-graduation LP-fee policy carried by the token and read by the launchpad each trade. A
            // fixed per-venue rate, decoupled from the post-graduation LP fee (V4: 1% regardless of the
            // token's 50/100-bps hook fee; V2: a fixed rate, as V2 has no post-graduation LP fee). The
            // treasury/creator split is venue-specific protocol policy. The creator tax is NOT stored here —
            // taxable variants store it from `TaxConfigs` in `_initializeTaxConfig`, and it applies
            // identically pre- and post-graduation. Non-tax tokens carry none (`getLaunchpadFees` returns 0 tax).
            lpFeeBps: _launchpadLpFeeBps(graduator),
            treasuryShareBps: _launchpadTreasuryShareBps(),
            // Post-graduation LP fee the `RealmSwapHook` charges on V4 swaps (50/100); 0 for V2. Surfaced
            // by the token via `getSwapFees` so the single hook reads each token's fee tier directly.
            swapLpFeeBps: swapLpFeeBps
        });
    }

    /// @dev Strips the `earningsAllocation` split off a `TaxConfigsWithMultiAllocation`, returning the
    ///      plain `TaxConfigs` the shared creation pipeline consumes. The allocation is read separately by
    ///      `createToken` and forwarded to `initializeEarningsAllocation`.
    function _toTaxConfigs(TaxConfigsWithMultiAllocation calldata c) internal pure returns (TaxConfigs memory cfg) {
        cfg.buyTaxBps = c.buyTaxBps;
        cfg.sellTaxBps = c.sellTaxBps;
        cfg.taxDurationSeconds = c.taxDurationSeconds;
        cfg.startTaxFromLaunch = c.startTaxFromLaunch;
        cfg.buyTaxDecayStartBps = c.buyTaxDecayStartBps;
        cfg.sellTaxDecayStartBps = c.sellTaxDecayStartBps;
        cfg.taxDecayDuration = c.taxDecayDuration;
    }

    /// @dev Same, for the direct venue's variant.
    function _toTaxConfigs(TaxConfigsWithDirectAllocation calldata c) internal pure returns (TaxConfigs memory cfg) {
        cfg.buyTaxBps = c.buyTaxBps;
        cfg.sellTaxBps = c.sellTaxBps;
        cfg.taxDurationSeconds = c.taxDurationSeconds;
        cfg.startTaxFromLaunch = c.startTaxFromLaunch;
        cfg.buyTaxDecayStartBps = c.buyTaxDecayStartBps;
        cfg.sellTaxDecayStartBps = c.sellTaxDecayStartBps;
        cfg.taxDecayDuration = c.taxDecayDuration;
    }

    /// @dev Whether an allocation configures any bucket at all. Shared by every factory's `createToken`
    ///      and preview, and the flag that routes the token to the taxable implementation.
    function _hasAllocation(uint16 burnBps, uint16 dividendsBps, uint16 liquidityBps) internal pure returns (bool) {
        return burnBps != 0 || dividendsBps != 0 || liquidityBps != 0;
    }

    /// @dev Raised by `createToken` when an allocation is set, for the length of its call, and consumed
    ///      by `_dispatchAndInitialize`, which routes the token to the taxable implementation on it. A
    ///      TRANSIENT marker rather than a parameter: the creation pipeline's stack is already at the
    ///      limit without `via_ir`, and this is the one input that only the dispatch reads. Cleared by
    ///      the read, so nothing outlives the call that set it.
    bool internal transient _allocationPending;

    /// @dev Validates a tax config. The static tax and the decay add-on are validated INDEPENDENTLY,
    ///      each with its own sentinel consistency (zero duration ⇒ zero bps, and vice-versa) so a token
    ///      may configure either, both, or neither — in particular a "decay-only" token sets just the
    ///      decay fields with no long-term static tax.
    ///      - Static: `taxDurationSeconds` capped at `MAX_TAX_DURATION_SECONDS` (120 years — an
    ///        overflow-prevention bound from `uint32` packing); the static-bps ceiling is venue-dependent
    ///        and enforced separately by `_validateTotalFee`.
    ///      - Decay: combined start bps (`buy + sell`) capped at `MAX_TAX_DECAY_START_COMBINED_BPS` (20%) and duration at
    ///        `MAX_TAX_DECAY_DURATION_SECONDS` (20 min). The decay bps are NOT part of the 5% cap in
    ///        `_validateTotalFee` (the effective rate is `max(decay, static)`, not their sum), only of its
    ///        hook-cap check; pre-graduation the launchpad's own per-trade `MAX_TRADING_FEE_BPS`
    ///        backstops the LP fee + decay total. Each configured decay start must be
    ///        strictly above its direction's static rate (`buyTaxDecayStartBps > buyTaxBps`, same for sell) —
    ///        the decay interpolates down to the static rate, so a start at or below it would never decay.
    ///        Checked per direction and only when that start is set, so single-direction and decay-only
    ///        (static 0) configs stay valid.
    ///      - Both: if a static tax AND a decay are configured, the static window must cover the decay
    ///        window (`taxDurationSeconds >= taxDecayDuration`) — the decay interpolates down to the static
    ///        rate, so a shorter static window would leave the long-term static tax effectively unused.
    ///      No fee-receiver or ownership constraints are imposed at any duration.
    function _validateTaxConfig(TaxConfigs memory t) internal pure {
        if (t.taxDurationSeconds != 0) {
            require(t.buyTaxBps > 0 || t.sellTaxBps > 0, InvalidTaxConfig());
            require(t.taxDurationSeconds <= MAX_TAX_DURATION_SECONDS, InvalidTaxDuration());
        } else {
            require(t.buyTaxBps == 0 && t.sellTaxBps == 0, InvalidTaxConfig());
        }

        if (t.taxDecayDuration != 0) {
            require(t.buyTaxDecayStartBps > 0 || t.sellTaxDecayStartBps > 0, InvalidTaxConfig());
            require(t.taxDecayDuration <= MAX_TAX_DECAY_DURATION_SECONDS, InvalidTaxDuration());
            require(
                uint256(t.buyTaxDecayStartBps) + t.sellTaxDecayStartBps <= MAX_TAX_DECAY_START_COMBINED_BPS,
                InvalidTaxBps()
            );
            // A configured decay must START strictly ABOVE its long-term static rate (per direction): the
            // decay interpolates DOWN to the static rate, so a start at or below it would never decay (the
            // effective `max(decay, static)` would just hold the static rate). Guarded per direction so a
            // single-direction decay (the other start 0) — and a decay-only token (static 0) — stay valid.
            if (t.buyTaxDecayStartBps != 0) require(t.buyTaxDecayStartBps > t.buyTaxBps, InvalidTaxBps());
            if (t.sellTaxDecayStartBps != 0) require(t.sellTaxDecayStartBps > t.sellTaxBps, InvalidTaxBps());
            // When BOTH a static tax and a decay are configured, the static window must cover the decay
            // window: the decay interpolates DOWN to the static rate, so a static window shorter than the
            // decay window would leave the long-term static tax effectively unused (it would expire before
            // the decay reaches it). A cliff at the static window's end is still expected — this only rules
            // out the degenerate config where the static duration plays no part.
            if (t.taxDurationSeconds != 0) {
                require(t.taxDurationSeconds >= t.taxDecayDuration, InvalidTaxDuration());
            }
        } else {
            require(t.buyTaxDecayStartBps == 0 && t.sellTaxDecayStartBps == 0, InvalidTaxConfig());
        }
    }

    /// @dev Caps the POST-graduation total fee a swapper pays (LP fee + tax) at `MAX_TOTAL_FEE_BPS`
    ///      (5%). Applied to buy and sell tax independently since a swap only ever pays one direction.
    ///      `lpFeeBps` is the venue's post-graduation LP fee — 0 for V2 (no LP fee, so tax can reach the
    ///      full 5%), 50 or 100 for V4 (leaving 450/400 bps for tax). Pre-graduation the launchpad
    ///      additionally charges its own LP fee on top of the tax; that transient total is bounded by
    ///      the launchpad's (looser) `MAX_TRADING_FEE_BPS`, not here. `taxCfg` bps are unbounded here, so
    ///      the sum is widened to `uint256` to avoid a spurious overflow revert before this check fires.
    /// @dev A decay can still be running once the pool trades on a V4 hook (from the first second on the
    ///      direct venue, after an early graduation on the curve ones), so LP fee + decay start must also
    ///      fit under the hook's own cap, or every swap in that direction reverts `FeeTooHigh`.
    function _validateTotalFee(uint256 lpFeeBps, TaxConfigs memory taxCfg) internal pure {
        require(
            lpFeeBps + taxCfg.buyTaxBps <= MAX_TOTAL_FEE_BPS && lpFeeBps + taxCfg.sellTaxBps <= MAX_TOTAL_FEE_BPS
                && lpFeeBps + taxCfg.buyTaxDecayStartBps <= HOOK_MAX_OVERALL_FEE_BPS
                && lpFeeBps + taxCfg.sellTaxDecayStartBps <= HOOK_MAX_OVERALL_FEE_BPS,
            InvalidTaxBps()
        );
    }

    /// @dev A token uses the taxable impl family if it configures a long-term static tax OR the launch
    ///      decay add-on. Decay-only tokens (no static tax) still need the taxable impl: post-graduation
    ///      tax collection (V2 intrinsic swap-back / V4 hook plumbing) lives only there.
    function _isTaxConfigured(TaxConfigs memory t) internal pure returns (bool) {
        return t.taxDurationSeconds != 0 || t.taxDecayDuration != 0;
    }

    /// @dev Whether the token configures a LONG-TERM static tax (a decay-only token returns false).
    ///      Gate for the earnings allocation: the decay window is capped at 20 minutes, so a decay-only
    ///      token has no meaningful post-graduation tax stream to split — its allocation would only ever
    ///      apply to the LP-fee creator share, which is not what the split is for.
    function _hasStaticTax(TaxConfigs memory t) internal pure returns (bool) {
        return t.taxDurationSeconds != 0;
    }

    /// @dev Buy tax (bps) the launchpad will charge on the deploy buy inside `createToken`. Only a
    ///      creation-anchored window (`startTaxFromLaunch`) is open at creation; a graduation-anchored
    ///      one charges no tax pre-graduation, so the deploy buy pays the LP fee alone. The deploy buy
    ///      lands at elapsed≈0, so the effective rate is `max(decay start, static)` — the same value the
    ///      token's `getLaunchpadFees` returns at launch. Used by the concrete factories'
    ///      `quoteBuyOnDeploy` so the quote matches the fee actually charged.
    /// @dev Design decision: the deployer's own deploy buy is intentionally taxed (no buyer-identity
    ///      exemption) — tax stays a pure function of (window, direction), keeping quotes caller-independent.
    //       If deployer==tax receiver, there is no extra cost, as all taxes go to the deployer anyway.
    function _deployBuyTaxBps(TaxConfigs memory taxCfg) internal pure returns (uint256) {
        if (!taxCfg.startTaxFromLaunch) return 0;
        uint256 staticBps = taxCfg.buyTaxBps;
        uint256 decayBps = taxCfg.buyTaxDecayStartBps;
        return decayBps > staticBps ? decayBps : staticBps;
    }

    /// @dev Single source of truth for which implementation `createToken` will clone. Both the public
    ///      `previewTokenImplementation` (used by frontends to mine a `0xeeaa`-suffixed salt) and
    ///      `_dispatchAndInitialize` (the path that actually clones the impl) read from this function — so
    ///      a salt that previews to a vanity-suffixed address is guaranteed to also produce one at create
    ///      time. An earnings allocation lives on the taxable implementation — the base token has no
    ///      split, no buffers and no dividend machine — so a token that configures one is cloned from it
    ///      even with no tax at all: on the V4 venues the creator's LP-fee share is a permanent earnings
    ///      stream in its own right. Anti-sniper is deliberately NOT a dispatch input: it is a gated
    ///      feature of both impls.
    function _previewTokenImplementation(TaxConfigs memory taxCfg, bool hasAllocation) internal view returns (address) {
        return (hasAllocation || _isTaxConfigured(taxCfg)) ? TOKEN_IMPL_TAX : TOKEN_IMPL_BASE;
    }

    /// @dev Resolves the implementation for `taxCfg` (tax vs non-tax — anti-sniper does NOT change the
    ///      impl), clones it, and runs the matching `initialize`. The ONLY branch is tax vs non-tax:
    ///      both impls take the `AntiSniperConfigs` and enable protection internally iff it opts in
    ///      (`protectionWindowSeconds != 0`), so the factory always forwards it and never branches on
    ///      anti-sniper. Impl resolution shares `_previewTokenImplementation` with the public preview,
    ///      so a salt that previews to a `0xeeaa` address also clones to one. Callers (`createToken` on
    ///      the derived factory) invoke `LAUNCHPAD.launchToken` and `_finalizeCreation` (which registers
    ///      the token's fee config with the master handler) after this returns.
    function _dispatchAndInitialize(
        string memory name,
        string memory symbol,
        bytes32 salt,
        address tokenOwner,
        address graduator,
        uint16 swapLpFeeBps,
        uint256 vaultAllocation,
        TaxConfigs memory taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        bool hasAllocation = _allocationPending;
        if (hasAllocation) _allocationPending = false;
        address impl = _previewTokenImplementation(taxCfg, hasAllocation);

        IRealmToken.InitializeParams memory params;
        (token, params) =
            _cloneAndCreateToken(impl, name, symbol, salt, tokenOwner, graduator, swapLpFeeBps, vaultAllocation);

        if (impl == TOKEN_IMPL_TAX) {
            // Taxable impl: stores the tax rate from `taxCfg` in `_initializeTaxConfig`. With an
            // allocation and no tax, `taxCfg` is all zeros and the token simply charges none.
            IRealmTaxableToken(payable(token)).initialize(params, taxCfg, antiSniperCfg);
        } else {
            // Non-tax impl: `taxCfg` is empty (validated); base `getLaunchpadFees` returns 0 tax.
            RealmToken(token).initialize(params, antiSniperCfg);
        }
    }

    /// @dev Reserved for future storage variables. Decrement when adding new storage to keep the
    ///      proxy's slot layout stable across upgrades. Never reorder existing storage.
    uint256[50] private __gap;
}
