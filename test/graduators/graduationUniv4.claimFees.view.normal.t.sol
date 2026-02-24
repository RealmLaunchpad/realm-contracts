// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UniswapV4ClaimFeesViewFunctionsBase} from "test/graduators/graduationUniv4.claimFees.t.sol";

contract UniswapV4ClaimFeesViewFunctions_NormalToken is UniswapV4ClaimFeesViewFunctionsBase {
    function setUp() public override {
        super.setUp();
    }

    function _expectsSellTaxes() internal pure override returns (bool) {
        return false;
    }
}
