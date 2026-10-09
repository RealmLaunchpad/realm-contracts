// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RealmTreasuryRouter} from "src/treasury/RealmTreasuryRouter.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract RejectEth {
    receive() external payable {
        revert("rejected");
    }
}

contract Sink {
    receive() external payable {}
}

contract SweepAsset is ERC20 {
    constructor() ERC20("Sweep", "SWP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RealmTreasuryRouterTests is Test {
    event TreasuryEthRouted(address indexed from, uint256 votingShare, uint256 treasuryShare);

    RealmTreasuryRouter router;
    Sink treasury;
    address admin = makeAddr("admin");

    function setUp() public {
        treasury = new Sink();
        router = _deploy(address(treasury));
    }

    function _deploy(address treasury_) internal returns (RealmTreasuryRouter) {
        vm.startPrank(admin);
        RealmTreasuryRouter impl = new RealmTreasuryRouter(treasury_);
        RealmTreasuryRouter proxy = RealmTreasuryRouter(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RealmTreasuryRouter.initialize, ()))))
        );
        vm.stopPrank();
        return proxy;
    }

    function testFuzz_receive_everythingToTreasury(uint96 value) public {
        deal(address(this), value);
        vm.expectEmit(true, false, false, true);
        emit TreasuryEthRouted(address(this), 0, value);
        (bool ok,) = address(router).call{value: value}("");
        assertTrue(ok);
        assertEq(address(treasury).balance, value, "treasury got everything");
        assertEq(address(router).balance, 0, "nothing stranded");
    }

    function test_receive_treasuryRejects_reverts() public {
        router = _deploy(address(new RejectEth()));
        vm.expectRevert(RealmTreasuryRouter.TreasuryTransferFailed.selector);
        (bool ok,) = address(router).call{value: 9 ether}("");
        ok; // expectRevert consumes the revert of the low-level call
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(RealmTreasuryRouter.InvalidAddress.selector);
        new RealmTreasuryRouter(address(0));
    }

    function test_upgrade_onlyOwner() public {
        RealmTreasuryRouter newImpl = new RealmTreasuryRouter(address(treasury));
        vm.expectRevert();
        router.upgradeToAndCall(address(newImpl), "");
        vm.prank(admin);
        router.upgradeToAndCall(address(newImpl), "");
    }

    /// @dev Native is forwarded on arrival, so the native sentinel is not sweepable.
    function test_sweep_rejectsNativeSentinel() public {
        vm.expectRevert(RealmTreasuryRouter.InvalidAsset.selector);
        router.sweep(address(0));
    }

    /// @dev Anyone can sweep; the whole balance goes to the multisig.
    function test_sweep_permissionless_sendsWholeBalanceToTreasury() public {
        SweepAsset asset = new SweepAsset();
        asset.mint(address(router), 100e18);
        vm.expectEmit(address(router));
        emit RealmTreasuryRouter.TreasuryAssetSwept(address(asset), 100e18);
        vm.prank(makeAddr("anyone"));
        router.sweep(address(asset));
        assertEq(asset.balanceOf(address(treasury)), 100e18, "treasury got everything");
        assertEq(asset.balanceOf(address(router)), 0, "nothing left");
    }

    /// @dev A zero balance transfers nothing and emits nothing.
    function test_sweep_zeroBalanceIsANoop() public {
        SweepAsset asset = new SweepAsset();
        vm.expectCall(address(asset), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        vm.recordLogs();
        router.sweep(address(asset));
        assertEq(vm.getRecordedLogs().length, 0, "no event");
    }
}
