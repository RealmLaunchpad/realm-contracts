// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests} from "test/launchpad/base.t.sol";
import {V4SwapHelpers} from "test/e2e/base/V4SwapHelpers.t.sol";
import {V2SwapHelpers} from "test/e2e/base/V2SwapHelpers.t.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {SniperProtection} from "src/tokens/SniperProtection.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";

/// @notice Central abstract base for the Realm end-to-end test framework. Each factory variant has
///         a thin subclass under test/e2e/variants/ that implements `_createTestToken` and the trait
///         booleans. Tests live in abstract suites under test/e2e/suites/ and are mixed into the
///         variant subclasses based on which traits the variant supports.
abstract contract RealmE2EBase is V4SwapHelpers, V2SwapHelpers {
    ////////////////////////////// VIRTUAL HOOKS //////////////////////////////

    /// @dev Creates a token using the variant's factory with sensible defaults (single fee receiver
    ///      and no deployer buy).
    function _createTestToken(bytes32 salt) internal virtual returns (address token);

    /// @dev Creates a token with multiple fee receivers (>=2).
    function _createTestTokenWithSplit(bytes32 salt, IRealmFactory.FeeShare[] memory feeReceivers)
        internal
        virtual
        returns (address token);

    /// @dev Creates a token while sending `ethValue` for the deployer-buy flow. `supplyShares` must
    ///      sum to 10_000.
    function _createTokenWithDeployerBuy(
        bytes32 salt,
        uint256 ethValue,
        IRealmFactory.SupplyShare[] memory supplyShares
    ) internal virtual returns (address token);

    function _isV4Graduator() internal view virtual returns (bool);
    function _hasSniperProtection() internal view virtual returns (bool);
    function _hasTax() internal view virtual returns (bool);
    function _supportsRenounceOwnership() internal view virtual returns (bool);

    /// @dev Returns the address of the variant's factory. Used for `prank(creator)` flows that
    ///      target a uniform factory regardless of variant.
    function _factory() internal view virtual returns (address);

    /// @dev Returns the variant's token implementation address (for salt prediction).
    function _tokenImpl() internal view virtual returns (address);

    ////////////////////////// AUTO-ROUTING HELPERS //////////////////////////

    /// @dev Buys tokens on the post-graduation pool, picking V2 or V4 based on graduator type.
    function _swapBuyAuto(address caller, address token, uint256 ethIn, uint256 minOut) internal {
        if (_isV4Graduator()) {
            _swapBuyV4(caller, token, ethIn, minOut, true);
        } else {
            _swapBuyV2(caller, token, ethIn, minOut, true);
        }
    }

    /// @dev Sells tokens on the post-graduation pool, picking V2 or V4 based on graduator type.
    function _swapSellAuto(address caller, address token, uint256 tokenIn, uint256 minEth)
        internal
        returns (uint256 ethReceived)
    {
        if (_isV4Graduator()) {
            return _swapSellV4(caller, token, tokenIn, minEth, true);
        } else {
            return _swapSellV2(caller, token, tokenIn, minEth, true);
        }
    }

    /// @dev Graduates the token using a path safe for the variant. For sniper-protected variants,
    ///      a single graduation-sized buy would trip `MaxBuyPerTxExceeded`, so the token is
    ///      graduated via many distinct sub-cap buyers.
    function _graduateE2E(address token) internal {
        testToken = token;
        if (_hasSniperProtection()) {
            _graduateInSmallBuys(token);
        } else {
            _graduateToken();
        }
    }

    /// @dev Graduates the token by issuing many sub-cap buys, each from a distinct buyer to avoid
    ///      tripping per-tx and max-wallet caps. ~0.05 ETH per buy yields ~22M tokens, under the
    ///      3% per-tx cap; using distinct addresses keeps the wallet cap clear.
    function _graduateInSmallBuys(address token) internal {
        uint256 chunks = 100; // Enough to cross the 3.75 ETH threshold at ~0.05 ETH each.
        for (uint256 i; i < chunks; ++i) {
            if (launchpad.getTokenState(token).graduated) return;
            address b = address(uint160(0x10000 + i));
            vm.deal(b, 0.05 ether);
            vm.prank(b);
            launchpad.buyTokensWithExactEth{value: 0.05 ether}(token, 0, DEADLINE);
        }
    }

    /// @dev Warps past the sniper protection window using the token's stored launchTimestamp.
    function _warpPastSniperWindow(address token) internal {
        SniperProtection sp = SniperProtection(token);
        uint256 windowEnd = uint256(IRealmToken(address(sp)).launchTimestamp()) + uint256(sp.protectionWindowSeconds());
        vm.warp(windowEnd + 1);
    }

    /// @dev Warps past the tax window using the token's `graduationTimestamp` + `taxDurationSeconds`.
    function _warpPastTaxWindow(address token) internal {
        RealmTaxableTokenUniV4 t = RealmTaxableTokenUniV4(payable(token));
        uint256 end = uint256(t.graduationTimestamp()) + uint256(t.taxDurationSeconds());
        vm.warp(end + 1);
    }

    /// @dev Default sniper config used when the variant is sniper-protected. Empty whitelist on
    ///      purpose — graduation must succeed via the code-level graduator bypass in
    ///      `SniperProtection._checkSniperProtection`, NOT via a user-supplied whitelist. Putting
    ///      the graduators in the whitelist here would mask any regression in that bypass.
    function _defaultE2EAntiSniperCfg() internal pure returns (AntiSniperConfigs memory) {
        return AntiSniperConfigs({
            maxBuyPerTxBps: 300, maxWalletBps: 300, protectionWindowSeconds: 1 hours, whitelist: new address[](0)
        });
    }

    /// @dev Single-share supply shares helper.
    function _ssOne(address account) internal pure returns (IRealmFactory.SupplyShare[] memory arr) {
        arr = new IRealmFactory.SupplyShare[](1);
        arr[0] = IRealmFactory.SupplyShare({account: account, shares: 10_000});
    }

    /// @dev Two-share fee receivers helper for multi-recipient tests.
    function _fsTwo(address a1, address a2) internal pure returns (IRealmFactory.FeeShare[] memory arr) {
        arr = new IRealmFactory.FeeShare[](2);
        arr[0] = IRealmFactory.FeeShare({account: a1, shares: 6_000, directFeesEnabled: false});
        arr[1] = IRealmFactory.FeeShare({account: a2, shares: 4_000, directFeesEnabled: false});
    }
}
