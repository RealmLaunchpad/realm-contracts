// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {RealmVoting} from "src/voting/RealmVoting.sol";

contract MockRealm is ERC20, ERC20Burnable {
    constructor() ERC20("Realm", "REALM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RealmVotingTests is Test {
    event RoundStarted(uint256 indexed roundId, uint256 startTime, uint256 endTime);
    event Voted(uint256 indexed roundId, address indexed token, address indexed voter, uint256 amount);
    event EthAllocated(uint256 indexed roundId, address indexed from, uint256 amount);
    event WinnerProcessed(uint256 indexed roundId, address indexed winner, uint256 amount, address to);
    event RoundDurationSet(uint256 duration, uint256 fromRoundId);

    uint256 constant DURATION = 3 days;

    RealmVoting voting;
    MockRealm realm;
    address owner = makeAddr("owner");
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address tokenA = makeAddr("tokenA");
    address tokenB = makeAddr("tokenB");
    address offPlatform = makeAddr("offPlatform");
    uint256 t0;

    function setUp() public {
        t0 = 1_000_000;
        vm.warp(t0);
        realm = new MockRealm();

        vm.startPrank(owner);
        RealmVoting impl = new RealmVoting(address(realm));
        vm.expectEmit(true, false, false, true);
        emit RoundStarted(1, t0, t0 + DURATION);
        voting = RealmVoting(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RealmVoting.initialize, (DURATION)))))
        );
        voting.setAdmin(admin, true);
        vm.stopPrank();

        for (uint256 i; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            realm.mint(who, 1_000e18);
            vm.prank(who);
            realm.approve(address(voting), type(uint256).max);
        }
    }

    function _vote(address who, address token, uint256 amount) internal {
        vm.prank(who);
        voting.vote(token, amount);
    }

    function _fund(uint256 amount) internal {
        deal(address(this), amount);
        (bool ok,) = address(voting).call{value: amount}("");
        assertTrue(ok);
    }

    function _round(uint256 id) internal view returns (RealmVoting.Round memory r) {
        (r.startTime, r.endTime, r.winner, r.winnerVotes, r.ethCollected, r.ethWithdrawn) = voting.rounds(id);
    }

    // ───────────────────────── init ─────────────────────────

    function test_init_roundOneLive() public view {
        (uint256 id, uint256 start, uint256 end) = voting.currentRound();
        assertEq(id, 1);
        assertEq(start, t0);
        assertEq(end, t0 + DURATION);
        assertEq(voting.lastSyncedRound(), 1);
        assertEq(voting.owner(), owner);
    }

    // ───────────────────────── vote ─────────────────────────

    function test_vote_burnsAndCounts() public {
        uint256 supply = realm.totalSupply();
        vm.expectEmit(true, true, true, true);
        emit Voted(1, tokenA, alice, 100e18);
        _vote(alice, tokenA, 100e18);
        assertEq(realm.totalSupply(), supply - 100e18, "burned");
        assertEq(realm.balanceOf(alice), 900e18);
        assertEq(voting.votes(1, tokenA), 100e18);
        assertEq(_round(1).winner, tokenA);
        assertEq(_round(1).winnerVotes, 100e18);
    }

    function test_vote_anyAddress_onlyZeroAmountRejected() public {
        _vote(alice, offPlatform, 1); // no launchpad check: any address is a valid candidate
        assertEq(_round(1).winner, offPlatform);
        vm.expectRevert(RealmVoting.InvalidAmount.selector);
        _vote(alice, tokenA, 0);
    }

    function test_vote_leaderOnlyOnStrictlyMore() public {
        _vote(alice, tokenA, 100e18);
        _vote(bob, tokenB, 100e18);
        assertEq(_round(1).winner, tokenA, "tie keeps the earlier leader");
        _vote(bob, tokenB, 1);
        assertEq(_round(1).winner, tokenB);
        assertEq(_round(1).winnerVotes, 100e18 + 1);
    }

    // ───────────────────────── native ─────────────────────────

    function test_receive_allocatesToLiveRound() public {
        vm.expectEmit(true, true, false, true);
        emit EthAllocated(1, address(this), 3 ether);
        _fund(3 ether);
        assertEq(_round(1).ethCollected, 3 ether);
    }

    // ───────────────────────── rounds are time-derived ─────────────────────────

    function test_rounds_viewAheadOfStorage_syncAnnouncesSkipped() public {
        vm.warp(t0 + 2 * DURATION + 1); // two boundaries crossed, nobody touched the contract
        (uint256 id, uint256 start, uint256 end) = voting.currentRound();
        assertEq(id, 3, "view shows n even though storage shows n-2");
        assertEq(start, t0 + 2 * DURATION);
        assertEq(end, t0 + 3 * DURATION);
        assertEq(voting.lastSyncedRound(), 1);
        assertEq(_round(3).startTime, 0, "untouched round has no storage");

        vm.expectEmit(true, false, false, true);
        emit RoundStarted(2, t0 + DURATION, t0 + 2 * DURATION);
        vm.expectEmit(true, false, false, true);
        emit RoundStarted(3, start, end);
        _fund(1 ether);
        assertEq(voting.lastSyncedRound(), 3);
        assertEq(_round(3).startTime, start);
        assertEq(_round(3).endTime, end);
        assertEq(_round(3).ethCollected, 1 ether, "native lands in the live round");
        assertEq(_round(2).ethCollected, 0);

        _vote(alice, tokenA, 5e18);
        assertEq(voting.votes(3, tokenA), 5e18, "votes land in the live round");
        assertEq(voting.votes(1, tokenA), 0);
    }

    function test_nextRound_onlyAtBoundary() public {
        vm.expectRevert(RealmVoting.RoundNotEnded.selector);
        voting.nextRound();
        vm.warp(t0 + DURATION);
        vm.expectEmit(true, false, false, true);
        emit RoundStarted(2, t0 + DURATION, t0 + 2 * DURATION);
        voting.nextRound();
        assertEq(voting.lastSyncedRound(), 2);
    }

    // ───────────────────────── processWinner ─────────────────────────

    function test_processWinner_progressivePulls() public {
        _vote(alice, tokenA, 1e18);
        _fund(10 ether);
        vm.expectRevert(RealmVoting.RoundNotEnded.selector);
        vm.prank(admin);
        voting.processWinner(1, 1 ether);

        vm.warp(t0 + DURATION);
        vm.expectEmit(true, true, false, true);
        emit WinnerProcessed(1, tokenA, 4 ether, admin);
        vm.prank(admin);
        voting.processWinner(1, 4 ether);
        assertEq(admin.balance, 4 ether);
        assertEq(_round(1).ethWithdrawn, 4 ether);
        assertEq(_round(1).ethCollected, 10 ether, "collected is history, not a balance");

        vm.expectRevert(RealmVoting.InsufficientRoundEth.selector);
        vm.prank(admin);
        voting.processWinner(1, 6 ether + 1);

        vm.prank(owner); // owner acts as admin too
        voting.processWinner(1, 6 ether);
        assertEq(owner.balance, 6 ether);
        assertEq(address(voting).balance, 0);
    }

    function test_processWinner_onlyAdmin() public {
        vm.warp(t0 + DURATION);
        vm.expectRevert(RealmVoting.NotAdmin.selector);
        vm.prank(alice);
        voting.processWinner(1, 0);
    }

    function test_processWinner_noVotes_winnerIsZero() public {
        _fund(1 ether);
        vm.warp(t0 + DURATION);
        vm.expectEmit(true, true, false, true);
        emit WinnerProcessed(1, address(0), 1 ether, admin);
        vm.prank(admin);
        voting.processWinner(1, 1 ether);
    }

    // ───────────────────────── duration ─────────────────────────

    function test_setRoundDuration_appliesFromNextRound() public {
        vm.warp(t0 + 1 days);
        vm.expectEmit(false, false, false, true);
        emit RoundDurationSet(1 days, 2);
        vm.prank(owner);
        voting.setRoundDuration(1 days);

        (uint256 id,, uint256 end) = voting.currentRound();
        assertEq(id, 1, "live round unchanged");
        assertEq(end, t0 + DURATION, "live round keeps its end");

        vm.warp(t0 + DURATION);
        (id,, end) = voting.currentRound();
        assertEq(id, 2);
        assertEq(end, t0 + DURATION + 1 days, "next round uses the new duration");

        vm.warp(t0 + DURATION + 5 days);
        (id,,) = voting.currentRound();
        assertEq(id, 7);
    }

    function test_setRoundDuration_onlyOwner() public {
        vm.expectRevert();
        vm.prank(admin);
        voting.setRoundDuration(1 days);
    }

    // ───────────────────────── upgrades ─────────────────────────

    function test_upgrade_onlyOwner() public {
        RealmVoting newImpl = new RealmVoting(address(realm));
        vm.expectRevert();
        vm.prank(admin);
        voting.upgradeToAndCall(address(newImpl), "");
        vm.prank(owner);
        voting.upgradeToAndCall(address(newImpl), "");
    }
}
