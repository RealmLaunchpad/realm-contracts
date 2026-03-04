// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

/// @notice This can be used for univ2 or univ4 tokens. Just with different graduators
contract LivoFactoryBase is ILivoFactory {
    /// @notice Token implementation contract used as the clone source
    ILivoToken public immutable TOKEN_IMPLEMENTATION;
    /// @notice Launchpad where tokens are registered after creation
    ILivoLaunchpad public immutable LAUNCHPAD;
    /// @notice Graduator contract that handles token graduation to Uniswap
    ILivoGraduator public immutable GRADUATOR;
    /// @notice Bonding curve used for token pricing before graduation
    ILivoBondingCurve public immutable BONDING_CURVE;
    /// @notice Fee handler contract for managing creator and treasury fees
    ILivoFeeHandler public immutable FEE_HANDLER;

    /// @notice Initializes the factory with its immutable dependencies
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

    /// @notice Deploys a new token clone, initializes it, and registers it in the launchpad
    /// @dev tokenOwner wont receive any fees, he needs to claim them manually. This avoids unwanted ETH fees from project tokenOwner doesn't specifically endorse
    function createToken(string calldata name, string calldata symbol, address tokenOwner, bytes32 salt)
        external
        returns (address token)
    {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 32, InvalidNameOrSymbol());
        require(tokenOwner != address(0), InvalidTokenOwner());

        // forge-lint: disable-next-line
        bytes32 salt_ = keccak256(abi.encodePacked(msg.sender, block.timestamp, symbol, salt));
        // minimal proxy pattern to deploy a new LivoToken instance
        // Deploying the contracts with new() costs 3-4 times more gas than cloning
        // trading will be a bit more expensive, as variables cannot be immutable
        token = Clones.cloneDeterministic(address(TOKEN_IMPLEMENTATION), salt_);

        // emit the event here for off-chain indexers
        emit TokenCreated(
            token,
            name,
            symbol,
            tokenOwner, // token owner
            address(LAUNCHPAD),
            address(GRADUATOR),
            address(FEE_HANDLER),
            tokenOwner // fee receiver
        );

        // Creates the Uniswap Pair or whatever other initialization is necessary
        // in the case of univ4, the pair will be the address of the pool manager,
        // to which tokens cannot be transferred until graduation
        address pair = GRADUATOR.initialize(token);

        // the token needs to be initialized with the pair, so we have to do it after graduator.initialize
        LivoToken(token)
            .initialize(
                ILivoToken.InitializeParams({
                    name: name,
                    symbol: symbol,
                    tokenOwner: tokenOwner,
                    graduator: address(GRADUATOR),
                    pair: pair,
                    launchpad: address(LAUNCHPAD),
                    feeHandler: address(FEE_HANDLER),
                    feeReceiver: tokenOwner
                })
            );

        // registers token in launchpad together with its components and configs
        // this will also emit an event from the launchpad
        LAUNCHPAD.launchToken(token, BONDING_CURVE);

        return token;
    }
}
