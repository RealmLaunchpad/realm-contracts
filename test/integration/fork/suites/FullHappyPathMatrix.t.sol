// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {ForkIntegrationSwapHelpers} from "test/integration/fork/base/ForkIntegrationSwapHelpers.t.sol";
import {ForkIntegrationCaseLib} from "test/integration/fork/base/ForkIntegrationCaseLib.t.sol";

/// @notice Full happy-path matrix for deployed Realm fork integrations.
/// @dev Chain-specific contracts only need to override `_chainConfig()`.
abstract contract FullHappyPathMatrix is ForkIntegrationSwapHelpers {
    uint256 internal constant UNI_V2_CASE_COUNT = 2 * 3 * 4;
    uint256 internal constant UNI_V4_CASE_COUNT = 2 * 2 * 2 * 3 * 4;

    function test_fullHappyPath_allUniV2Cases() public {
        uint256 caseIndex;
        uint256 ran;

        for (uint256 sniper; sniper < 2; ++sniper) {
            for (uint256 creatorBuy; creatorBuy < 3; ++creatorBuy) {
                for (uint256 feeMode; feeMode < 4; ++feeMode) {
                    ForkIntegrationCaseLib.IntegrationCase memory c = ForkIntegrationCaseLib.IntegrationCase({
                        factoryKind: ForkIntegrationCaseLib.FactoryKind.UniV2,
                        taxMode: ForkIntegrationCaseLib.TaxMode.NoTax,
                        sniperMode: ForkIntegrationCaseLib.SniperMode(sniper),
                        ownershipMode: ForkIntegrationCaseLib.OwnershipMode.RenounceOwnership,
                        creatorBuyMode: ForkIntegrationCaseLib.CreatorBuyMode(creatorBuy),
                        feeMode: ForkIntegrationCaseLib.FeeMode(feeMode)
                    });

                    if (_caseInShard(caseIndex)) {
                        _logCase(caseIndex, c);
                        _runFullHappyPath(caseIndex, c);
                        ++ran;
                    }
                    ++caseIndex;
                }
            }
        }

        emit log_named_uint("UniV2 integration cases run", ran);
    }

    function test_fullHappyPath_allUniV4Cases() public {
        uint256 caseIndex = UNI_V2_CASE_COUNT;
        uint256 ran;

        for (uint256 taxMode; taxMode < 2; ++taxMode) {
            for (uint256 sniper; sniper < 2; ++sniper) {
                for (uint256 ownership; ownership < 2; ++ownership) {
                    for (uint256 creatorBuy; creatorBuy < 3; ++creatorBuy) {
                        for (uint256 feeMode; feeMode < 4; ++feeMode) {
                            ForkIntegrationCaseLib.IntegrationCase memory c = ForkIntegrationCaseLib.IntegrationCase({
                                factoryKind: ForkIntegrationCaseLib.FactoryKind.UniV4,
                                taxMode: ForkIntegrationCaseLib.TaxMode(taxMode),
                                sniperMode: ForkIntegrationCaseLib.SniperMode(sniper),
                                ownershipMode: ForkIntegrationCaseLib.OwnershipMode(ownership),
                                creatorBuyMode: ForkIntegrationCaseLib.CreatorBuyMode(creatorBuy),
                                feeMode: ForkIntegrationCaseLib.FeeMode(feeMode)
                            });

                            if (_caseInShard(caseIndex)) {
                                _logCase(caseIndex, c);
                                _runFullHappyPath(caseIndex, c);
                                ++ran;
                            }
                            ++caseIndex;
                        }
                    }
                }
            }
        }

        emit log_named_uint("UniV4 integration cases run", ran);
        assertEq(caseIndex, UNI_V2_CASE_COUNT + UNI_V4_CASE_COUNT, "matrix count mismatch");
    }

    function _caseInShard(uint256 caseIndex) internal view returns (bool) {
        uint256 start = vm.envOr("INTEGRATION_CASE_START", uint256(0));
        uint256 end = vm.envOr("INTEGRATION_CASE_END", uint256(type(uint256).max));
        return caseIndex >= start && caseIndex <= end;
    }

    function _logCase(uint256 caseIndex, ForkIntegrationCaseLib.IntegrationCase memory c) internal {
        emit log_named_uint("integration case", caseIndex);
        emit log_named_uint("factory kind", uint256(c.factoryKind));
        emit log_named_uint("tax mode", uint256(c.taxMode));
        emit log_named_uint("sniper mode", uint256(c.sniperMode));
        emit log_named_uint("ownership mode", uint256(c.ownershipMode));
        emit log_named_uint("creator buy mode", uint256(c.creatorBuyMode));
        emit log_named_uint("fee mode", uint256(c.feeMode));
    }

    function _runFullHappyPath(uint256 caseIndex, ForkIntegrationCaseLib.IntegrationCase memory c) internal {
        (address token, ForkIntegrationCaseLib.CaseActors memory a) = _deployCaseToken(caseIndex, c);

        _buyFromLaunchpadWithQuoter(token, a.launchBuyer, LAUNCHPAD_BUY_REQUEST_ETH);
        uint256 launchBuyerTokens = IERC20(token).balanceOf(a.launchBuyer);
        assertGt(launchBuyerTokens, 0, "launch buyer did not receive tokens");
        _sellToLaunchpadWithQuoter(token, a.launchBuyer, launchBuyerTokens / 2);

        uint256 directBalanceBeforeFees = a.feeDirect.balance;
        _graduateWithQuoter(token, caseIndex, _hasSniper(c));
        _postGraduationSwaps(c, token, a.ammBuyer);
        _assertFeeClaimsAndDirectReceivers(c, token, a, directBalanceBeforeFees);
    }

    function _postGraduationSwaps(ForkIntegrationCaseLib.IntegrationCase memory c, address token, address trader)
        internal
    {
        uint256 tokenBeforeBuy = IERC20(token).balanceOf(trader);
        vm.deal(trader, INITIAL_ETH_BALANCE);

        if (_isV4(c) && _hasTax(c)) vm.recordLogs();
        if (_isV4(c)) {
            _swapBuyV4(trader, token, AMM_BUY_ETH, 0);
        } else {
            _swapBuyV2(trader, token, AMM_BUY_ETH, 0);
        }
        if (_isV4(c) && _hasTax(c)) _assertTaxLogSeen();

        uint256 tokenAfterBuy = IERC20(token).balanceOf(trader);
        assertGt(tokenAfterBuy, tokenBeforeBuy, "AMM buy did not deliver tokens");

        uint256 sellAmount = (tokenAfterBuy - tokenBeforeBuy) / 2;
        assertGt(sellAmount, 0, "empty AMM sell amount");

        uint256 ethReceived;
        if (_isV4(c) && _hasTax(c)) vm.recordLogs();
        if (_isV4(c)) {
            ethReceived = _swapSellV4(trader, token, sellAmount, 0);
        } else {
            ethReceived = _swapSellV2(trader, token, sellAmount, 0);
        }
        if (_isV4(c) && _hasTax(c)) _assertTaxLogSeen();

        assertGt(ethReceived, 0, "AMM sell did not deliver ETH");
    }
}
