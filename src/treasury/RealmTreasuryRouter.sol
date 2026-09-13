// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title RealmTreasuryRouter
/// @notice The address every protocol contract pushes treasury native to (launchpad trading fees, graduation
///         fees, the LP fee router's treasury slice). Forwards 1/3 to `RealmVoting` — the slice the REALM
///         vote spends on the winning token — and the rest to the treasury multisig. Putting this proxy in
///         front of the multisig is what lets the treasury policy change later without touching the systems
///         that pay it.
/// @dev    UUPS proxy, stateless beyond owner + proxy slots, like `SwapLpFeeRouter`: the two destinations are
///         immutables of the implementation, so repointing either is a new impl + `upgradeTo`.
contract RealmTreasuryRouter is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice The treasury multisig. Gets everything the voting contract does not.
    address public immutable TREASURY;
    /// @notice `RealmVoting`. Gets 1/3 of every deposit, earmarked for the round it arrives in.
    address public immutable VOTING;

    /// @notice Emitted on every deposit. `votingShare` is 0 when the voting call failed (see `receive`).
    event TreasuryEthRouted(address indexed from, uint256 votingShare, uint256 treasuryShare);

    error TreasuryTransferFailed();
    error InvalidAddress();

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

    /// @dev Reserved for future storage variables. Decrement when adding new storage.
    uint256[50] private __gap;
}
