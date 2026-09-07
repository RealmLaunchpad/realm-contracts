// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RealmQuoter} from "src/RealmQuoter.sol";
import {IRealmQuoter, LimitReason} from "src/interfaces/IRealmQuoter.sol";
import {IRealmLaunchpad} from "src/interfaces/IRealmLaunchpad.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {TokenState} from "src/types/tokenData.sol";

/// @notice Mainnet-fork regression test for the legacy-token revert.
///
/// `RealmToken`s deployed before sniper-protection do not expose `maxTokenPurchase`. The original
/// `RealmQuoter` called that selector unconditionally, which propagated as an empty revert when
/// invoked from the frontend (`cast call` returned "execution reverted" with no error data).
/// The fix wraps the call in `try/catch` and treats a revert as "no cap".
///
/// `LEGACY_TOKEN` is a real token deployed before sniper-protection. It has since graduated, so
/// the quoter's `_checkValidity` would short-circuit on `LimitReason.GRADUATED` before reaching
/// the try/catch path. To exercise the patched code path we keep the real token bytecode (so
/// `maxTokenPurchase` is genuinely missing) but mock the launchpad's `getTokenState` to flip
/// `graduated=false`, simulating the moment in time when the bug was reachable.
contract RealmQuoterMainnetForkTest is Test {
    address internal constant LEGACY_TOKEN = 0x5cc0846Ea203Ffdad359AD4c31a7DFB2F62E1110;
    address internal constant LAUNCHPAD = 0xd9f8bbe437a3423b725c6616C1B543775ecf1110;

    RealmQuoter internal quoter;
    address internal buyer;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        require(
            address(IRealmLaunchpad(LAUNCHPAD).getTokenConfig(LEGACY_TOKEN).bondingCurve) != address(0),
            "legacy token not registered on mainnet launchpad"
        );
        quoter = new RealmQuoter(LAUNCHPAD);
        buyer = makeAddr("legacy-token-buyer");
    }

    /// @notice Pre-graduated state: synthesise a non-graduated `TokenState` for `LEGACY_TOKEN` so
    ///         the quoter falls through `_checkValidity` and actually reaches the patched
    ///         `_maxEthToSpendForBuyer` path on real legacy bytecode.
    function _mockNonGraduated() internal {
        TokenState memory state = IRealmLaunchpad(LAUNCHPAD).getTokenState(LEGACY_TOKEN);
        state.graduated = false;
        state.ethCollected = 0;
        state.releasedSupply = 0;
        vm.mockCall(
            LAUNCHPAD, abi.encodeWithSelector(IRealmLaunchpad.getTokenState.selector, LEGACY_TOKEN), abi.encode(state)
        );
    }

    /// @notice Sanity check: the legacy token's bytecode lacks `maxTokenPurchase`, so a direct
    ///         call reverts. This is the precondition that breaks the unpatched quoter.
    function test_legacyToken_maxTokenPurchase_reverts() public {
        vm.expectRevert();
        IRealmToken(LEGACY_TOKEN).maxTokenPurchase(buyer);
    }

    /// @notice The fix in action: `getMaxEthToSpend` calls `_maxEthToSpendForBuyer`, which calls
    ///         `maxTokenPurchase` on the legacy token. Pre-fix this revert bubbled out as the
    ///         no-data error the user hit via `cast call`. Post-fix the catch block falls back to
    ///         "no sniper cap" and the quoter returns the launchpad's graduation cap.
    function test_patchedQuoter_getMaxEthToSpend_legacyToken() public {
        _mockNonGraduated();
        (uint256 maxEth, LimitReason reason) = quoter.getMaxEthToSpend(LEGACY_TOKEN, buyer);
        assertGt(maxEth, 0, "maxEth should be positive on a non-graduated legacy token");
        assertEq(uint256(reason), uint256(LimitReason.GRADUATION_EXCESS), "graduation should be the binding cap");
    }
}
