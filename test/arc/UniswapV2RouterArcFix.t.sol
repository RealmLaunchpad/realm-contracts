// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {DeploymentAddressesArcTestnet as Arc} from "src/config/DeploymentAddresses.sol";

contract MockToken is ERC20 {
    constructor(uint256 supply) ERC20("Mock", "MOCK") {
        _mint(msg.sender, supply);
    }
}

/// @notice Proves the deployed arc-testnet V2 router (`Arc.UNIV2_ROUTER`, the vendored
///         RealmUniswapV2Router02 with pair init-code-hash 0xb5a7f108…) is compatible with the factory
///         — i.e. the fix for the original misdeployed Router02, whose stock 0x96e8ac42… hash made
///         every `pairFor` target a non-contract.
///
///         Uses two plain ERC20s, NOT USDC: ARC's native-USDC precompile (0x3600) moves balance via
///         host logic that a Foundry fork can't simulate (its `transferFrom` StackUnderflows), so a
///         full USDC-paired graduation can only be verified on LIVE arc-testnet. The `pairFor` code
///         path being fixed here is identical regardless of token, so this is a faithful proof.
///
///         Self-contained (reads the on-chain router; no deployCode/prior-build needed). Skips cleanly
///         without ARC_TESTNET_RPC_URL.
contract UniswapV2RouterArcFixTest is Test {
    function test_onChainRouter_pairsAgainstFactory() public {
        string memory rpc = vm.envOr("ARC_TESTNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, Arc.BLOCKCHAIN_ID, "fork is not arc-testnet");

        address router = Arc.UNIV2_ROUTER;
        assertGt(router.code.length, 0, "no router deployed at Arc.UNIV2_ROUTER");
        assertEq(IUniswapV2Router(router).factory(), Arc.UNIV2_FACTORY, "router.factory() wrong");

        MockToken a = new MockToken(1_000e18);
        MockToken b = new MockToken(1_000e18);
        a.approve(router, type(uint256).max);
        b.approve(router, type(uint256).max);

        // With the STOCK hash this reverts (pairFor → non-contract, the on-chain bug); with the
        // vendored hash it finds/creates the factory's real pair and mints LP. Success == fix works.
        (uint256 amtA, uint256 amtB, uint256 liq) = IUniswapV2Router(router)
            .addLiquidity(address(a), address(b), 500e18, 500e18, 0, 0, address(0xdEaD), block.timestamp);
        assertEq(amtA, 500e18, "amountA");
        assertEq(amtB, 500e18, "amountB");
        assertGt(liq, 0, "no LP minted");

        address pair = IUniswapV2Factory(Arc.UNIV2_FACTORY).getPair(address(a), address(b));
        assertTrue(pair != address(0), "pair not created");
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        assertEq(uint256(r0) + uint256(r1), 1_000e18, "reserves != deposited");
    }
}
