// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";

/// @notice This can be used for univ2 or univ4 tokens. Just with different graduators
contract LivoFactoryBase {
    error InvalidNameOrSymbol();
    error InvalidTokenOwner();

    ILivoToken public immutable TOKEN_IMPLEMENTATION;
    ILivoLaunchpad public immutable LAUNCHPAD;
    ILivoGraduator public immutable GRADUATOR;
    ILivoBondingCurve public immutable BONDING_CURVE;
    ILivoFeeHandler public immutable FEE_HANDLER;

    constructor(
        address launchpad,
        address tokenImplementation,
        address bondingCurve,
        address graduator,
        address feeHandler
    ) {
        LAUNCHPAD = ILivoLaunchpad(launchpad);
        TOKEN_IMPLEMENTATION = ILivoToken(tokenImplementation);
        BONDING_CURVE = ILivoBondingCurve(bondingCurve);
        GRADUATOR = ILivoGraduator(graduator);
        FEE_HANDLER = ILivoFeeHandler(feeHandler);
    }

    /// @dev tokenOwner wont receive any fees, he needs to claim them manually. This avoids unwanted ETH fees from project tokenOwner doesn't specifically endorse
    function createToken(string calldata name, string calldata symbol, address tokenOwner, bytes32 salt)
        external
        returns (address token)
    {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 32, InvalidNameOrSymbol());
        require(tokenOwner != address(0), InvalidTokenOwner());

        bytes32 salt_ = keccak256(abi.encodePacked(msg.sender, block.timestamp, symbol, salt));
        // minimal proxy pattern to deploy a new LivoToken instance
        // Deploying the contracts with new() costs 3-4 times more gas than cloning
        // trading will be a bit more expensive, as variables cannot be immutable
        token = Clones.cloneDeterministic(address(TOKEN_IMPLEMENTATION), salt_);

        // Creates the Uniswap Pair or whatever other initialization is necessary
        // in the case of univ4, the pair will be the address of the pool manager,
        // to which tokens cannot be transferred until graduation
        address pair = GRADUATOR.initialize(token);

        // the token needs to be initialized with the pair, so we have to do it after graduator.initialize
        ILivoToken(token)
            .initialize(
                name,
                symbol,
                tokenOwner,
                address(GRADUATOR), // graduator address
                pair, // uniswap pair
                address(LAUNCHPAD), // supply receiver, all tokens are held by the launchpad initially
                "" // todo get rid of tokenCallData since initialize happens in factories, not in launchpad
            );

        // registers token in launchpad together with its components and configs
        LAUNCHPAD.launchToken(token, BONDING_CURVE);

        // TODO decide what event is emitted from here and what from the launchpad
        return token;
    }
}
