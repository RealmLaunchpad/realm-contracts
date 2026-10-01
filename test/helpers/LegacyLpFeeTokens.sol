// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";

Vm constant LEGACY_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @notice The pre-native-fee token behaviour: a 0-fee pool and the LP fee charged by the hook through
///         `getSwapFees`. The whitelisted hooks still carry that LP-fee path (it serves tokens launched
///         before the change), so their suites exercise it through these.
contract LegacyLpFeeRealmToken is RealmToken {
    function getSwapFees(bool) external view override returns (IRealmToken.RealmTradeFees memory) {
        return IRealmToken.RealmTradeFees({taxBps: 0, lpFeeBps: poolLpFeeBps});
    }

    function poolFee() public pure override returns (uint24) {
        return 0;
    }
}

/// @notice See `LegacyLpFeeRealmToken`.
contract LegacyLpFeeTaxableTokenUniV4 is RealmTaxableTokenUniV4 {
    function getSwapFees(bool isBuy) external view override returns (IRealmToken.RealmTradeFees memory) {
        return IRealmToken.RealmTradeFees({taxBps: _effectiveTaxBps(isBuy), lpFeeBps: poolLpFeeBps});
    }

    function poolFee() public pure override returns (uint24) {
        return 0;
    }
}

/// @notice Swaps the code of the two V4 token implementations for their legacy twins, so every clone the
///         factory mints afterwards behaves as a pre-change token. Storage layouts are identical.
function useLegacyLpFeeTokens(address baseImpl, address taxImpl) {
    LEGACY_VM.etch(baseImpl, address(new LegacyLpFeeRealmToken()).code);
    LEGACY_VM.etch(taxImpl, address(new LegacyLpFeeTaxableTokenUniV4()).code);
}
