// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

abstract contract FactoryWhitelisting {
    /// @notice Authorized factories
    mapping(address factory => bool authorized) public whitelistedFactories;

    error InvalidAddress();
    error AlreadyConfigured();
    error UnauthorizedFactory();

    event FactoryWhitelisted(address indexed factory);
    event FactoryBlacklisted(address indexed factory);

    modifier onlyWhitelistedFactory() {
        _onlyWhitelistedFactory();
        _;
    }

    function _whitelistFactory(address factory) internal {
        require(factory != address(0), InvalidAddress());
        require(!whitelistedFactories[factory], AlreadyConfigured());

        whitelistedFactories[factory] = true;
        emit FactoryWhitelisted(factory);
    }

    function _blacklistFactory(address factory) internal {
        require(factory != address(0), InvalidAddress());
        require(whitelistedFactories[factory], UnauthorizedFactory());

        whitelistedFactories[factory] = false;
        emit FactoryBlacklisted(factory);
    }

    function _onlyWhitelistedFactory() internal view {
        require(whitelistedFactories[msg.sender], UnauthorizedFactory());
    }
}
