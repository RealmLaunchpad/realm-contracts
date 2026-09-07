// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {RealmE2EBase} from "test/e2e/base/RealmE2EBase.t.sol";
import {RealmSwapHook} from "src/hooks/RealmSwapHook.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice E2E suite for tax variants only. Confirms the V4 hook applies the configured tax during
///         the post-graduation tax window and stops after the window closes.
abstract contract E2ETaxWindow is RealmE2EBase {
    function test_e2e_tax_emitsCreatorTaxesAccrued_duringWindow() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);
        _graduateE2E(token);

        vm.deal(alice, 1 ether);
        _swapBuyAuto(alice, token, 0.5 ether, 0);
        uint256 tokenBal = IERC20(token).balanceOf(alice);
        assertGt(tokenBal, 0);

        vm.recordLogs();
        _swapSellAuto(alice, token, tokenBal / 2, 0);

        bytes32 want = RealmSwapHook.CreatorTaxesAccrued.selector;
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == want) {
                found = true;
                break;
            }
        }
        assertTrue(found, "expected CreatorTaxesAccrued during sell within tax window");
    }

    function test_e2e_tax_doesNotEmitCreatorTaxesAccrued_afterWindow() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);
        _graduateE2E(token);

        vm.deal(alice, 1 ether);
        _swapBuyAuto(alice, token, 0.5 ether, 0);
        uint256 tokenBal = IERC20(token).balanceOf(alice);

        _warpPastTaxWindow(token);

        vm.recordLogs();
        _swapSellAuto(alice, token, tokenBal / 2, 0);

        bytes32 unwanted = RealmSwapHook.CreatorTaxesAccrued.selector;
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == unwanted) {
                found = true;
                break;
            }
        }
        assertFalse(found, "expected NO CreatorTaxesAccrued once tax window has closed");
    }
}
