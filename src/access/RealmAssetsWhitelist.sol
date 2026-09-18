// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title RealmAssetsWhitelist
/// @notice The ERC20 assets the protocol has vetted, each with its value in the chain's native currency.
///         An asset is whitelisted while its `unitsPerNativeX18` is non-zero.
///
/// @dev TWO TIERS, like every operational allowlist here, but stricter at the top: the owner is a cold
///      multisig that manages APPROVERS and cannot whitelist anything itself. Approvers are hot keys
///      (an agent reviewing listing requests) doing the frequent, low-stakes work.
///
/// @dev THE RATE IS IN WHOLE UNITS, never raw ones: 3,500 USDC per ETH is `3500e18` whatever the asset's
///      decimals. Consumers apply `decimals()` themselves, so a 6- and an 18-decimal asset of equal value
///      carry the same rate.
///
/// @dev NOT UPGRADEABLE: a mapping, a role and two setters, with nothing in it that could turn out wrong.
contract RealmAssetsWhitelist is Ownable2Step {
    /// @notice Addresses allowed to whitelist assets. Managed by the owner.
    mapping(address account => bool) public isApprover;

    /// @notice Whole units of `asset` worth one whole unit of the chain's native currency, scaled by 1e18.
    ///         Zero means not whitelisted.
    mapping(address asset => uint256) public unitsPerNativeX18;

    event ApproverSet(address indexed account, bool allowed);
    event WhitelistUpdated(address indexed asset, uint256 unitsPerNativeX18);

    error NotApprover();

    /// @param initialOwner cold multisig: manages approvers, nothing else
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Allow or revoke an approver. Owner only.
    function setApprover(address account, bool allowed) external onlyOwner {
        isApprover[account] = allowed;
        emit ApproverSet(account, allowed);
    }

    /// @notice Whitelist `asset` at `unitsPerNative` (whole units per native coin, scaled by 1e18), update
    ///         its rate, or remove it with zero. Approvers only.
    function setWhitelisted(address asset, uint256 unitsPerNative) external {
        require(isApprover[msg.sender], NotApprover());
        unitsPerNativeX18[asset] = unitsPerNative;
        emit WhitelistUpdated(asset, unitsPerNative);
    }
}
