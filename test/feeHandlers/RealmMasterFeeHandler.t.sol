// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {RealmMasterFeeHandler} from "src/feeHandlers/RealmMasterFeeHandler.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice Owner-controlled contract that, on every received ETH, attempts to reenter
///         `setShares` on the master fee handler. Used to verify the `nonReentrant` guard
///         shared between `depositFees` and `setShares` blocks the reentry path.
contract ReenterOnReceive {
    RealmMasterFeeHandler public immutable handler;
    address public token;
    bool public attackTriggered;

    constructor(RealmMasterFeeHandler _handler) {
        handler = _handler;
    }

    function setToken(address _token) external {
        token = _token;
    }

    function callCreateToken(address factory, bytes calldata data) external payable returns (address newToken) {
        (bool ok, bytes memory ret) = factory.call{value: msg.value}(data);
        require(ok, "factory call failed");
        newToken = abi.decode(ret, (address));
    }

    receive() external payable {
        if (token == address(0)) return;
        attackTriggered = true;
        // Build a single-entry FeeShare[] that, if applied, would wipe the current direct
        // set. The reentry must revert because `setShares` shares the transient `nonReentrant`
        // guard with the in-flight `depositFees`.
        IRealmFactory.FeeShare[] memory newShares = new IRealmFactory.FeeShare[](1);
        newShares[0] = IRealmFactory.FeeShare({account: address(0xBEEF), shares: 10_000, directFeesEnabled: false});
        handler.setShares(token, newShares);
    }
}

contract RealmMasterFeeHandlerReentrancyTest is LaunchpadBaseTestsWithUniv4Graduator {
    ReenterOnReceive internal malicious;
    address internal eoaClaimable = makeAddr("eoaClaimable");

    function setUp() public override {
        super.setUp();
        malicious = new ReenterOnReceive(feeHandler);
    }

    /// @dev Builds a 2-entry FeeShare[]: malicious as direct (50%), EOA as claimable (50%).
    function _feeShares() internal view returns (IRealmFactory.FeeShare[] memory arr) {
        arr = new IRealmFactory.FeeShare[](2);
        arr[0] = IRealmFactory.FeeShare({account: address(malicious), shares: 5_000, directFeesEnabled: true});
        arr[1] = IRealmFactory.FeeShare({account: eoaClaimable, shares: 5_000, directFeesEnabled: false});
    }

    /// @dev Malicious-owner direct receiver tries to reenter `setShares` from `receive()`.
    ///      The nonReentrant guard blocks the inner `setShares` → outer `.call` returns false →
    ///      slice is preserved as a pending claim. Outer `depositFees` does NOT revert, so the
    ///      swap/graduation hot path stays alive.
    function test_setSharesReentryFromDirectReceiver_doesNotDosDepositFees() public {
        // Deploy a token with malicious as tokenOwner + direct fee receiver, EOA as claimable.
        vm.prank(address(malicious));
        address token = factoryV4Unified.createToken(
            "AttackToken",
            "ATTK",
            _nextValidSalt(address(factoryV4Unified), address(realmToken), address(malicious)),
            _feeShares(),
            _noSs(),
            false, // do NOT renounce — owner = msg.sender = malicious
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );
        malicious.setToken(token);

        assertEq(IRealmToken(token).owner(), address(malicious), "owner = malicious");
        assertTrue(feeHandler.isDirectReceiver(token, address(malicious)), "malicious is direct");

        uint256 deposit = 1 ether;
        vm.deal(address(this), deposit);

        // Sanity: handler holds nothing for this token before the deposit.
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory before = feeHandler.getClaimable(tokens, address(malicious));
        assertEq(before[0], 0, "no pending pre-deposit");

        // Trigger the deposit. The reentry attempt MUST not propagate as a revert.
        feeHandler.depositFees{value: deposit}(token);

        // The reentered setShares reverted, so the slice fell back to pending.
        uint256[] memory afterAtk = feeHandler.getClaimable(tokens, address(malicious));
        assertEq(afterAtk[0], deposit / 2, "malicious slice routed to pending");

        // Claimable EOA accumulated normally.
        uint256[] memory eoaPending = feeHandler.getClaimable(tokens, eoaClaimable);
        assertEq(eoaPending[0], deposit / 2, "EOA accumulator advanced");

        // Direct config was NOT mutated by the failed reentry.
        assertTrue(feeHandler.isDirectReceiver(token, address(malicious)), "still direct");
        address[] memory directs = feeHandler.getDirectReceivers(token);
        assertEq(directs.length, 1, "directReceivers untouched");
        assertEq(directs[0], address(malicious), "direct still malicious");

        // Malicious can recover the failed slice by claiming.
        // First disable the reentry trigger so the malicious receive() doesn't try to attack
        // again when receiving the claim payout (claim() is also nonReentrant and would revert).
        malicious.setToken(address(0));

        uint256 ethBefore = address(malicious).balance;
        vm.prank(address(malicious));
        feeHandler.claim(tokens);
        assertEq(address(malicious).balance - ethBefore, deposit / 2, "claim paid out");
    }
}

