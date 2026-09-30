// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploymentAddressesRobinhoodMainnet as Robinhood} from "src/config/DeploymentAddresses.sol";
import {IUniversalRouter, IV4RouterSwaps} from "src/interfaces/IUniswapV4UniversalRouter.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

/// @notice Pins `IV4RouterSwaps` to the calldata layout the universal router DEPLOYED on Robinhood
///         actually decodes. The params cross into `execute` as an opaque `bytes` blob, so the compiler
///         cannot check the two sides against each other — only a live router can.
/// @dev Regression test for the buy-back outage: the params were encoded from `lib/v4-periphery`, which
///      predates `minHopPriceX36`, and every ERC20-quoted swap reverted with EMPTY returndata. The
///      low-level `.call` in `RealmUniv4BuyBacks` turned that into `BuyBackFailed()` /
///      `DividendConversionFailed()` with no clue as to why.
/// @dev Deliberately needs no pool, no liquidity and no Realm stack: an UNINITIALISED key is enough,
///      because the question is only whether the router can decode what we send. A decodable payload
///      reaches the pool lookup and fails there with `PoolNotInitialized`; an undecodable one dies
///      earlier with empty returndata. That keeps this immune to pools drying up.
/// @dev The key is ERC20/ERC20 ON PURPOSE. With the stale layout the router read `currency0` as the
///      `hookData` length, which is 0 for a native quote — harmless — and a 20-byte address for an
///      ERC20 one. Native-quoted pools therefore kept working, which is exactly why the existing
///      Robinhood suites (all hookless native-ETH pools) never caught this.
contract RobinhoodRouterAbi is Test {
    uint256 internal constant ROBINHOOD_FORK_BLOCK = 58_000_000;

    /// @dev v4-core's `PoolNotInitialized()`, thrown once the swap params decoded cleanly.
    bytes4 internal constant POOL_NOT_INITIALIZED = 0x486aa307;

    address internal constant CURRENCY_0 = 0x1111111111111111111111111111111111111111;
    address internal constant CURRENCY_1 = 0x2222222222222222222222222222222222222222;

    /// @dev The layout the protocol used to send: `IV4RouterSwaps.ExactInputSingleParams` minus
    ///      `minHopPriceX36`. Kept only so the negative control below can prove this test would catch
    ///      the regression coming back.
    struct StaleExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), ROBINHOOD_FORK_BLOCK);
    }

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(CURRENCY_0),
            currency1: Currency.wrap(CURRENCY_1),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
    }

    function _execute(bytes memory encodedParams) internal returns (bool ok, bytes memory ret) {
        bytes[] memory params = new bytes[](1);
        params[0] = encodedParams;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE)), params);
        (ok, ret) = Robinhood.UNIV4_UNIVERSAL_ROUTER
            .call(abi.encodeCall(IUniversalRouter.execute, (abi.encodePacked(uint8(0x10)), inputs, block.timestamp)));
    }

    /// @notice What the protocol sends today must be decodable by the deployed router.
    function test_currentEncodingIsDecodedByTheDeployedRouter() public {
        (bool ok, bytes memory ret) = _execute(
            abi.encode(
                IV4RouterSwaps.ExactInputSingleParams({
                    poolKey: _key(),
                    zeroForOne: true,
                    amountIn: 1000,
                    amountOutMinimum: 0,
                    minHopPriceX36: 0,
                    hookData: bytes("")
                })
            )
        );
        assertFalse(ok, "uninitialised pool must revert");
        assertGt(ret.length, 0, "EMPTY REVERT: the router could not decode our swap params");
        assertEq(bytes4(ret), POOL_NOT_INITIALIZED, "decoded, but did not reach the pool lookup");
    }

    /// @notice The negative control: the layout we used to send is NOT decodable, proving the assertion
    ///         above is load-bearing rather than passing for some unrelated reason.
    function test_staleEncodingRevertsEmpty() public {
        (bool ok, bytes memory ret) = _execute(
            abi.encode(
                StaleExactInputSingleParams({
                    poolKey: _key(), zeroForOne: true, amountIn: 1000, amountOutMinimum: 0, hookData: bytes("")
                })
            )
        );
        assertFalse(ok, "stale layout must revert");
        assertEq(ret.length, 0, "stale layout unexpectedly decoded - the router ABI moved again");
    }
}
