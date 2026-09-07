// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {ISwapLpFeeRouter} from "src/interfaces/ISwapLpFeeRouter.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";

/// @title SwapLpFeeRouter
/// @notice UUPS-upgradeable router that splits LP fees collected by `LivoSwapHook` between the
///         protocol treasury, the per-token creator share, and (future) a liquidity-reinvestment
///         slice, using a marketcap-tiered split.
/// @dev    The implementation contract is intentionally stateless beyond standard UUPS storage
///         (owner + proxy slots). Every tier threshold, split BPS and the treasury address are
///         baked into the implementation's bytecode as `immutable`s, so changing any of them is
///         done by deploying a new implementation and calling `upgradeTo` on the proxy.
/// @dev    Marketcap is computed from the swap's avg price — derived directly from the
///         `(ethSwapAmount, tokenSwapAmount)` pair supplied by the hook — times the fixed 1B token
///         total supply. No oracle, no slot0 read, no external call, no launchpad coupling.
contract SwapLpFeeRouter is ISwapLpFeeRouter, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice Basis points denominator (10000 = 100%).
    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Total supply of every Realm token (1B, 18 decimals). Every token routed through this
    ///         router is a `RealmToken` with this fixed supply, so it is hardcoded to spare an external
    ///         `token.totalSupply()` call on every routing. Mirrors `RealmToken.TOTAL_SUPPLY`.
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Treasury address that receives the treasury slice on every routing. Baked into the
    ///         implementation as an immutable so each routing avoids the external
    ///         `LAUNCHPAD.treasury()` lookup. If the treasury changes, deploy a new router
    ///         implementation with the new value and `upgradeTo` it.
    address public immutable TREASURY;

    /// @notice Ascending marketcap thresholds, in native 18-dec wei (ETH on the ETH-family chains,
    ///         USDC on ARC). Tier `i` applies while `marketcap` is in `[THRESHOLD_i, THRESHOLD_{i+1})`.
    ///         `THRESHOLD_0 == 0` is implicit.
    /// @dev    Stored as 6 individual immutables (rather than an array) so each tier lookup is a
    ///         single PUSH from bytecode instead of an SLOAD chain.
    uint256 public immutable THRESHOLD_1;
    uint256 public immutable THRESHOLD_2;
    uint256 public immutable THRESHOLD_3;
    uint256 public immutable THRESHOLD_4;
    uint256 public immutable THRESHOLD_5;
    uint256 public immutable THRESHOLD_6;

    /// @notice Treasury share in basis points for each tier (the creator share is the complement).
    uint16 public immutable TIER0_TREASURY_BPS;
    uint16 public immutable TIER1_TREASURY_BPS;
    uint16 public immutable TIER2_TREASURY_BPS;
    uint16 public immutable TIER3_TREASURY_BPS;
    uint16 public immutable TIER4_TREASURY_BPS;
    uint16 public immutable TIER5_TREASURY_BPS;
    uint16 public immutable TIER6_TREASURY_BPS;

    /// @notice Emitted on every successful routing.
    /// @param token          The token whose LP fees were routed.
    /// @param creatorShare   The portion forwarded to the creator via `token.accrueFees`.
    /// @param treasuryShare  The portion sent to the treasury.
    /// @param liquidityShare The portion (re)deployed as additional liquidity. Hardcoded to zero
    ///                       in this implementation; future implementations may populate it when
    ///                       a liquidity-reinvestment path is wired in. The field is included
    ///                       from day one so indexers and the off-chain ABI stay stable.
    event LpFeesRouted(address indexed token, uint256 creatorShare, uint256 treasuryShare, uint256 liquidityShare);

    error TreasuryTransferFailed();
    error InvalidTreasuryBps();
    error InvalidThresholds();
    error InvalidTreasury();

    /// @notice Configuration baked into the implementation as immutables.
    /// @dev `thresholds` must be strictly ascending. Each `treasuryBps` must be ≤ 10000.
    struct Config {
        uint256[6] thresholds;
        uint16[7] treasuryBps;
    }

    /// @notice Sets up the implementation's immutables. The implementation itself is not meant to
    ///         be used directly — `_disableInitializers()` locks its proxy storage so only proxies
    ///         pointing to this implementation can be initialized.
    /// @dev    Immutables are read from the implementation's bytecode through delegatecall, so they
    ///         work transparently behind the UUPS proxy. To change any of them, deploy a new impl
    ///         with different constructor args and call `upgradeTo` on the proxy.
    constructor(address treasury_, Config memory cfg) {
        require(treasury_ != address(0), InvalidTreasury());

        // Thresholds must be strictly ascending so the linear tier scan resolves unambiguously.
        // `thresholds[0] > 0` is also required: if the first threshold were zero, the tier-0
        // branch in `_resolveTreasuryBps` would be unreachable (every marketcap would fall
        // through to tier 1+) and `TIER0_TREASURY_BPS` would be dead bytecode.
        require(
            cfg.thresholds[0] > 0 && cfg.thresholds[0] < cfg.thresholds[1] && cfg.thresholds[1] < cfg.thresholds[2]
                && cfg.thresholds[2] < cfg.thresholds[3] && cfg.thresholds[3] < cfg.thresholds[4]
                && cfg.thresholds[4] < cfg.thresholds[5],
            InvalidThresholds()
        );

        // Every tier's treasury share must be a valid BPS (≤ 100%).
        require(
            cfg.treasuryBps[0] <= BASIS_POINTS && cfg.treasuryBps[1] <= BASIS_POINTS
                && cfg.treasuryBps[2] <= BASIS_POINTS && cfg.treasuryBps[3] <= BASIS_POINTS
                && cfg.treasuryBps[4] <= BASIS_POINTS && cfg.treasuryBps[5] <= BASIS_POINTS
                && cfg.treasuryBps[6] <= BASIS_POINTS,
            InvalidTreasuryBps()
        );

        TREASURY = treasury_;

        THRESHOLD_1 = cfg.thresholds[0];
        THRESHOLD_2 = cfg.thresholds[1];
        THRESHOLD_3 = cfg.thresholds[2];
        THRESHOLD_4 = cfg.thresholds[3];
        THRESHOLD_5 = cfg.thresholds[4];
        THRESHOLD_6 = cfg.thresholds[5];

        TIER0_TREASURY_BPS = cfg.treasuryBps[0];
        TIER1_TREASURY_BPS = cfg.treasuryBps[1];
        TIER2_TREASURY_BPS = cfg.treasuryBps[2];
        TIER3_TREASURY_BPS = cfg.treasuryBps[3];
        TIER4_TREASURY_BPS = cfg.treasuryBps[4];
        TIER5_TREASURY_BPS = cfg.treasuryBps[5];
        TIER6_TREASURY_BPS = cfg.treasuryBps[6];

        _disableInitializers();
    }

    /// @notice One-shot initializer for the proxy. Sets `msg.sender` as the initial owner.
    /// @dev Must be called atomically with proxy deployment (via `ERC1967Proxy`'s constructor
    ///      init-data) so no one else can front-run ownership.
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    /// @dev UUPS upgrade gate: only the owner can swap the implementation.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @inheritdoc ISwapLpFeeRouter
    /// @dev Reverts on treasury transfer failure so the calling hook can apply its own fallback.
    /// @dev SECURITY NOTE: this entrypoint is intentionally permissionless. Any external caller
    ///      can route fees by sending ETH along with arbitrary
    ///      `(token, ethSwapAmount, tokenSwapAmount)` — meaning they fully control the marketcap
    ///      input and therefore the tier picked. This is acceptable because (a) the caller is
    ///      splitting their own ETH (no protocol funds at risk), and (b) the only "trusted"
    ///      caller (the hook) supplies `(ethSwapAmount, tokenSwapAmount)` derived from on-chain
    ///      swap deltas the trader cannot manipulate. Do NOT add protocol logic elsewhere that
    ///      assumes routings only originate from the hook.
    function depositLpFees(address token, uint256 ethSwapAmount, uint256 tokenSwapAmount) external payable override {
        if (msg.value == 0) return;

        uint256 marketcap = _computeMarketcapEth(ethSwapAmount, tokenSwapAmount);
        uint16 treasuryBps = _resolveTreasuryBps(marketcap);

        uint256 treasuryShare = (msg.value * treasuryBps) / BASIS_POINTS;
        uint256 creatorShare = msg.value - treasuryShare;
        // Liquidity-reinvestment slice is reserved for a future implementation.
        uint256 liquidityShare = 0;

        emit LpFeesRouted(token, creatorShare, treasuryShare, liquidityShare);

        if (treasuryShare > 0) {
            (bool ok,) = TREASURY.call{value: treasuryShare}("");
            require(ok, TreasuryTransferFailed());
        }
        if (creatorShare > 0) {
            // Forwards to the master fee handler via the token's own `accrueFees`. The token is
            // pre-approved as a recipient there and routes to the configured creator/fee receivers.
            IRealmToken(token).accrueFees{value: creatorShare}();
        }
    }

    /// @dev Linear tier resolution. The most-common buckets (tier 0 / tier 1) are checked first
    ///      so the typical swap pays for at most one comparison instead of six.
    function _resolveTreasuryBps(uint256 marketcapEth) internal view returns (uint16) {
        if (marketcapEth < THRESHOLD_1) return TIER0_TREASURY_BPS;
        if (marketcapEth < THRESHOLD_2) return TIER1_TREASURY_BPS;
        if (marketcapEth < THRESHOLD_3) return TIER2_TREASURY_BPS;
        if (marketcapEth < THRESHOLD_4) return TIER3_TREASURY_BPS;
        if (marketcapEth < THRESHOLD_5) return TIER4_TREASURY_BPS;
        if (marketcapEth < THRESHOLD_6) return TIER5_TREASURY_BPS;
        return TIER6_TREASURY_BPS;
    }

    /// @dev Computes marketcap in native wei from the swap's avg price and the fixed `TOTAL_SUPPLY`.
    ///      `price = ethSwapAmount / tokenSwapAmount` (in respective smallest units; both the native
    ///      currency and Realm tokens use 18 decimals so the ratio is dimensionless). Marketcap =
    ///      `price × TOTAL_SUPPLY`, reordered as `(TOTAL_SUPPLY × ethSwapAmount) / tokenSwapAmount` to
    ///      avoid precision loss on the intermediate price.
    /// @dev    Returns 0 if `tokenSwapAmount` is zero (degenerate swap); the caller falls back to
    ///         tier 0 in that case.
    function _computeMarketcapEth(uint256 ethSwapAmount, uint256 tokenSwapAmount) internal pure returns (uint256) {
        if (tokenSwapAmount == 0) return 0;
        return (TOTAL_SUPPLY * ethSwapAmount) / tokenSwapAmount;
    }

    /// @dev Reserved for future storage variables. Decrement when adding new storage to keep the
    ///      proxy's slot layout stable across upgrades. Never reorder existing storage.
    uint256[50] private __gap;
}