contract RealmMasterFeeHandlerAccessControlTest is LaunchpadBaseTestsWithUniv4Graduator {
    address internal token;

    function setUp() public override {
        super.setUp();

        vm.prank(creator);
        token = factoryV4Unified.createToken(
            "AccessToken",
            "ACCS",
            _nextValidSalt(address(factoryV4Unified), address(realmToken)),
            _fs(creator),
            _noSs(),
            false,
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );
    }

    function _assertSingleRecipient(address targetToken, address expectedRecipient) internal view {
        (address[] memory recipients, uint256[] memory shares) = feeHandler.getRecipients(targetToken);
        assertEq(recipients.length, 1, "recipient length");
        assertEq(recipients[0], expectedRecipient, "recipient");
        assertEq(shares[0], 10_000, "share");
    }

    function _createRenouncedToken() internal returns (address renouncedToken) {
        vm.prank(creator);
        renouncedToken = factoryV4Unified.createToken(
            "RenouncedToken",
            "RNCD",
            _nextValidSalt(address(factoryV4Unified), address(realmToken)),
            _fs(creator),
            _noSs(),
            true,
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );
        assertEq(IRealmToken(renouncedToken).owner(), address(0), "renounced token owner");
    }

    function test_setShares_tokenOwnerCanUpdate() public {
        vm.prank(creator);
        feeHandler.setShares(token, _fs(alice));

        _assertSingleRecipient(token, alice);
    }

    function test_setShares_handlerOwnerCanUpdate() public {
        assertEq(feeHandler.owner(), admin, "handler owner");

        vm.prank(admin);
        feeHandler.setShares(token, _fs(alice));

        _assertSingleRecipient(token, alice);
    }

    function test_setShares_revertsForNonHandlerOwnerOrTokenOwner() public {
        vm.prank(bob);
        vm.expectRevert(IRealmMasterFeeHandler.Unauthorized.selector);
        feeHandler.setShares(token, _fs(alice));
    }

    function test_setShares_handlerOwnerCanUpdateRenouncedToken() public {
        address renouncedToken = _createRenouncedToken();

        vm.prank(admin);
        feeHandler.setShares(renouncedToken, _fs(alice));

        _assertSingleRecipient(renouncedToken, alice);
    }

    function test_setShares_originalCreatorCannotUpdateRenouncedToken() public {
        address renouncedToken = _createRenouncedToken();

        vm.prank(creator);
        vm.expectRevert(IRealmMasterFeeHandler.Unauthorized.selector);
        feeHandler.setShares(renouncedToken, _fs(alice));
    }
}

contract RealmMasterFeeHandlerDirectReceiverCapTest is LaunchpadBaseTestsWithUniv4Graduator {
    address internal d0 = makeAddr("d0");
    address internal d1 = makeAddr("d1");
    address internal d2 = makeAddr("d2");
    address internal d3 = makeAddr("d3");
    address internal d4 = makeAddr("d4");

    address internal token;

    function setUp() public override {
        super.setUp();
        // Plain V4 token, owner = creator, single claimable fee receiver.
        vm.prank(creator);
        token = factoryV4Unified.createToken(
            "CapToken",
            "CAP",
            _nextValidSalt(address(factoryV4Unified), address(realmToken)),
            _fs(creator),
            _noSs(),
            false,
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );
    }

    function _shares(address[] memory directs) internal pure returns (IRealmFactory.FeeShare[] memory arr) {
        uint256 n = directs.length;
        arr = new IRealmFactory.FeeShare[](n);
        // Equal split, BPS sums to 10_000 (with last entry absorbing rounding).
        uint256 each = 10_000 / n;
        uint256 acc;
        for (uint256 i = 0; i < n - 1; i++) {
            arr[i] = IRealmFactory.FeeShare({account: directs[i], shares: each, directFeesEnabled: true});
            acc += each;
        }
        arr[n - 1] = IRealmFactory.FeeShare({account: directs[n - 1], shares: 10_000 - acc, directFeesEnabled: true});
    }

    function test_registerToken_rejectsNonTokenCaller() public {
        vm.prank(alice);
        vm.expectRevert(IRealmMasterFeeHandler.Unauthorized.selector);
        feeHandler.registerToken(_fs(alice));
    }

    function test_tokenRegisterFees_rejectsNonFactoryCaller() public {
        vm.prank(creator);
        vm.expectRevert(IRealmMasterFeeHandler.Unauthorized.selector);
        IRealmToken(token).registerFees(_fs(alice));
    }

    function test_setShares_acceptsFourDirectReceivers() public {
        address[] memory directs = new address[](4);
        directs[0] = d0;
        directs[1] = d1;
        directs[2] = d2;
        directs[3] = d3;

        vm.prank(creator);
        feeHandler.setShares(token, _shares(directs));

        address[] memory got = feeHandler.getDirectReceivers(token);
        assertEq(got.length, 4, "4 directs accepted");
    }

    function test_setShares_rejectsFiveDirectReceivers() public {
        address[] memory directs = new address[](5);
        directs[0] = d0;
        directs[1] = d1;
        directs[2] = d2;
        directs[3] = d3;
        directs[4] = d4;

        vm.prank(creator);
        vm.expectRevert(IRealmMasterFeeHandler.TooManyDirectReceivers.selector);
        feeHandler.setShares(token, _shares(directs));
    }
}

