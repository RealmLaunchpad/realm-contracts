// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmGraduator} from "src/interfaces/IRealmGraduator.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {SniperProtection, AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @dev Anti-sniper protection is folded into every token as a gated feature: `SniperProtection`
///      supplies the caps + window logic, and the warm-slot `hasSniperProt` flag (packed into the
///      `pair`/`graduated` slot the hot path already loads) gates it. Tokens that don't opt in pay
///      no extra SLOAD and behave identically to a plain token — the caps code is present but never
///      reached. Tax variants (`RealmTaxableToken*`) inherit this same gated feature.
contract RealmToken is ERC20, IRealmToken, Initializable, SniperProtection {
    /// @notice Version of the Realm stack this token belongs to
    string public constant override VERSION = "2.0";

    /// @notice all Realm tokens have same supply
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Owner of the token. The creator unless communityTakeOver takes place
    address public owner;

    /// @notice Address who can accept ownership of the token
    /// @dev It can be address(0) if no owner is proposed
    address public proposedOwner;

    /// @notice The only graduator allowed to graduate this token
    address public graduator;

    /// @notice Uniswap pair. Token transfers to this address are blocked before graduation
    /// @dev Packed with `graduated` and `hasSniperProt` so the hot-path read of all three fields in
    ///      `_update` costs a single SLOAD.
    address public pair;

    /// @notice Whether the token has graduated already or not
    bool public graduated;

    /// @notice Whether anti-sniper protection is enabled for this token. Set once at initialization
    ///         when an `AntiSniperConfigs` with a non-zero window is supplied. Packs into the `pair`
    ///         slot so `_update` reads it for free while it already loads `pair`/`graduated`; gates the
    ///         `SniperProtection` caps so non-opted-in tokens skip the check entirely.
    bool public hasSniperProt;

    /// @notice Whether holder dividends are enabled for this token. Set once at creation, by the taxable
    ///         variant, when the earnings allocation routes a non-zero share to dividends. Lives HERE,
    ///         rather than beside the rest of the dividend state, purely for gas: it packs into the
    ///         `pair` slot that `_update` already loads, so a token WITHOUT dividends pays nothing at all
    ///         for the feature — no extra SLOAD, no branch that costs a cold read.
    bool public hasDividends;

    /// @notice How many payout assets this token pays dividends in (0 when `hasDividends` is false,
    ///         otherwise 1..`DividendDistribution.MAX_DIVIDEND_ASSETS`). Set once at creation, alongside
    ///         `hasDividends`, and never changed — the set a token pays in is fixed for its life.
    /// @dev Lives HERE, beside `hasDividends` and for the same reason: it packs into the `pair` slot that
    ///      `_update` already loads, so the transfer hook learns how many assets to settle from a WARM
    ///      slot instead of a cold one. A token without dividends never reads it at all.
    uint8 public dividendAssetCount;

    /// @notice Launchpad address
    RealmLaunchpad public launchpad;

    /// @notice Contract handling fees for this token
    address public feeHandler;

    /// @notice Pre-graduation LP/trading fee on buys and sells (bps), read by the launchpad each trade
    ///         and split between treasury and creator. Single rate for both directions, mirroring the
    ///         post-graduation `LivoSwapHook`. Fixed at launch (no setter — the owner cannot change LP fees).
    uint16 public lpFeeBps;

    /// @notice Share of the LP fee routed to the treasury (bps); the remainder goes to the creator via
    ///         `accrueFees`. Fixed at launch.
    uint16 public treasuryShareBps;

    /// @notice Post-graduation LP fee `LivoSwapHook` charges on every V4 swap (bps), surfaced via
    ///         `getSwapFees`. 0 for Uniswap V2 (no hook LP fee); 50 or 100 for V4. Distinct from the
    ///         pre-graduation `lpFeeBps` the launchpad charges on the bonding curve. Fixed at launch.
    /// @dev Packs into the `feeHandler` + `launchTimestamp` slot alongside `lpFeeBps`/`treasuryShareBps`.
    uint16 public swapLpFeeBps;

    /// @notice Timestamp of token creation (the `initialize` call). Anchors both the sniper-protection
    ///         window (passed into `SniperProtection`) and, on taxable variants, the creation-anchored
    ///         tax window. Set once at the end of `_initializeRealmToken`, after the initial mint, so the
    ///         mint still observes `launchTimestamp == 0`. Packs into this slot alongside `feeHandler`.
    uint40 public launchTimestamp;

    /// @notice Factory that initialized this token. Allowed to perform one-shot fee registration.
    /// @dev Lives in transient storage: the factory calls `initialize` and `registerFees` in the
    ///      same tx, so the value only needs to survive across that single tx. Auto-clears at
    ///      end of tx, so a second `registerFees` attempt from any future tx finds it zeroed
    ///      and reverts on the `msg.sender == 0` check.
    /// @dev SECURITY ASSUMPTION (tokens with `hasSniperProt`): `SniperProtection._checkSniperProtection`
    ///      reads this slot to exempt the deployer-buy hops `launchpad → factory → supplyShares`
    ///      from the per-tx / per-wallet caps (both `to == factoryAddr` and `from == factoryAddr`
    ///      branches). Outside the deploy tx the slot reads `address(0)`, so the exemption checks
    ///      effectively become `if (to == address(0)) return;` and `if (from == address(0))
    ///      return;`. This is currently safe because:
    ///        - `to == 0`: OZ ERC20 v5's `transfer`/`transferFrom` revert with
    ///          `ERC20InvalidReceiver` before reaching `_update`, so the `to == factoryAddr`
    ///          branch is unreachable with `factoryAddr == 0`.
    ///        - `from == 0`: the only mint is `_initializeRealmToken`'s initial mint to the
    ///          launchpad, which runs before `_initializeSniperProtection` caches
    ///          `protectionWindowEnd` (so it reads 0 during the mint, and `launchTimestamp` itself
    ///          is also set only at the END of this initializer). At that moment the window-active
    ///          check (`block.timestamp >= protectionWindowEnd`) returns early on its own, so the
    ///          `from == factoryAddr` branch is unreachable with `factoryAddr == 0`.
    /// @dev ⚠️ FUTURE FOOT-GUN: any new path that lets `_update` fire with `to == address(0)`
    ///      OR with `from == address(0)` while the protection window is open (`protectionWindowEnd`
    ///      set, not yet elapsed) would silently bypass the sniper caps. Concrete cases to watch out for:
    ///        - a custom transfer override (or alternate ERC20 base) that drops the
    ///          zero-recipient guard, enabling burns through `_update`;
    ///        - any new `_mint` call site that runs after init (e.g. a rebase or inflation
    ///          hook), since post-init mints have `from == address(0)`;
    ///        - any new internal call site that issues `_update(*, address(0), x)` directly
    ///          (e.g. a "burn from launchpad" admin path).
    ///      If any such path is introduced, harden the exemption: pass a non-zero sentinel
    ///      for the cleared state, or have `_checkSniperProtection` add explicit
    ///      `factoryAddr != address(0)` guards around the factoryAddr short-circuits.
    address internal transient tokenFactory;

    /// @notice Token name
    string internal _tokenName;

    /// @notice Token symbol
    string internal _tokenSymbol;

    //////////////////////// Errors //////////////////////

    error OnlyGraduatorAllowed();
    error TransferToPairBeforeGraduationNotAllowed();
    error CannotSelfTransfer();
    error Unauthorized();

    //////////////////////////////////////////////////////

    /// @notice Creates a new RealmToken instance which will be used as implementation for clones
    /// @dev Token name and symbol are set during initialization, not in constructor
    constructor() ERC20("", "") {
        _disableInitializers();
    }

    /// @notice Initializes the token clone. Anti-sniper protection is enabled iff `antiSniperCfg` opts
    ///         in (`protectionWindowSeconds != 0`); pass an all-zero config for a plain token.
    /// @param params Shared token initialization parameters
    /// @param antiSniperCfg Anti-sniper caps + window config (validated upstream in the factory)
    function initialize(IRealmToken.InitializeParams memory params, AntiSniperConfigs memory antiSniperCfg)
        external
        virtual
        initializer
    {
        _initializeRealmToken(params);
        _initializeAntiSniper(antiSniperCfg);
    }

    /// @dev Internal initializer body; callable from child `initializer`-gated functions.
    /// @dev `params.graduator` is not explicitly checked for `address(0)`; the call to
    ///      `IRealmGraduator(params.graduator).initialize(address(this))` below would revert in
    ///      that case anyway (no code at the zero address).
    function _initializeRealmToken(IRealmToken.InitializeParams memory params) internal onlyInitializing {
        _tokenName = params.name;
        _tokenSymbol = params.symbol;
        graduator = params.graduator;
        owner = params.tokenOwner;
        feeHandler = params.feeHandler;
        tokenFactory = msg.sender;
        pair = IRealmGraduator(params.graduator).initialize(address(this));

        // Defensive ordering: set `launchpad` before `_mint` so any future `_update()` override that
        // reads it sees the real value. The mint itself is not gated by the sniper-protection check:
        // `protectionWindowEnd` is cached only later by `_initializeSniperProtection`, so it reads 0
        // during the mint and the check's window-active early-return (`block.timestamp >= 0`) covers it.
        launchpad = RealmLaunchpad(params.launchpad);

        // Creator-vault tokens lock `vaultAllocation` of the supply: only `TOTAL_SUPPLY - vaultAllocation`
        // is sold on the (allocation-specific) bonding curve via the launchpad; the rest is minted to
        // the factory (`msg.sender`), which distributes it into the vesting vaults in this same tx.
        // `vaultAllocation == 0` (the common case) reproduces the original single mint exactly.
        // The factory→vault transfers later in the tx are exempt from sniper caps via the
        // `from == tokenFactory` branch in `_checkSniperProtection`.
        uint256 vaultAllocation = params.vaultAllocation;
        _mint(params.launchpad, TOTAL_SUPPLY - vaultAllocation);
        if (vaultAllocation > 0) {
            _mint(msg.sender, vaultAllocation);
        }

        // Pre-graduation LP-fee policy carried by the token and read by the launchpad each trade.
        // Bounds are enforced upstream in the factory (and re-capped by the launchpad at read time).
        // These fields pack into a single storage slot (shared with `feeHandler` and `launchTimestamp`),
        // so the launchpad's per-trade `getLaunchpadFees` read is a single warm SLOAD.
        lpFeeBps = params.lpFeeBps;
        treasuryShareBps = params.treasuryShareBps;
        swapLpFeeBps = params.swapLpFeeBps;
        emit LaunchpadFeesInitialized(params.lpFeeBps, params.treasuryShareBps);

        // Creation timestamp, set AFTER the initial mint so that mint still observes
        // `launchTimestamp == 0` (the sniper-window early-return relies on it; see the `tokenFactory`
        // security note). Anchors the sniper window and the taxable variants' tax window.
        launchTimestamp = uint40(block.timestamp);
    }

    /// @dev Opt-in gate for anti-sniper protection, called by every token's `initialize`. A zero
    ///      protection window means "not configured" (the factory's `_validateAntiSniperConfig`
    ///      guarantees the rest of the config is then also empty), so this no-ops and leaves
    ///      `hasSniperProt` false — a plain token. Otherwise it validates + stores the caps and window
    ///      and flips the warm-slot `hasSniperProt` gate so `_update` / `maxTokenPurchase` enforce them.
    ///      Must run AFTER `_initializeRealmToken` (which sets `launchTimestamp`, the window anchor).
    function _initializeAntiSniper(AntiSniperConfigs memory antiSniperCfg) internal onlyInitializing {
        if (antiSniperCfg.protectionWindowSeconds == 0) return;
        _initializeSniperProtection(antiSniperCfg, launchTimestamp);
        hasSniperProt = true;
    }

    //////////////////////// restricted access functions ////////////////////////

    /// @notice Marks the token as graduated, which unlocks transfers to the pair
    /// @dev Can only be called by the pre-set graduator contract
    function markGraduated() external virtual {
        require(msg.sender == graduator, OnlyGraduatorAllowed());

        graduated = true;
        emit Graduated();
    }

    /// @notice Proposes a new owner for a token. Only callable by the current tokenOwner.
    ///         Pass address(0) as newOwner to cancel a pending proposal.
    /// @dev Also callable by the launchpad for communityTakeOvers. Effectively called by admins.
    function proposeNewOwner(address newOwner) external {
        address _owner = owner;
        require(msg.sender == _owner || msg.sender == address(launchpad), Unauthorized());

        proposedOwner = newOwner;

        emit NewOwnerProposed(_owner, newOwner, msg.sender);
    }

    /// @notice Accepts token ownership. Only callable by the address proposed as new owner.
    function acceptTokenOwnership() external {
        require(msg.sender == proposedOwner, Unauthorized());

        owner = msg.sender;
        delete proposedOwner;

        emit OwnershipTransferred(msg.sender);
    }

    /// @notice Permanently renounces ownership. Only callable by the current owner.
    /// @dev Clears both owner and any pending proposedOwner.
    function renounceOwnership() external {
        require(msg.sender == owner, Unauthorized());
        delete owner;
        delete proposedOwner;
        emit OwnershipTransferred(address(0));
    }

    //////////////////////// fee accrual ////////////////////////

    /// @notice Registers this token's initial fee shares in the master fee handler.
    /// @dev Callable only by the factory that initialized the token. The handler infers the token
    ///      from `msg.sender`, so this token contract is the only address registered.
    function registerFees(IRealmFactory.FeeShare[] calldata feeShares) external {
        require(msg.sender == tokenFactory, Unauthorized());
        IRealmMasterFeeHandler(feeHandler).registerToken(feeShares);
    }

    /// @notice Routes ETH fees to the fee handler for this token
    /// @dev `virtual` so taxable variants can override to split earnings across allocation buckets
    ///      (see `EarningsAllocation`) before the fund-wallet deposit.
    function accrueFees() external payable virtual {
        IRealmMasterFeeHandler(feeHandler).depositFees{value: msg.value}(address(this));
    }

    //////////////////////// view functions ////////////////////////

    /// @notice Returns the underlying fee receiver addresses and their share in basis points
    function getFeeReceivers() external view returns (address[] memory, uint256[] memory) {
        return IRealmMasterFeeHandler(feeHandler).getRecipients(address(this));
    }

    /// @notice Default tax config returning no taxes. Overridden by taxable token implementations.
    /// @dev LEGACY, superseded by `getSwapFees` — kept for backwards compatibility (see `IRealmToken`).
    function getTaxConfig() external view virtual returns (IRealmToken.TaxConfig memory config) {}

    /// @notice Default swap fees: the always-on post-graduation LP fee with zero tax. Taxable variants
    ///         override to add the windowed tax for `isBuy`. `swapLpFeeBps` is set at init (0 for V2).
    function getSwapFees(bool) external view virtual returns (IRealmToken.RealmTradeFees memory) {
        return IRealmToken.RealmTradeFees({taxBps: 0, lpFeeBps: swapLpFeeBps});
    }

    /// @notice Returns the pre-graduation fee policy for a trade. The base implementation returns the
    ///         configured LP fee with no tax (non-taxable tokens never have one); taxable variants
    ///         override to add the creation-anchored tax. `virtual` so future variants can compute
    ///         dynamic rates.
    function getLaunchpadFees(IRealmToken.LaunchpadTrade calldata)
        external
        view
        virtual
        returns (IRealmToken.LaunchpadFees memory)
    {
        return IRealmToken.LaunchpadFees({lpFeeBps: lpFeeBps, treasuryShareBps: treasuryShareBps, taxBps: 0});
    }

    /// @notice Largest amount `buyer` may purchase on the bonding curve right now. No cap unless the
    ///         token opted into anti-sniper protection (`hasSniperProt`), in which case the per-tx /
    ///         per-wallet caps apply during the protection window.
    function maxTokenPurchase(address buyer) external view virtual returns (uint256) {
        if (!hasSniperProt) return type(uint256).max;
        return _maxTokenPurchase(buyer, balanceOf(buyer), graduated);
    }

    /// @dev ERC20 interface compliance
    function name() public view override returns (string memory) {
        return _tokenName;
    }

    /// @dev ERC20 interface compliance
    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @dev Launchpad is pre-approved
    function allowance(address owner_, address spender) public view override(ERC20, IERC20) returns (uint256) {
        if (spender == address(launchpad)) return type(uint256).max;
        return super.allowance(owner_, spender);
    }

    //////////////////////// internal functions ////////////////////////

    /// @dev Balance-change hook for gated per-account features that need to observe every transfer.
    ///      A no-op here (and never even reached on a token without dividends, thanks to the warm-slot
    ///      gate in `_update`); the taxable variant overrides it to maintain the dividend round minima.
    ///      Runs BEFORE the balances move, so implementations read pre-transfer balances.
    function _onBalanceChange(address from, address to, uint256 amount) internal virtual {}

    function _update(address from, address to, uint256 amount) internal virtual override {
        // Load `pair`/`graduated`/`hasSniperProt`/`hasDividends` (one packed slot) with a single SLOAD,
        // reused for every check below instead of re-reading the slot up to four times.
        (address _pair, bool _graduated, bool _hasSniperProt, bool _hasDividends) =
            (pair, graduated, hasSniperProt, hasDividends);

        // Dividend round minima, gated by the warm-slot flag so a non-dividend token pays nothing.
        if (_hasDividends) _onBalanceChange(from, to, amount);

        // Anti-sniper caps, gated by the warm-slot flag. Only enforced pre-graduation;
        // `_hasSniperProt && !_graduated` short-circuits for the common non-protected token AND for
        // every post-graduation transfer (when the tax variants' `_update` re-enters here after
        // splitting a taxed transfer).
        if (_hasSniperProt && !_graduated) {
            _checkSniperProtection(
                from, to, amount, address(launchpad), tokenFactory, address(graduator), balanceOf(to)
            );
        }

        // this ensures tokens don't arrive to the pair before graduation
        // to avoid exploits/DOS related to liquidity addition at graduation
        if ((!_graduated) && (to == _pair)) {
            revert TransferToPairBeforeGraduationNotAllowed();
        }

        super._update(from, to, amount);
    }

    function _spendAllowance(address owner_, address spender, uint256 value) internal override {
        // skips allowance logic if the spender is the launchpad to pre-approve launchpad forever
        if (spender == address(launchpad)) return;

        super._spendAllowance(owner_, spender, value);
    }
}
