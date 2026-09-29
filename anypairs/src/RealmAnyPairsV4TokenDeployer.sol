// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RealmAnyPairsTokenPlain} from "./RealmAnyPairsTokenPlain.sol";
import {RealmAnyPairsTokenDividend} from "./RealmAnyPairsTokenDividend.sol";
import {RealmAnyPairsDividendTracker} from "./RealmAnyPairsDividendTracker.sol";

/// @title RealmAnyPairsV4TokenDeployer
/// @notice External (linked) library holding the token/tracker creation bytecode, so it lives in a separately deployed
///         contract instead of inside every launcher.
/// @dev Every token is deployed with CREATE2 and MUST end in {TOKEN_SUFFIX} (0x1110). The salt is bound to
///      the launch caller, so a mined salt is useless to anyone else. DELEGATECALLed by the launcher:
///      `address(this)` is the launcher (CREATE2 deployer), `msg.sender` is the launch caller.
///      {_saltFor}, the init-hash helpers and {_create2Address} are the single address derivation; deploy*,
///      predict* and initCodeHash* must all use them so mined and deployed addresses never diverge.
library RealmAnyPairsV4TokenDeployer {
    /// @notice Every Realm AnyPairs token address ends in these two bytes.
    uint16 internal constant TOKEN_SUFFIX = 0x1110;

    /// @dev The predicted address already holds code: this (caller, salt, init code) was already launched.
    error SaltAlreadyUsed(address predicted);
    /// @dev The deployed address does not end in {TOKEN_SUFFIX}: the salt was not mined for this exact caller, launcher
    /// and set of constructor arguments.
    error InvalidTokenAddress(address token);

    // ── deploys (delegatecalled: address(this) = launcher = CREATE2 deployer, msg.sender = launch caller) ──

    function deployPlain(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        address launcher,
        address creator,
        uint256 maxWallet,
        uint32 maxWalletSecs,
        address[] calldata exempt,
        bytes32 userSalt
    ) external returns (address token) {
        bytes32 salt = _saltFor(msg.sender, userSalt);
        address predicted = _create2Address(
            address(this), salt, _initHashPlain(name, symbol, totalSupply, launcher, creator, maxWallet, maxWalletSecs, exempt)
        );
        if (predicted.code.length != 0) revert SaltAlreadyUsed(predicted);
        token = address(new RealmAnyPairsTokenPlain{salt: salt}(name, symbol, totalSupply, launcher, creator, maxWallet, maxWalletSecs, exempt));
        if (uint16(uint160(token)) != TOKEN_SUFFIX) revert InvalidTokenAddress(token);
    }

    function deployDividend(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        address launcher,
        address creator,
        uint256 maxWallet,
        uint32 maxWalletSecs,
        address[] calldata exempt,
        bytes32 userSalt
    ) external returns (address token) {
        bytes32 salt = _saltFor(msg.sender, userSalt);
        address predicted = _create2Address(
            address(this), salt, _initHashDividend(name, symbol, totalSupply, launcher, creator, maxWallet, maxWalletSecs, exempt)
        );
        if (predicted.code.length != 0) revert SaltAlreadyUsed(predicted);
        token = address(new RealmAnyPairsTokenDividend{salt: salt}(name, symbol, totalSupply, launcher, creator, maxWallet, maxWalletSecs, exempt));
        if (uint16(uint160(token)) != TOKEN_SUFFIX) revert InvalidTokenAddress(token);
    }

    // Native rewards tracker, called by {RealmAnyPairsV4UnifiedLauncher._deployNativeTracker}.
    function deployTracker(RealmAnyPairsDividendTracker.Config memory c) external returns (address) {
        return address(new RealmAnyPairsDividendTracker(c));
    }

    // ── init code hashes: what a miner hashes against (publish these per deployment) ──

    function initCodeHashPlain(
        string calldata name, string calldata symbol, uint256 totalSupply, address launcher, address creator,
        uint256 maxWallet, uint32 maxWalletSecs, address[] calldata exempt
    ) external pure returns (bytes32) {
        return _initHashPlain(name, symbol, totalSupply, launcher, creator, maxWallet, maxWalletSecs, exempt);
    }

    function initCodeHashDividend(
        string calldata name, string calldata symbol, uint256 totalSupply, address launcher, address creator,
        uint256 maxWallet, uint32 maxWalletSecs, address[] calldata exempt
    ) external pure returns (bytes32) {
        return _initHashDividend(name, symbol, totalSupply, launcher, creator, maxWallet, maxWalletSecs, exempt);
    }

    // ── predicts (pure; caller and deployer passed explicitly) ──

    /// @notice The address a launch by `caller` through `launcher` deploys to. `launcher` is both the CREATE2 deployer
    /// and the token's `launcher` constructor argument, which is every deploy this system performs.
    function predictPlain(
        address caller, string calldata name, string calldata symbol, uint256 totalSupply, address launcher,
        address creator, uint256 maxWallet, uint32 maxWalletSecs, address[] calldata exempt, bytes32 userSalt
    ) external pure returns (address) {
        return _create2Address(
            launcher, _saltFor(caller, userSalt),
            _initHashPlain(name, symbol, totalSupply, launcher, creator, maxWallet, maxWalletSecs, exempt)
        );
    }

    /// @notice {predictPlain} with the CREATE2 `deployer` named separately from the constructor's `launcher`.
    function predictPlainAt(
        address deployer, address caller, string calldata name, string calldata symbol, uint256 totalSupply,
        address launcher, address creator, uint256 maxWallet, uint32 maxWalletSecs, address[] calldata exempt,
        bytes32 userSalt
    ) external pure returns (address) {
        return _create2Address(
            deployer, _saltFor(caller, userSalt),
            _initHashPlain(name, symbol, totalSupply, launcher, creator, maxWallet, maxWalletSecs, exempt)
        );
    }

    function predictDividend(
        address caller, string calldata name, string calldata symbol, uint256 totalSupply, address launcher,
        address creator, uint256 maxWallet, uint32 maxWalletSecs, address[] calldata exempt, bytes32 userSalt
    ) external pure returns (address) {
        return _create2Address(
            launcher, _saltFor(caller, userSalt),
            _initHashDividend(name, symbol, totalSupply, launcher, creator, maxWallet, maxWalletSecs, exempt)
        );
    }

    function predictDividendAt(
        address deployer, address caller, string calldata name, string calldata symbol, uint256 totalSupply,
        address launcher, address creator, uint256 maxWallet, uint32 maxWalletSecs, address[] calldata exempt,
        bytes32 userSalt
    ) external pure returns (address) {
        return _create2Address(
            deployer, _saltFor(caller, userSalt),
            _initHashDividend(name, symbol, totalSupply, launcher, creator, maxWallet, maxWalletSecs, exempt)
        );
    }

    // ── THE derivation ──

    /// @dev The caller-bound CREATE2 salt. Internal so launchers can use it without embedding creation code.
    function _saltFor(address caller, bytes32 userSalt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(caller, userSalt));
    }

    /// @dev The CREATE2 address formula. Internal for the same reason as {_saltFor}.
    function _create2Address(address deployer, bytes32 salt, bytes32 initHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
    }

    function _initHashPlain(
        string calldata name, string calldata symbol, uint256 totalSupply, address launcher, address creator,
        uint256 maxWallet, uint32 maxWalletSecs, address[] calldata exempt
    ) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            type(RealmAnyPairsTokenPlain).creationCode,
            abi.encode(name, symbol, totalSupply, launcher, creator, maxWallet, maxWalletSecs, exempt)
        ));
    }

    function _initHashDividend(
        string calldata name, string calldata symbol, uint256 totalSupply, address launcher, address creator,
        uint256 maxWallet, uint32 maxWalletSecs, address[] calldata exempt
    ) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            type(RealmAnyPairsTokenDividend).creationCode,
            abi.encode(name, symbol, totalSupply, launcher, creator, maxWallet, maxWalletSecs, exempt)
        ));
    }
}
