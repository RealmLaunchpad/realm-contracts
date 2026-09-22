// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {UniswapV4PoolConstants as Eth} from "src/libraries/UniswapV4PoolConstants.sol";
import {UniswapV4PoolConstantsArc as Arc} from "src/libraries/UniswapV4PoolConstantsArc.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";

/// @notice The ARC (USDC-native) V4 pool constants the `chain-arc-*` retarget swaps in for the direct
///         venue. What is left there is price-independent, so it must match the ETH library exactly: a
///         drift would have an ARC build target a different pool than the tokens and graduator agree on.
contract UniswapV4ConstantsArcTest is Test {
    function test_feeAndSpacing_matchTheEthLibrary() public pure {
        assertEq(Arc.LP_FEE, Eth.LP_FEE, "LP fee");
        assertEq(Arc.TICK_SPACING, Eth.TICK_SPACING, "tick spacing");
    }

    function test_fuzz_realmPoolKey_matchesTheEthLibrary(address token, address quote, address hook) public pure {
        vm.assume(token != quote);
        assertEq(
            keccak256(abi.encode(Arc.realmPoolKey(token, quote, hook))),
            keccak256(abi.encode(Eth.realmPoolKey(token, quote, hook))),
            "pool key"
        );
        PoolKey memory arcNative = Arc.realmPoolKey(token, hook);
        assertEq(keccak256(abi.encode(arcNative)), keccak256(abi.encode(Eth.realmPoolKey(token, hook))), "native key");
    }
}
