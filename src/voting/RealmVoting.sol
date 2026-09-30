// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Burnable} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title RealmVoting
/// @notice Burn REALM to vote for a token; each round's native (1/3 of treasury earnings, forwarded by
///         `RealmTreasuryRouter`) is spent buying that round's winner.
///
/// @dev ROUNDS ARE DERIVED FROM THE CLOCK, NOT FROM A COUNTER. Rounds are contiguous and fixed-length:
///      round `id` spans `[anchorTime + (id - anchorId) * roundDuration, + roundDuration)`, so the live
///      round (`currentRound()`) never waits on a keeper. Storage catches up lazily: the first `vote`,
///      native deposit or `nextRound()` after a boundary writes the live round's times and emits
///      `RoundStarted` for it and for every round skipped in between. A round nobody touched has no
///      storage and nothing to process.
///
/// @dev WINNER. The address with the most votes; a strictly greater total replaces the leader, so a tie keeps
///      the earlier one. ANY address can be voted for — no launchpad check, so a future launchpad or an
///      off-platform coin qualifies. A vote for something unbuyable only costs the voter their REALM: the
///      admin doing the manual swap simply decides what to do with that round's native. A round with no votes has `winner == address(0)`; its native is still pullable, and
///      what to do with it is the admin's call.
///
/// @dev SWAPS ARE MANUAL. `processWinner` hands native to the calling admin, in as many slices as it likes,
///      who buys the winner off-chain-decided venues. Purchases are attributed by watching that wallet.
contract RealmVoting is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    struct Round {
        uint40 startTime;
        uint40 endTime;
        address winner;
        uint256 winnerVotes;
        uint256 ethCollected;
        uint256 ethWithdrawn;
    }

    /// @notice The token burned to vote.
    ERC20Burnable public immutable REALM;

    /// @notice Length of every round from `anchorId` on.
    uint256 public roundDuration;
    /// @notice Schedule anchor: round `anchorId` starts at `anchorTime`. Moved by `setRoundDuration`.
    uint256 public anchorId;
    uint256 public anchorTime;
    /// @notice Last round written to storage. The live round is `currentRound()`, which may be ahead.
    uint256 public lastSyncedRound;
    /// @notice Per-round state. Empty for rounds nobody touched.
    mapping(uint256 roundId => Round) public rounds;
    /// @notice REALM burned for `token` in `roundId`; 1 wei burned = 1 vote.
    mapping(uint256 roundId => mapping(address token => uint256)) public votes;
    /// @notice Ops keys that pull round funds. The owner (cold) manages them and may act as one.
    mapping(address account => bool) public isAdmin;

    event RoundStarted(uint256 indexed roundId, uint256 startTime, uint256 endTime);
    event Voted(uint256 indexed roundId, address indexed token, address indexed voter, uint256 amount);
    event EthAllocated(uint256 indexed roundId, address indexed from, uint256 amount);
    event WinnerProcessed(uint256 indexed roundId, address indexed winner, uint256 amount, address to);
    /// @notice `fromRoundId` is the first round the new duration applies to.
    event RoundDurationSet(uint256 duration, uint256 fromRoundId);
    event AdminSet(address indexed account, bool allowed);

    error NotAdmin();
    error InvalidAmount();
    error RoundNotEnded();
    error InsufficientRoundEth();
    error EthTransferFailed();

    modifier onlyAdmin() {
        require(isAdmin[msg.sender] || msg.sender == owner(), NotAdmin());
        _;
    }

    constructor(address realm_) {
        REALM = ERC20Burnable(realm_);
        _disableInitializers();
    }

    /// @notice One-shot initializer for the proxy: `msg.sender` becomes owner and round 1 starts now.
    /// @dev Must be called atomically with proxy deployment (via `ERC1967Proxy`'s constructor init-data).
    function initialize(uint256 roundDuration_) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        require(roundDuration_ > 0, InvalidAmount());
        roundDuration = roundDuration_;
        anchorId = 1;
        anchorTime = block.timestamp;
        emit RoundDurationSet(roundDuration_, 1);
        _sync();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Burns `amount` REALM from the caller (needs allowance) as `amount` votes for `token` in the
    ///         live round.
    function vote(address token, uint256 amount) external {
        require(amount > 0, InvalidAmount());
        uint256 id = _sync();
        REALM.burnFrom(msg.sender, amount);
        uint256 total = votes[id][token] += amount;
        Round storage round = rounds[id];
        if (total > round.winnerVotes) (round.winner, round.winnerVotes) = (token, total);
        emit Voted(id, token, msg.sender, amount);
    }

    /// @notice Native is earmarked for the round it arrives in.
    receive() external payable {
        uint256 id = _sync();
        rounds[id].ethCollected += msg.value;
        emit EthAllocated(id, msg.sender, msg.value);
    }

    /// @notice Rolls storage forward to the live round. Permissionless; `vote` and `receive` roll on their
    ///         own, this exists so a keeper can publish `RoundStarted` right at the boundary. Reverts when
    ///         there is nothing to roll so a misfiring keeper is visible.
    function nextRound() external {
        uint256 before = lastSyncedRound;
        require(_sync() > before, RoundNotEnded());
    }

    /// @notice Pulls `amount` of an ended round's native to the caller, who buys the winner manually.
    function processWinner(uint256 roundId, uint256 amount) external onlyAdmin {
        require(roundId < _currentId(), RoundNotEnded());
        Round storage round = rounds[roundId];
        require(amount <= round.ethCollected - round.ethWithdrawn, InsufficientRoundEth());
        round.ethWithdrawn += amount;
        emit WinnerProcessed(roundId, round.winner, amount, msg.sender);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, EthTransferFailed());
    }

    /// @notice Applies from the NEXT round: the live round keeps the end it was announced with.
    function setRoundDuration(uint256 duration) external onlyOwner {
        require(duration > 0, InvalidAmount());
        uint256 id = _sync();
        anchorId = id + 1;
        anchorTime = rounds[id].endTime;
        roundDuration = duration;
        emit RoundDurationSet(duration, id + 1);
    }

    function setAdmin(address account, bool allowed) external onlyOwner {
        isAdmin[account] = allowed;
        emit AdminSet(account, allowed);
    }

    /// @notice The live round, derived from the clock. May be ahead of `lastSyncedRound`, in which case
    ///         `rounds(id)` is still empty.
    function currentRound() external view returns (uint256 id, uint256 startTime, uint256 endTime) {
        id = _currentId();
        (startTime, endTime) = _roundTimes(id);
    }

    function _currentId() internal view returns (uint256) {
        // Between `setRoundDuration` and the boundary it re-anchored at, the live round is the pre-anchor one.
        if (block.timestamp < anchorTime) return anchorId - 1;
        return anchorId + (block.timestamp - anchorTime) / roundDuration;
    }

    function _roundTimes(uint256 id) internal view returns (uint256 startTime, uint256 endTime) {
        // Pre-anchor rounds ran on an older duration; the only one ever asked for is stored.
        if (id < anchorId) return (rounds[id].startTime, rounds[id].endTime);
        startTime = anchorTime + (id - anchorId) * roundDuration;
        endTime = startTime + roundDuration;
    }

    /// @dev Writes the live round's times if storage is behind, announcing every round skipped in between.
    function _sync() internal returns (uint256 id) {
        id = _currentId();
        uint256 synced = lastSyncedRound;
        if (id == synced) return id;
        // ponytail: one log per skipped round, unbounded by design — ~1.5k gas each, a year idle at
        // 3-day rounds is ~180k. Only the live round gets storage.
        for (uint256 k = synced + 1; k < id; k++) {
            (uint256 s, uint256 e) = _roundTimes(k);
            emit RoundStarted(k, s, e);
        }
        (uint256 start, uint256 end) = _roundTimes(id);
        // Safe cast: timestamps fit uint40 for millennia.
        // forge-lint: disable-next-line(unsafe-typecast)
        rounds[id].startTime = uint40(start);
        // forge-lint: disable-next-line(unsafe-typecast)
        rounds[id].endTime = uint40(end);
        lastSyncedRound = id;
        emit RoundStarted(id, start, end);
    }

    /// @dev Reserved for future storage variables. Decrement when adding new storage.
    uint256[50] private __gap;
}