/// @notice Pins the invariant: a recipient that switches from `direct` to `claimable` does NOT
///         retroactively earn from the pre-reclassification accumulator. Their pre-existing direct
///         payouts were already delivered synchronously; the accumulator was advanced only for the
///         claimable cohort, so there is no slice owed to the reclassified account.
contract RealmMasterFeeHandlerReclassificationTest is LaunchpadBaseTestsWithUniv4Graduator {
    address internal directRecipient = makeAddr("direct");
    address internal claimableRecipient = makeAddr("claimable");
    address internal token;

    function setUp() public override {
        super.setUp();

        IRealmFactory.FeeShare[] memory fs = new IRealmFactory.FeeShare[](2);
        fs[0] = IRealmFactory.FeeShare({account: directRecipient, shares: 5_000, directFeesEnabled: true});
        fs[1] = IRealmFactory.FeeShare({account: claimableRecipient, shares: 5_000, directFeesEnabled: false});

        vm.prank(creator);
        token = factoryV4Unified.createToken(
            "Reclass",
            "RCL",
            _nextValidSalt(address(factoryV4Unified), address(realmToken)),
            fs,
            _noSs(),
            false,
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );
    }

    function test_directBecomesClaimable_doesNotInheritAccumulatedFees() public {
        address[] memory tokens_ = new address[](1);
        tokens_[0] = token;

        // 1) Accrue fees: direct receives synchronously, claimable accrues via accumulator.
        uint256 deposit = 1 ether;
        vm.deal(address(this), deposit);
        feeHandler.depositFees{value: deposit}(token);

        assertEq(directRecipient.balance, deposit / 2, "direct received synchronous slice");

        uint256[] memory directPending = feeHandler.getClaimable(tokens_, directRecipient);
        assertEq(directPending[0], 0, "direct has zero pending after successful forward");

        uint256[] memory claimablePending = feeHandler.getClaimable(tokens_, claimableRecipient);
        assertEq(claimablePending[0], deposit / 2, "claimable accrued half via accumulator");

        // 2) Reclassify the previously-direct receiver as claimable (same shares).
        IRealmFactory.FeeShare[] memory newFs = new IRealmFactory.FeeShare[](2);
        newFs[0] = IRealmFactory.FeeShare({account: directRecipient, shares: 5_000, directFeesEnabled: false});
        newFs[1] = IRealmFactory.FeeShare({account: claimableRecipient, shares: 5_000, directFeesEnabled: false});
        vm.prank(creator);
        feeHandler.setShares(token, newFs);

        // 3) Critical invariant: the now-claimable receiver has ZERO claimable. Their direct slice
        //    was paid in step 1; they were never part of the accumulator before the reconfig.
        uint256[] memory afterReclass = feeHandler.getClaimable(tokens_, directRecipient);
        assertEq(afterReclass[0], 0, "reclassified receiver MUST NOT inherit accumulator credit");

        // 4) Sanity: original claimable's pending is preserved (snapshot moved accrual to pending).
        uint256[] memory claimableAfter = feeHandler.getClaimable(tokens_, claimableRecipient);
        assertEq(claimableAfter[0], deposit / 2, "original claimable slice preserved across reconfig");

        // 5) New deposit splits 50/50 across both as claimables — both accrue from this point on.
        vm.deal(address(this), deposit);
        feeHandler.depositFees{value: deposit}(token);

        uint256[] memory directPostNew = feeHandler.getClaimable(tokens_, directRecipient);
        assertEq(directPostNew[0], deposit / 2, "now-claimable accrues only from post-reconfig deposits");

        uint256[] memory claimablePostNew = feeHandler.getClaimable(tokens_, claimableRecipient);
        assertEq(claimablePostNew[0], deposit, "original claimable: pre-reconfig pending + post-reconfig accrual");
    }
}
