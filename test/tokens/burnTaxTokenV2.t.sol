// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {V2SwapHelpers} from "test/e2e/base/V2SwapHelpers.t.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Integration tests for the V2 token-space burn earnings-allocation leg (no ETH→token round
///         trip: the burn share is burned as tax TOKENS inside the swap-back, before the swap).
contract BurnTaxTokenV2Tests is LaunchpadBaseTestsWithUniv2Graduator, V2SwapHelpers {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }

    /// @dev Creates an ownerless V2 tax token with a `burnBps` allocation via the allocation-aware
    ///      `createToken` overload. 4%-configurable sell tax, creation-anchored 14-day window.
    function _createBurnV2Token(uint16 sellTaxBps, uint16 burnBps) internal returns (address token) {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "BurnV2",
            symbol: "BV2",
            salt: _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 0,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: burnBps, dividendsBps: 0, liquidityBps: 0, dividendToken: address(0)
            })
        });
        vm.prank(creator);
        token = factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new ILivoFactory.CreatorVault[](0), address(0)
        );
    }

    function test_burnBps_storedAtCreation() public {
        address token = _createBurnV2Token(400, 5000);
        assertEq(LivoTaxableTokenUniV2(payable(token)).burnBps(), 5000, "burnBps stored via new overload");
    }

    function test_v2Burn_swapBackBurnsTokenShareInPlace() public {
        address token = _createBurnV2Token(400, 5000); // 4% sell tax; 50% of earnings → burn
        testToken = token;
        LivoTaxableTokenUniV2 burnToken = LivoTaxableTokenUniV2(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(token, 0, DEADLINE);
        _graduateToken();

        // A single sell accrues sell tax as tokens on the contract (no auto-swap-back: the balance was
        // 0 before this sell).
        uint256 sellAmount = IERC20(token).balanceOf(buyer) / 10;
        _swapSellV2(buyer, token, sellAmount, 0, true);

        uint256 accrued = IERC20(token).balanceOf(address(burnToken));
        assertGt(accrued, 0, "sell tax should accrue as tokens on the contract");

        uint256 supplyBefore = IERC20(token).totalSupply();
        uint256 expectedBurn = accrued * 5000 / 10_000;

        // Manual swap-back by the launchpad owner (V2 tokens are ownerless). Burns the burn share as
        // tokens in-place (no ETH→token round trip), then swaps the rest.
        // Shared two-field signature; V2 spends no ETH to burn (token-space burn), so `ethSpent` is 0.
        vm.expectEmit(true, true, true, true, address(burnToken));
        emit LivoTaxableToken.CreatorTaxBurn(0, expectedBurn);
        vm.prank(admin);
        burnToken.swapBack(accrued, 0);

        assertEq(IERC20(token).totalSupply(), supplyBefore - expectedBurn, "supply reduced by the token-space burn");
        assertLt(IERC20(token).balanceOf(address(burnToken)), accrued, "accrued tax processed");
    }

    function test_v2SwapBack_revertsBeforeGraduation() public {
        address token = _createBurnV2Token(400, 5000);
        LivoTaxableTokenUniV2 burnToken = LivoTaxableTokenUniV2(payable(token));
        vm.prank(admin);
        vm.expectRevert(LivoTaxableTokenUniV2.NotGraduated.selector);
        burnToken.swapBack(1, 0);
    }
}
