// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTest} from "test/launchpad/base.t.sol";
import {LivoToken} from "src/LivoToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";

contract BaseUniswapV2GraduationTests is LaunchpadBaseTest {

    address poolManagerAddress = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address positionManagerAddress = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    // IUniversalRouter public immutable universalRouter = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    // IPermit2 public immutable permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3); // review if this is needed

    LivoGraduatorUniswapV4 graduator;

    function setUp() public override {
        super.setUp();
        
        graduator = new LivoGraduatorUniswapV4(address(launchpad), poolManagerAddress, positionManagerAddress);
    }

    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
    // todo test that 
}