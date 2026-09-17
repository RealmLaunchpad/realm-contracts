// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RealmMasterFeeHandler} from "src/feeHandlers/RealmMasterFeeHandler.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {DeploymentAddressesEthereumMainnet as Mainnet} from "src/config/DeploymentAddresses.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PathKey} from "lib/v4-periphery/src/libraries/PathKey.sol";
import {MockMasterFeeToken} from "test/helpers/MasterFeeHandlerTestHelpers.sol";

/// @dev The token double, able to pay its fees in an ERC20 as a real token's `accrueFees(asset, amount)` does.
contract MockAssetFeeToken is MockMasterFeeToken {
    constructor(RealmMasterFeeHandler handler_) MockMasterFeeToken(handler_, address(0)) {}

    function accrueFees(address asset, uint256 amount) external {
        IERC20(asset).approve(address(feeHandler), amount);
        feeHandler.depositFees(address(this), asset, amount);
    }
}

/// @notice `claimAsNative` against real mainnet liquidity: fees earned in USDC, sold for ETH on the V4
///         USDC/ETH 0.05% pool, paid out as native.
contract RealmMasterFeeHandlerClaimAsNativeTests is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant BLOCKNUMBER = 23327777;

    RealmMasterFeeHandler handler;
    MockAssetFeeToken tokenA;
    MockAssetFeeToken tokenB;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), BLOCKNUMBER);
        handler = new RealmMasterFeeHandler(Mainnet.UNIV4_UNIVERSAL_ROUTER, Mainnet.PERMIT2);
        tokenA = _earning(alice, 1_000e6);
        tokenB = _earning(bob, 1_000e6);
    }

    /// @dev A token whose whole fee stream belongs to `recipient`, with `amount` USDC already deposited.
    function _earning(address recipient, uint256 amount) internal returns (MockAssetFeeToken token) {
        token = new MockAssetFeeToken(handler);
        IRealmFactory.FeeShare[] memory shares = new IRealmFactory.FeeShare[](1);
        shares[0] = IRealmFactory.FeeShare({account: recipient, shares: 10_000, directFeesEnabled: false});
        token.registerFees(shares);
        deal(USDC, address(token), amount);
        token.accrueFees(USDC, amount);
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

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    // The handler's own balance is compared as a delta: on a mainnet fork, the address a test deploys
    // to can already hold dust ETH sent to it in the wild.
    function test_claimAsNative_paysNativeAndClosesTheAssetLedger() public {
        uint256 handlerBefore = address(handler).balance;
        vm.expectEmit(address(handler));
        emit IRealmMasterFeeHandler.CreatorAssetClaimed(address(tokenA), USDC, alice, 1_000e6);
        vm.prank(alice);
        uint256 out = handler.claimAsNative(_one(address(tokenA)), USDC, _usdcToNative(), 0.01 ether);

        assertGt(out, 0.01 ether, "native received");
        assertEq(alice.balance, out, "paid to the claimer");
        assertEq(IERC20(USDC).balanceOf(alice), 0, "the asset itself is never delivered");
        assertEq(handler.getClaimable(_one(address(tokenA)), USDC, alice)[0], 0, "asset ledger closed");
        assertEq(address(handler).balance, handlerBefore, "no native left behind");
    }

    /// @dev The handler holds every creator's balance: a claim may only ever sell its own.
    function test_claimAsNative_leavesOtherCreatorsUntouched() public {
        vm.prank(alice);
        handler.claimAsNative(_one(address(tokenA)), USDC, _usdcToNative(), 1);

        assertEq(IERC20(USDC).balanceOf(address(handler)), 1_000e6, "bob's USDC still held");
        vm.prank(bob);
        handler.claim(_one(address(tokenB)), USDC);
        assertEq(IERC20(USDC).balanceOf(bob), 1_000e6, "and still claimable in full");
    }

    function test_claimAsNative_missedFloorRevertsAndKeepsTheClaim() public {
        vm.prank(alice);
        vm.expectRevert(IRealmMasterFeeHandler.NativeConversionFailed.selector);
        handler.claimAsNative(_one(address(tokenA)), USDC, _usdcToNative(), 1_000 ether);

        assertEq(handler.getClaimable(_one(address(tokenA)), USDC, alice)[0], 1_000e6, "claim intact");
    }

    function test_claimAsNative_nothingClaimableIsANoop() public {
        vm.prank(bob);
        assertEq(handler.claimAsNative(_one(address(tokenA)), USDC, _usdcToNative(), 0), 0);
    }

    function test_receive_refusesNativeOutsideAClaim() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(handler).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
