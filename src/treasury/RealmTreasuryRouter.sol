// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RealmTreasuryRouter
/// @notice The address every protocol contract pushes treasury native to (launchpad trading fees, graduation
///         fees, the LP fee router's treasury slice). Forwards 1/3 to `RealmVoting` — the slice the REALM
///         vote spends on the winning token — and the rest to the treasury multisig. Putting this proxy in
///         front of the multisig is what lets the treasury policy change later without touching the systems
///         that pay it.
/// @dev    UUPS proxy, stateless beyond owner + proxy slots, like `SwapLpFeeRouter`: the two destinations are
///         immutables of the implementation, so repointing either is a new impl + `upgradeTo`.
contract RealmTreasuryRouter is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice The treasury multisig. Gets everything the voting contract does not.
    address public immutable TREASURY;
    /// @notice `RealmVoting`. Gets 1/3 of every deposit, earmarked for the round it arrives in.
    address public immutable VOTING;

    /// @notice Emitted on every deposit. `votingShare` is 0 when the voting call failed (see `receive`).
    event TreasuryEthRouted(address indexed from, uint256 votingShare, uint256 treasuryShare);

    /// @notice Emitted when an ERC20 balance that accumulated here is forwarded to the multisig.
    event TreasuryAssetSwept(address indexed asset, uint256 amount);

    error TreasuryTransferFailed();
    error InvalidAddress();
    /// @notice Thrown when `sweep` is handed `address(0)`; native arrives through `receive` and is
    ///         routed on arrival, so there is never a native balance here to sweep.
    error InvalidAsset();

    constructor(address treasury_, address voting_) {
        require(treasury_ != address(0) && voting_ != address(0), InvalidAddress());
        TREASURY = treasury_;
        VOTING = voting_;
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
    ///      succeed, so a voting contract that rejects native must not brick trading. Its share falls back
    ///      to the multisig; only the multisig rejecting native reverts, exactly as today.
    receive() external payable {
        uint256 votingShare = msg.value / 3;
        if (votingShare > 0) {
            (bool sent,) = VOTING.call{value: votingShare}("");
            if (!sent) votingShare = 0;
        }
        uint256 treasuryShare = msg.value - votingShare;
        (bool ok,) = TREASURY.call{value: treasuryShare}("");
        require(ok, TreasuryTransferFailed());
        emit TreasuryEthRouted(msg.sender, votingShare, treasuryShare);
    }

    /// @notice Forwards this contract's whole balance of `asset` to the treasury multisig.
    /// @dev An ERC20 cannot be routed on arrival the way native is — there is no hook to run when one
    ///      lands — so a pool quoted in an ERC20 pays its treasury slice into this contract and it sits
    ///      here until someone calls this. The whole balance goes to the MULTISIG: the REALM vote spends
    ///      native and only native, so splitting an arbitrary quote into it would hand the vote a
    ///      currency it cannot use.
    /// @dev Owner-gated, though the destination is an immutable and there is nothing for a caller to
    ///      gain: the treasury decides when its own balances move, and an ungated sweep is a stream of
    ///      transfers the multisig never asked for.
    function sweep(address asset) external onlyOwner {
        require(asset != address(0), InvalidAsset());
        uint256 amount = IERC20(asset).balanceOf(address(this));
        if (amount == 0) return;
        IERC20(asset).safeTransfer(TREASURY, amount);
        emit TreasuryAssetSwept(asset, amount);
    }

    /// @dev Reserved for future storage variables. Decrement when adding new storage.
    uint256[50] private __gap;
}
