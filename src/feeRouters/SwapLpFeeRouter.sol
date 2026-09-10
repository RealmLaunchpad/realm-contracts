// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {ISwapLpFeeRouter} from "src/interfaces/ISwapLpFeeRouter.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";

/// @title SwapLpFeeRouter
/// @notice UUPS-upgradeable router that splits LP fees collected by `RealmSwapHook` between the
///         protocol treasury and the per-token creator share with a flat 30/70 split (a future
///         implementation may carve out a liquidity-reinvestment slice).
/// @dev    The implementation contract is intentionally stateless beyond standard UUPS storage
///         (owner + proxy slots). The split and the treasury address are baked into the
///         implementation's bytecode, so changing either is done by deploying a new implementation
///         and calling `upgradeTo` on the proxy.
contract SwapLpFeeRouter is ISwapLpFeeRouter, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice Basis points denominator (10000 = 100%).
    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Treasury share of every routed LP fee (bps): 30 treasury / 70 creator.
    uint16 public constant TREASURY_BPS = 3_000;

    /// @notice Treasury address that receives the treasury slice on every routing. Baked into the
    ///         implementation as an immutable so each routing avoids the external
    ///         `LAUNCHPAD.treasury()` lookup. If the treasury changes, deploy a new router
    ///         implementation with the new value and `upgradeTo` it.
    address public immutable TREASURY;

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
    error InvalidTreasury();

    /// @notice Sets up the implementation's immutables. The implementation itself is not meant to
    ///         be used directly — `_disableInitializers()` locks its proxy storage so only proxies
    ///         pointing to this implementation can be initialized.
    /// @dev    Immutables are read from the implementation's bytecode through delegatecall, so they
    ///         work transparently behind the UUPS proxy. To change the treasury, deploy a new impl
    ///         with a different constructor arg and call `upgradeTo` on the proxy.
    constructor(address treasury_) {
        require(treasury_ != address(0), InvalidTreasury());
        TREASURY = treasury_;
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
    /// @dev `ethSwapAmount` / `tokenSwapAmount` are accepted for ABI stability but unused: the split
    ///      is flat, no longer marketcap-tiered.
    /// @dev SECURITY NOTE: this entrypoint is intentionally permissionless. Any external caller can
    ///      route fees by sending ETH along with an arbitrary `token`. This is acceptable because the
    ///      caller is splitting their own ETH (no protocol funds at risk). Do NOT add protocol logic
    ///      elsewhere that assumes routings only originate from the hook.
    function depositLpFees(address token, uint256, uint256) external payable override {
        if (msg.value == 0) return;

        uint256 treasuryShare = (msg.value * TREASURY_BPS) / BASIS_POINTS;
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

    /// @dev Reserved for future storage variables. Decrement when adding new storage to keep the
    ///      proxy's slot layout stable across upgrades. Never reorder existing storage.
    uint256[50] private __gap;
}
