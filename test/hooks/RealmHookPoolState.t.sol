// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";

/// @notice `RealmHook` must report exactly what the V4 `PoolManager.Swap` event reports, so indexers can
///         drop the singleton-PoolManager subscription and read spot price off the hook instead.
/// @dev Runs the standard tax-token suite setup, then swaps `RealmHook`'s code in at the same mined hook
///      address the base deployed `RealmSwapHook` to. The hook holds no persistent storage (only
///      transient), so re-etching it mid-setup is safe.
contract RealmHookPoolStateTests is TaxTokenUniV4BaseTests {
    bytes32 constant POOL_STATE_SIG = keccak256("RealmPoolState(address,bytes32,uint160,uint128)");
    bytes32 constant SWAP_BUY_SIG = keccak256("RealmSwapBuy(address,address,uint256,uint256,uint256)");
    bytes32 constant SWAP_SELL_SIG = keccak256("RealmSwapSell(address,address,uint256,uint256,uint256)");
    bytes32 constant V4_SWAP_SIG = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function setUp() public virtual override {
        super.setUp();
        deployCodeTo(
            "RealmHook.sol:RealmHook", abi.encode(poolManagerAddress, address(lpFeeRouter), treasury), TEST_HOOK_ADDRESS
        );
    }

    /// @notice A buy emits `RealmPoolState` carrying the same post-swap price and liquidity the
    ///         `PoolManager.Swap` event reports, ahead of the hook's own `RealmSwapBuy`.
    function test_buyEmitsPoolStateMatchingPoolManager() public createDefaultTaxToken {
        _graduateToken();

        deal(buyer, 1 ether);
        vm.recordLogs();
        _swapBuy(buyer, 1 ether, 0, true);

        _assertPoolStateMatchesPoolManager(vm.getRecordedLogs(), SWAP_BUY_SIG);
    }

    /// @notice Same guarantee on the sell leg, which settles its fee in `afterSwap` rather than before.
    function test_sellEmitsPoolStateMatchingPoolManager() public createDefaultTaxToken {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();
        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1);

        vm.recordLogs();
        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 2, 0, true);

        _assertPoolStateMatchesPoolManager(vm.getRecordedLogs(), SWAP_SELL_SIG);
    }

    /// @dev Asserts the hook's `RealmPoolState` mirrors `PoolManager.Swap` and precedes the trade event.
    ///      The ordering matters: indexers process logs by index and must have fresh reserves in hand
    ///      before they handle the trade, which is how the `PoolManager.Swap` subscription behaves today.
    function _assertPoolStateMatchesPoolManager(Vm.Log[] memory logs, bytes32 tradeSig) internal view {
        uint256 poolStateIdx = _indexOf(logs, POOL_STATE_SIG);
        uint256 v4SwapIdx = _indexOf(logs, V4_SWAP_SIG);
        uint256 tradeIdx = _indexOf(logs, tradeSig);

        assertEq(logs[poolStateIdx].emitter, TEST_HOOK_ADDRESS, "RealmPoolState must come from the hook");
        assertEq(address(uint160(uint256(logs[poolStateIdx].topics[1]))), testToken, "RealmPoolState token mismatch");
        assertLt(poolStateIdx, tradeIdx, "RealmPoolState must precede the trade event");

        (bytes32 hookPoolId, uint160 hookSqrtPriceX96, uint128 hookLiquidity) =
            abi.decode(logs[poolStateIdx].data, (bytes32, uint160, uint128));
        (,, uint160 poolSqrtPriceX96, uint128 poolLiquidity,,) =
            abi.decode(logs[v4SwapIdx].data, (int128, int128, uint160, uint128, int24, uint24));

        assertGt(hookSqrtPriceX96, 0, "sqrtPriceX96 must be non-zero");
        assertGt(hookLiquidity, 0, "liquidity must be non-zero");
        assertEq(hookSqrtPriceX96, poolSqrtPriceX96, "sqrtPriceX96 must match PoolManager.Swap");
        assertEq(hookLiquidity, poolLiquidity, "liquidity must match PoolManager.Swap");
        // `PoolManager.Swap` indexes the pool id as topic1. Comparing against it proves the hook's own
        // `key.toId()` resolves to the same pool the manager just swapped.
        assertEq(hookPoolId, logs[v4SwapIdx].topics[1], "poolId must match PoolManager.Swap's id topic");
    }

    function _indexOf(Vm.Log[] memory logs, bytes32 sig) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) return i;
        }
        revert("event not found");
    }
}
