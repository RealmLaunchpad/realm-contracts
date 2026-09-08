// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GraduationFeeConstants} from "src/libraries/GraduationFeeConstants.sol";
import {GraduationFeeConstantsArc} from "src/libraries/GraduationFeeConstantsArc.sol";
import {RealmGraduatorUniswapV2} from "src/graduators/RealmGraduatorUniswapV2.sol";
import {RealmGraduatorUniswapV2Arc} from "src/graduators/RealmGraduatorUniswapV2Arc.sol";

/// @dev Wraps the internal library guards in external calls so `vm.expectRevert` can catch them.
contract GuardHarness {
    function eth(uint256 chainId) external pure {
        GraduationFeeConstants.assertDeployableOn(chainId);
    }

    function arc(uint256 chainId) external pure {
        GraduationFeeConstantsArc.assertDeployableOn(chainId);
    }
}

/// @dev Minimal V2 router so a graduator ctor completes on a valid chain (only WETH()/factory() are read).
contract MockV2Router {
    function WETH() external pure returns (address) {
        return address(0xE);
    }

    function factory() external pure returns (address) {
        return address(0xF);
    }
}

/// @notice Tests the build-vs-chain guard baked into EVERY graduator constructor
///         (`GraduationFeeConstants.assertDeployableOn`). The committed build is ETH-priced, so a
///         graduator must REFUSE to deploy on an ARC chain — this is what catches a forgotten
///         `just chain-arc-testnet` before an ARC deploy, on any deploy path.
contract GraduatorChainGuardTest is Test {
    uint256 constant ARC_TESTNET = 5042002;
    uint256 constant ARC_MAINNET = 5042;

    // --- library allow/deny logic ---

    function test_ethLib_allowsNonArcChains() public {
        GuardHarness h = new GuardHarness();
        h.eth(1); // ethereum mainnet
        h.eth(11155111); // sepolia
        h.eth(4663); // robinhood mainnet
        h.eth(31337); // anvil / this test chain
    }

    function test_ethLib_revertsOnArcTestnet() public {
        GuardHarness h = new GuardHarness();
        vm.expectRevert();
        h.eth(ARC_TESTNET);
    }

    function test_ethLib_revertsOnArcMainnet() public {
        GuardHarness h = new GuardHarness();
        vm.expectRevert();
        h.eth(ARC_MAINNET);
    }

    function test_arcLib_allowsOnlyArcChains() public {
        GuardHarness h = new GuardHarness();
        h.arc(ARC_TESTNET);
        h.arc(ARC_MAINNET);
    }

    function test_arcLib_revertsOnEthChain() public {
        GuardHarness h = new GuardHarness();
        vm.expectRevert();
        h.arc(1);
    }

    // --- ctor wiring: the ETH-built graduator actually calls the guard and refuses an ARC chain ---

    function test_v2Graduator_ctorGuardsAgainstArc() public {
        MockV2Router r = new MockV2Router();
        // Same valid construction succeeds on the test chain but reverts on ARC — only the chainid
        // differs, so the revert can only be the guard (nothing else in the ctor reads block.chainid).
        new RealmGraduatorUniswapV2(address(r), address(0xABCD), bytes32(uint256(1)));

        vm.chainId(ARC_TESTNET);
        vm.expectRevert();
        new RealmGraduatorUniswapV2(address(r), address(0xABCD), bytes32(uint256(1)));
    }

    // --- the ARC V2 graduator is the mirror image: only constructs on ARC chains ---

    function test_v2ArcGraduator_ctorGuardsAgainstNonArc() public {
        MockV2Router r = new MockV2Router();
        // Reverts on the test chain (31337, non-ARC)...
        vm.expectRevert();
        new RealmGraduatorUniswapV2Arc(address(r), address(0xABCD), bytes32(uint256(1)));

        // ...and constructs on ARC. Only the chainid differs, so success is purely the guard passing.
        vm.chainId(ARC_TESTNET);
        new RealmGraduatorUniswapV2Arc(address(r), address(0xABCD), bytes32(uint256(1)));

        vm.chainId(ARC_MAINNET);
        new RealmGraduatorUniswapV2Arc(address(r), address(0xABCD), bytes32(uint256(1)));
    }
}
