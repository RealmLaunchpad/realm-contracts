// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RealmTreasuryRouter} from "src/treasury/RealmTreasuryRouter.sol";
import {RealmKeepersRegistry} from "src/access/RealmKeepersRegistry.sol";
import {DeploymentAddressesEthereumMainnet as Mainnet} from "src/config/DeploymentAddresses.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PathKey} from "lib/v4-periphery/src/libraries/PathKey.sol";

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
    // Unit suite: no swap happens here, so the venue and keeper addresses only need to be non-zero.
    address constant UR = address(0x1001);
    address constant P2 = address(0x1002);
    address constant KEEPERS = address(0x1003);

    function setUp() public {
        treasury = new Sink();
        voting = new Sink();
        router = _deploy(address(treasury), address(voting));
    }

    function _deploy(address treasury_, address voting_) internal returns (RealmTreasuryRouter) {
        vm.startPrank(admin);
        RealmTreasuryRouter impl = new RealmTreasuryRouter(treasury_, voting_, UR, P2, KEEPERS);
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
        new RealmTreasuryRouter(address(0), address(voting), UR, P2, KEEPERS);
        vm.expectRevert(RealmTreasuryRouter.InvalidAddress.selector);
        new RealmTreasuryRouter(address(treasury), address(0), UR, P2, KEEPERS);
        vm.expectRevert(RealmTreasuryRouter.InvalidAddress.selector);
        new RealmTreasuryRouter(address(treasury), address(voting), UR, P2, address(0));
    }

    function test_upgrade_onlyOwner() public {
        RealmTreasuryRouter newImpl = new RealmTreasuryRouter(address(treasury), address(voting), UR, P2, KEEPERS);
        vm.expectRevert();
        router.upgradeToAndCall(address(newImpl), "");
        vm.prank(admin);
        router.upgradeToAndCall(address(newImpl), "");
    }
}

/// @notice `convert` against real mainnet liquidity: USDC sold for ETH on the V4 USDC/ETH 0.05% pool.
contract RealmTreasuryRouterConvertTests is Test {
    event TreasuryEthRouted(address indexed from, uint256 votingShare, uint256 treasuryShare);

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant BLOCKNUMBER = 23327777;

    RealmTreasuryRouter router;
    Sink treasury;
    Sink voting;
    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), BLOCKNUMBER);
        treasury = new Sink();
        voting = new Sink();
        RealmKeepersRegistry keepers = new RealmKeepersRegistry(admin);
        vm.startPrank(admin);
        keepers.setKeeper(keeper, true);
        RealmTreasuryRouter impl = new RealmTreasuryRouter(
            address(treasury), address(voting), Mainnet.UNIV4_UNIVERSAL_ROUTER, Mainnet.PERMIT2, address(keepers)
        );
        router = RealmTreasuryRouter(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RealmTreasuryRouter.initialize, ()))))
        );
        router.setConversionRoute(USDC, _usdcToNative());
        vm.stopPrank();
        deal(USDC, address(router), 1_000e6);
    }

    function _usdcToNative() internal pure returns (PathKey[] memory path) {
        path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(0)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0)),
            hookData: ""
        });
    }

    // Balances are compared as deltas: on a mainnet fork, the addresses a test deploys to can already
    // hold dust ETH sent to them in the wild.
    function test_convert_sellsTheAssetAndRoutesTheNative() public {
        uint256 votingBefore = address(voting).balance;
        uint256 treasuryBefore = address(treasury).balance;
        uint256 routerBefore = address(router).balance;
        vm.prank(keeper);
        uint256 out = router.convert(USDC, 1_000e6, 0.01 ether);

        assertGt(out, 0.01 ether, "native received");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "asset sold");
        assertEq(address(voting).balance - votingBefore, out / 3, "voting third");
        assertEq(address(treasury).balance - treasuryBefore, out - out / 3, "treasury rest");
        assertEq(address(router).balance, routerBefore, "nothing stranded");
    }

    function test_convert_reportsTheSaleThenRoutesAsTheRouterItself() public {
        uint256 routedBefore = address(voting).balance + address(treasury).balance;
        vm.recordLogs();
        vm.prank(keeper);
        uint256 out = router.convert(USDC, 400e6, 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool converted;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router)) continue;
            if (logs[i].topics[0] == RealmTreasuryRouter.TreasuryAssetConverted.selector) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(USDC))));
                (uint256 amountIn, uint256 nativeOut) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(amountIn, 400e6);
                assertEq(nativeOut, out);
                converted = true;
            } else if (logs[i].topics[0] == TreasuryEthRouted.selector) {
                assertTrue(converted, "the sale is reported before its routing");
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(router)))));
            }
        }
        assertTrue(converted);
        assertEq(address(voting).balance + address(treasury).balance - routedBefore, out);
    }

    function test_convert_onlyKeepers() public {
        vm.expectRevert(RealmTreasuryRouter.NotAKeeper.selector);
        router.convert(USDC, 1_000e6, 0);
    }

    function test_convert_missedFloorRevertsAndKeepsTheAsset() public {
        vm.prank(keeper);
        vm.expectRevert(RealmTreasuryRouter.ConversionFailed.selector);
        router.convert(USDC, 1_000e6, 1_000 ether);
        assertEq(IERC20(USDC).balanceOf(address(router)), 1_000e6);
    }

    function test_convert_refusesAnAssetWithoutARoute() public {
        vm.prank(keeper);
        vm.expectRevert(RealmTreasuryRouter.InvalidRoute.selector);
        router.convert(makeAddr("noRoute"), 1, 0);
    }

    function test_setConversionRoute_onlyOwnerAndMustEndInNative() public {
        vm.expectRevert();
        router.setConversionRoute(USDC, _usdcToNative());

        PathKey[] memory toUsdt = _usdcToNative();
        toUsdt[0].intermediateCurrency = Currency.wrap(makeAddr("notNative"));
        vm.prank(admin);
        vm.expectRevert(RealmTreasuryRouter.InvalidRoute.selector);
        router.setConversionRoute(USDC, toUsdt);
    }
}
