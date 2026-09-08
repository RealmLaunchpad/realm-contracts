// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import {IRealmKeepersRegistry} from "src/interfaces/IRealmKeepersRegistry.sol";

/// @title RealmKeepersRegistry
/// @notice The set of addresses allowed to trigger a Realm token's out-of-band earnings conversions —
///         `processDividends`, `processBurn` and `processLiquidity`.
///
/// @dev WHY THESE CALLS ARE NOT PERMISSIONLESS. Each of them spends up to `MAX_EARNINGS_PER_PROCESS` of
///      a token's buffered earnings on a swap, and each takes its slippage floor from the caller (or,
///      for `processLiquidity`, places a position at whatever price it finds). A permissionless caller
///      picks their own floor, so they can do the whole thing in ONE transaction: push the pool's price
///      as far as they like, call in with a zero floor, unwind. The cost of that round trip is only the
///      pool fee paid twice — around 0.6% of the pool's native reserve for a constant-product pair, and
///      it does NOT grow with how far the price is pushed. The prize is the entire spend. Against
///      anything short of a very deep pool the attacker keeps almost all of it, and no depth threshold
///      fixes that: the depth a pair reports is its NATIVE side, which is exactly the side the attacker's
///      own front-run inflates.
///
/// @dev WHAT THE GATE ACTUALLY BUYS, stated narrowly so nobody over-reads it: the caller can no longer
///      choose the floor. That is all. A keeper's transaction sitting in a public mempool is still
///      sandwichable by anyone; what bounds THAT loss is the tight `minOut` a keeper prices off the live
///      pool, and what avoids it is submitting through private orderflow. The gate removes the free,
///      atomic, risk-free version of the attack. It does not remove MEV.
///
/// @dev TWO TIERS, for the reason every operational allowlist here has two. The owner is a cold multisig
///      that manages admins and nothing else; admins rotate the hot keeper keys, which is a frequent,
///      low-stakes operation that must not need the multisig. A keeper key is not trusted with funds —
///      the worst a rogue keeper can do is exactly what a permissionless caller could do before this
///      contract existed, which is why the hot tier is acceptable.
///
/// @dev NOT UPGRADEABLE, and not behind a proxy, unlike `RealmDividendSwapRegistry`. That one is a proxy
///      because its ELIGIBILITY RULES have to be fixable for tokens that are already live. This contract
///      has no rules — it is a mapping and two setters, and there is nothing in it that could turn out
///      to be wrong. Tokens bake the address in as a constant, so replacing this contract would mean
///      redeploying the implementations; keeping it this dumb is what makes that never necessary.
contract RealmKeepersRegistry is Ownable2Step, IRealmKeepersRegistry {
    /// @notice Addresses allowed to manage the keeper set. The owner manages THIS set; admins manage
    ///         the keepers.
    mapping(address account => bool) public isAdmin;

    /// @inheritdoc IRealmKeepersRegistry
    /// @dev A plain public mapping: the interface's getter and the storage are the same thing.
    mapping(address account => bool) public isKeeper;

    event AdminSet(address indexed account, bool allowed);
    event KeeperSet(address indexed account, bool allowed);

    error NotAdmin();

    modifier onlyAdmin() {
        require(isAdmin[msg.sender] || msg.sender == owner(), NotAdmin());
        _;
    }

    /// @param initialOwner cold multisig: manages admins, nothing else
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Allow or revoke an admin. Owner only.
    function setAdmin(address account, bool allowed) external onlyOwner {
        isAdmin[account] = allowed;
        emit AdminSet(account, allowed);
    }

    /// @notice Allow or revoke a keeper.
    /// @dev Revocation is immediate and total — a keeper holds no funds and has nothing to unwind, so
    ///      there is no reason for this to be anything but a single write.
    function setKeeper(address account, bool allowed) external onlyAdmin {
        isKeeper[account] = allowed;
        emit KeeperSet(account, allowed);
    }
}
