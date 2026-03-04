// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

abstract contract FactoryWhitelisting {
    /// @notice Authorized factories
    mapping(address factory => bool authorized) public whitelistedFactories;

    //////////////////////// ERRORS ///////////////////////

    error InvalidAddress();
    error AlreadyConfigured();
    error UnauthorizedFactory();

    //////////////////// EVENTS ///////////////////////

    event FactoryWhitelisted(address indexed factory);
    event FactoryBlacklisted(address indexed factory);

    ////////////////// MODIFIERS ///////////////////////

    modifier onlyWhitelistedFactory() {
        _onlyWhitelistedFactory();
        _;
    }

    ////////////// INTERNAL FUNCTIONS //////////////////

    /// @dev Internal function without access control.
    function _whitelistFactory(address factory) internal {
        require(factory != address(0), InvalidAddress());
        require(!whitelistedFactories[factory], AlreadyConfigured());

        whitelistedFactories[factory] = true;
        emit FactoryWhitelisted(factory);
    }

    /// @dev Internal function without access control.
    function _blacklistFactory(address factory) internal {
        require(factory != address(0), InvalidAddress());
        require(whitelistedFactories[factory], UnauthorizedFactory());

        whitelistedFactories[factory] = false;
        emit FactoryBlacklisted(factory);
    }

    /// @notice Reverts if the caller is not a whitelisted factory
    function _onlyWhitelistedFactory() internal view {
        require(whitelistedFactories[msg.sender], UnauthorizedFactory());
    }
}
