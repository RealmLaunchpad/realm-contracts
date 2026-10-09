// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RealmTreasuryRouter
/// @notice The address every protocol contract pushes treasury native to (launchpad trading fees, graduation
///         fees, the LP fee router's treasury slice). Forwards everything to the treasury multisig. Putting
///         this proxy in front of the multisig is what lets the treasury policy change later without touching
///         the systems that pay it.
/// @dev    UUPS proxy, stateless beyond owner + proxy slots, like `SwapLpFeeRouter`: the destination is an
///         immutable of the implementation, so repointing it is a new impl + `upgradeTo`.
contract RealmTreasuryRouter is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice Contract version.
    uint256 public constant VERSION = 2;

    using SafeERC20 for IERC20;

    /// @notice The treasury multisig. Gets everything.
    address public immutable TREASURY;

    /// @dev DEPRECATED (v1 `conversionRoute`, used by the removed `convert`). Kept so the storage layout
    ///      of the live proxy does not shift. Never read or written.
    mapping(address asset => bytes) private __deprecated_conversionRoute;

    /// @notice Emitted on every deposit. `votingShare` is always 0 since v2 (kept for the indexer ABI).
    event TreasuryEthRouted(address indexed from, uint256 votingShare, uint256 treasuryShare);

    /// @notice Emitted when an ERC20 balance that accumulated here is forwarded to the multisig.
    event TreasuryAssetSwept(address indexed asset, uint256 amount);

    error TreasuryTransferFailed();
    error InvalidAddress();
    /// @notice Thrown when `sweep` is handed `address(0)`; native arrives through `receive` and is forwarded
    ///         on arrival, so there is never a native balance here to sweep.
    error InvalidAsset();

    constructor(address treasury_) {
        require(treasury_ != address(0), InvalidAddress());
        TREASURY = treasury_;
        _disableInitializers();
    }

    /// @notice One-shot initializer for the proxy. Sets `msg.sender` as the initial owner.
    /// @dev Must be called atomically with proxy deployment (via `ERC1967Proxy`'s constructor init-data).
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @dev On the hot path of every trade: the launchpad and graduators require their treasury push to
    ///      succeed, so only the multisig rejecting native reverts.
    receive() external payable {
        (bool ok,) = TREASURY.call{value: msg.value}("");
        require(ok, TreasuryTransferFailed());
        emit TreasuryEthRouted(msg.sender, 0, msg.value);
    }

    /// @notice Forwards this contract's whole balance of `asset` to the treasury multisig.
    /// @dev An ERC20 cannot be forwarded on arrival the way native is — there is no hook to run when one
    ///      lands — so a pool quoted in an ERC20 pays its treasury slice into this contract and it sits here
    ///      until someone calls this. Permissionless: the destination is an immutable, so a caller can only
    ///      pay gas to move the treasury's own funds to the treasury.
    function sweep(address asset) external {
        require(asset != address(0), InvalidAsset());
        uint256 amount = IERC20(asset).balanceOf(address(this));
        if (amount == 0) return;
        IERC20(asset).safeTransfer(TREASURY, amount);
        emit TreasuryAssetSwept(asset, amount);
    }

    /// @dev Reserved for future storage variables. Decrement when adding new storage.
    uint256[49] private __gap;
}
