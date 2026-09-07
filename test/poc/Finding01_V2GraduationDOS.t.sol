// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";

import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// ───────────────────────────────────────────────────────────────────────────────
// Finding #1 — Pre-graduation token donation permanently bricks V2 graduation
// ───────────────────────────────────────────────────────────────────────────────
//
// Attack:
//   1. Attacker buys ~SWAP_THRESHOLD tokens from the bonding curve (≈0.05 ETH).
//   2. Attacker transfers those tokens to address(token). The transfer succeeds
//      because the pre-graduation gate only blocks transfers TO `pair`, not to
//      the token itself.
//   3. When anyone later triggers graduation, the V2 graduator calls
//      `router.addLiquidityETH` which does `transferFrom(graduator, pair, ...)`.
//      Inside the token's `_update(graduator, pair, ...)`: `_graduated=true`,
//      `isSell=true`, `balanceOf(this) >= SWAP_THRESHOLD` → `_processCollectedTokens` fires
//      against a pair whose reserves are still (0, 0). The router reverts with
//      INSUFFICIENT_LIQUIDITY, taking the entire graduation tx down.
//   4. The token is permanently stuck pre-graduation.
contract Finding01_V2GraduationDOS is LaunchpadBaseTestsWithUniv2Graduator {
    LivoTaxableTokenUniV2 internal taxToken;
    address internal attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();

        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));
        TaxConfigInit memory cfg = _taxCfg(100, 400, 7 days); // 1% buy / 4% sell

        vm.prank(creator);
        testToken = factoryV2Unified.createToken("Tax", "TAX", salt, _fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
        taxToken = LivoTaxableTokenUniV2(payable(testToken));

        vm.deal(attacker, 1 ether);
    }

    /// @notice Asserts that an attacker priming the token contract with
    ///         ≥ SWAP_THRESHOLD tokens MUST NOT prevent graduation. Fails on
    ///         the current (buggy) code because the graduator's first
    ///         `addLiquidityETH` triggers an auto-`_processCollectedTokens` against an
    ///         unfunded pair; passes once `_update` skips the auto-swap
    ///         branch for `from == graduator` (or another equivalent guard).
    function test_graduationMustSucceedDespiteTokenContractPriming() public {
        uint256 threshold = taxToken.SWAP_THRESHOLD();

        // ── 1. Attacker buys tokens from the bonding curve. ~0.05 ETH is more than
        //       enough to exceed SWAP_THRESHOLD = TOTAL_SUPPLY / 2000 early on the curve.
        vm.prank(attacker);
        launchpad.buyTokensWithExactEth{value: 0.05 ether}(testToken, 0, DEADLINE);

        uint256 attackerBal = IERC20(testToken).balanceOf(attacker);
        assertGe(attackerBal, threshold, "Attacker needs at least SWAP_THRESHOLD tokens to prime");

        // ── 2. Attacker primes the token contract. Transfer to address(token) is NOT
        //       blocked by the pre-graduation gate (which only blocks `to == pair`).
        vm.prank(attacker);
        IERC20(testToken).transfer(address(taxToken), threshold);

        assertGe(
            IERC20(testToken).balanceOf(address(taxToken)),
            threshold,
            "Token contract must hold >= SWAP_THRESHOLD to trigger the bug"
        );

        // ── 3. Graduation must still succeed. On the buggy code this reverts inside
        //       the graduator's addLiquidityETH; on the fixed code it goes through.
        uint256 ethReserves = launchpad.getTokenState(testToken).ethCollected;
        // Gross up by the tax token's actual buy fee (LP fee + buy tax) so reserves reach the threshold.
        uint256 finalBuy = ((GRADUATION_THRESHOLD - ethReserves) * 10000) / (10000 - _currentBuyFeeBps(testToken));
        vm.deal(buyer, finalBuy);

        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: finalBuy}(testToken, 0, DEADLINE);

        assertTrue(taxToken.graduated(), "Graduation must succeed even when address(token) is pre-primed");
    }
}
