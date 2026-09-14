// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RealmTreasuryRouter} from "src/treasury/RealmTreasuryRouter.sol";

contract RejectEth {
    receive() external payable {
        revert("rejected");
    }
}

contract Sink {
    uint256 public calls;

    receive() external payable {
        calls++;
    }
}

contract RealmTreasuryRouterTests is Test {
    event TreasuryEthRouted(address indexed from, uint256 votingShare, uint256 treasuryShare);

    RealmTreasuryRouter router;
    Sink treasury;
    Sink voting;
    address admin = makeAddr("admin");

    function setUp() public {
        treasury = new Sink();
        voting = new Sink();
        router = _deploy(address(treasury), address(voting));
    }

    function _deploy(address treasury_, address voting_) internal returns (RealmTreasuryRouter) {
        vm.startPrank(admin);
        RealmTreasuryRouter impl = new RealmTreasuryRouter(treasury_, voting_);
        RealmTreasuryRouter proxy = RealmTreasuryRouter(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RealmTreasuryRouter.initialize, ()))))
        );
        vm.stopPrank();
        return proxy;
    }

    function testFuzz_receive_oneThirdToVoting(uint96 value) public {
        deal(address(this), value);
        vm.expectEmit(true, false, false, true);
        emit TreasuryEthRouted(address(this), value / 3, value - value / 3);
        (bool ok,) = address(router).call{value: value}("");
        assertTrue(ok);
        assertEq(address(voting).balance, value / 3, "voting third");
        assertEq(address(treasury).balance, value - value / 3, "treasury rest");
        assertEq(address(router).balance, 0, "nothing stranded");
    }

    function test_receive_dust_skipsVotingCall() public {
        (bool ok,) = address(router).call{value: 2}("");
        assertTrue(ok);
        assertEq(voting.calls(), 0);
        assertEq(address(treasury).balance, 2);
    }

    function test_receive_votingRejects_fallsBackToTreasury() public {
        router = _deploy(address(treasury), address(new RejectEth()));
        vm.expectEmit(true, false, false, true);
        emit TreasuryEthRouted(address(this), 0, 9 ether);
        (bool ok,) = address(router).call{value: 9 ether}("");
        assertTrue(ok);
        assertEq(address(treasury).balance, 9 ether);
    }

    function test_receive_treasuryRejects_reverts() public {
        router = _deploy(address(new RejectEth()), address(voting));
        vm.expectRevert(RealmTreasuryRouter.TreasuryTransferFailed.selector);
        (bool ok,) = address(router).call{value: 9 ether}("");
        ok; // expectRevert consumes the revert of the low-level call
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(RealmTreasuryRouter.InvalidAddress.selector);
        new RealmTreasuryRouter(address(0), address(voting));
        vm.expectRevert(RealmTreasuryRouter.InvalidAddress.selector);
        new RealmTreasuryRouter(address(treasury), address(0));
    }

    function test_upgrade_onlyOwner() public {
        RealmTreasuryRouter newImpl = new RealmTreasuryRouter(address(treasury), address(voting));
        vm.expectRevert();
        router.upgradeToAndCall(address(newImpl), "");
        vm.prank(admin);
        router.upgradeToAndCall(address(newImpl), "");
    }
}
