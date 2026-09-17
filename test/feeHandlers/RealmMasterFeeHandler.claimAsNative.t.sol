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
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @dev An ERC20 with no market but the thin native pool a test gives it.
contract ThinAsset is ERC20 {
    constructor() ERC20("Thin", "THIN") {}
}

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

    /// @dev Refunds of the ETH `_thinPool` overpays for its position.
    receive() external payable {}

    /// @dev A token whose whole fee stream belongs to `recipient`, with `amount` USDC already deposited.
    function _earning(address recipient, uint256 amount) internal returns (MockAssetFeeToken token) {
        return _earningIn(USDC, recipient, amount);
    }

    /// @dev `_earning`, in any `asset`.
    function _earningIn(address asset, address recipient, uint256 amount) internal returns (MockAssetFeeToken token) {
        token = new MockAssetFeeToken(handler);
        IRealmFactory.FeeShare[] memory shares = new IRealmFactory.FeeShare[](1);
        shares[0] = IRealmFactory.FeeShare({account: recipient, shares: 10_000, directFeesEnabled: false});
        token.registerFees(shares);
        deal(asset, address(token), amount);
        token.accrueFees(asset, amount);
    }

    /// @dev A fresh ERC20 whose only native pool (1:1, 0.3%) holds ~3e15 of each side in +/-60 ticks, so
    ///      any sale much larger than that runs out of liquidity. Returns the one-hop route to native.
    function _thinPool() internal returns (ThinAsset asset, PathKey[] memory path) {
        asset = new ThinAsset();
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(asset)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        IPoolManager manager = IPoolManager(Mainnet.UNIV4_POOL_MANAGER);
        manager.initialize(key, uint160(1 << 96));

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        deal(address(asset), address(this), 1e18);
        asset.approve(address(lp), type(uint256).max);
        vm.deal(address(this), 1 ether);
        lp.modifyLiquidity{value: 1 ether}(
            key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: 0}), ""
        );

        path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0)),
            hookData: ""
        });
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

    /// @dev Claims across several tokens are summed into ONE swap, paying exactly what a single claim of
    ///      the same total would at the same pool state.
    function test_claimAsNative_sumsAcrossTokensInOneSwap() public {
        MockAssetFeeToken tokenC = _earning(alice, 500e6);

        uint256 snapshot = vm.snapshotState();
        MockAssetFeeToken combined = _earning(bob, 1_500e6);
        vm.prank(bob);
        uint256 expectedOut = handler.claimAsNative(_one(address(combined)), USDC, _usdcToNative(), 1);
        vm.revertToState(snapshot);

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenC);
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(handler));

        vm.expectCall(Mainnet.UNIV4_UNIVERSAL_ROUTER, abi.encodeWithSelector(IUniversalRouter.execute.selector), 1);
        vm.expectEmit(address(handler));
        emit IRealmMasterFeeHandler.CreatorAssetClaimed(address(tokenA), USDC, alice, 1_000e6);
        vm.expectEmit(address(handler));
        emit IRealmMasterFeeHandler.CreatorAssetClaimed(address(tokenC), USDC, alice, 500e6);
        vm.expectEmit(address(handler));
        emit IRealmMasterFeeHandler.CreatorAssetConvertedToNative(alice, USDC, 1_500e6, expectedOut);
        vm.prank(alice);
        uint256 out = handler.claimAsNative(tokens, USDC, _usdcToNative(), 1);

        assertEq(out, expectedOut, "same as one claim of the sum");
        assertEq(alice.balance, out, "paid to the claimer");
        assertEq(usdcBefore - IERC20(USDC).balanceOf(address(handler)), 1_500e6, "exactly the sum sold");
        assertEq(IERC20(USDC).balanceOf(address(handler)), 1_000e6, "bob's USDC untouched");
        assertEq(handler.getClaimable(_one(address(tokenA)), USDC, alice)[0], 0, "ledger A closed");
        assertEq(handler.getClaimable(_one(address(tokenC)), USDC, alice)[0], 0, "ledger C closed");
    }

    /// @dev A pool too thin to absorb the whole claim fills partially; the full-fill guard reverts, so the
    ///      unsold remainder never lands unattributed in the handler and the claim stays intact.
    function test_claimAsNative_partialFillRevertsAndKeepsTheClaim() public {
        (ThinAsset thin, PathKey[] memory path) = _thinPool();
        MockAssetFeeToken token = _earningIn(address(thin), alice, 1e18); // ~300x the pool's depth

        vm.prank(alice);
        vm.expectRevert(IRealmMasterFeeHandler.NativeConversionFailed.selector);
        handler.claimAsNative(_one(address(token)), address(thin), path, 1);

        assertEq(handler.getClaimable(_one(address(token)), address(thin), alice)[0], 1e18, "claim intact");
        assertEq(thin.balanceOf(address(handler)), 1e18, "nothing sold");

        // The same route fills a claim the pool can absorb, so the revert above is the partial fill.
        MockAssetFeeToken small = _earningIn(address(thin), bob, 1e14);
        vm.prank(bob);
        assertGt(handler.claimAsNative(_one(address(small)), address(thin), path, 1), 0, "small claim fills");
    }

    /// @dev A sale that fills but delivers no native reverts even with a zero floor: the claim is not
    ///      burned for nothing.
    function test_claimAsNative_zeroProceedsRevertsEvenWithZeroFloor() public {
        (ThinAsset thin, PathKey[] memory path) = _thinPool();
        MockAssetFeeToken token = _earningIn(address(thin), alice, 1); // all of it goes to the 0.3% fee

        vm.prank(alice);
        vm.expectRevert(IRealmMasterFeeHandler.NativeConversionFailed.selector);
        handler.claimAsNative(_one(address(token)), address(thin), path, 0);

        assertEq(handler.getClaimable(_one(address(token)), address(thin), alice)[0], 1, "claim intact");
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
