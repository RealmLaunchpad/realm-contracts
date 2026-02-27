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
        require(whitelistedFactories[msg.sender], UnauthorizedFactory());
        _;
    }

    function whitelistFactory(address factory) external {
        require(factory != address(0), InvalidAddress());
        require(!whitelistedFactories[factory], AlreadyConfigured());

        whitelistedFactories[factory] = true;
        emit FactoryWhitelisted(factory);
    }

    function blacklistFactory(address factory) external {
        require(whitelistedFactories[factory], UnauthorizedFactory());

        whitelistedFactories[factory] = false;
        emit FactoryBlacklisted(factory);
    }
}
