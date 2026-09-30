// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {MasterFeeHandlerTestHelpers, MockMasterFeeToken} from "test/helpers/MasterFeeHandlerTestHelpers.sol";
import {RealmMasterFeeHandler} from "src/feeHandlers/RealmMasterFeeHandler.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @dev Token double that also pays its fees in an ERC20, as a real token's `accrueFees(asset, amount)` does.
contract MockAssetPayingToken is MockMasterFeeToken {
    constructor(RealmMasterFeeHandler handler_, address owner_) MockMasterFeeToken(handler_, owner_) {}

    function accrueFees(address asset, uint256 amount) external {
        IERC20(asset).approve(address(feeHandler), amount);
        feeHandler.depositFees(address(this), asset, amount);
    }
}

/// @dev Mintable ERC20 whose `transfer` misbehaves while `broken`; each subclass picks how.
///      A broken transfer never moves funds, so a banked slice can never be paid twice.
contract MockAsset is ERC20 {
    bool public broken;

    constructor() ERC20("Asset", "AST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBroken(bool broken_) external {
        broken = broken_;
    }
}

contract FalseReturningAsset is MockAsset {
    function transfer(address to, uint256 value) public override returns (bool) {
        if (broken) return false;
        return super.transfer(to, value);
    }
}

contract RevertingAsset is MockAsset {
    function transfer(address to, uint256 value) public override returns (bool) {
        require(!broken, "transfer blocked");
        return super.transfer(to, value);
    }
}

/// @dev USDT-style: `transfer` returns no data at all, and reverts with no data while broken.
contract NoReturnDataAsset is MockAsset {
    function transfer(address to, uint256 value) public override returns (bool) {
        if (broken) revert();
        _transfer(msg.sender, to, value);
        assembly {
            return(0, 0)
        }
    }
}

/// @dev Returns a single non-zero byte while broken: truthy if read without a length check.
contract ShortReturnDataAsset is MockAsset {
    function transfer(address to, uint256 value) public override returns (bool) {
        if (broken) {
            assembly {
                mstore(0, shl(248, 1))
                return(0, 1)
            }
        }
        return super.transfer(to, value);
    }
}

/// @dev Burns every unit of gas it is given while broken.
contract GasBurningAsset is MockAsset {
    function transfer(address to, uint256 value) public override returns (bool) {
        if (broken) {
            assembly {
                for {} 1 {} {}
            }
        }
        return super.transfer(to, value);
    }
}

/// @dev Burns 10% of every non-mint, non-burn movement.
contract FeeOnTransferAsset is MockAsset {
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) return super._update(from, to, value);
        uint256 fee = value / 10;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

/// @notice ERC20 fees on the master handler: direct forwarding and its fallback, per-asset accounting on
///         split configs, the implicit-native asset list, and the ERC20 deposit gates.
contract RealmMasterFeeHandlerMultiAssetTests is MasterFeeHandlerTestHelpers {
    address internal dave = makeAddr("dave");

    MockAsset internal assetA;
    MockAsset internal assetB;

    function setUp() public override {
        super.setUp();
        assetA = new MockAsset();
        assetB = new MockAsset();
    }

    function _newAssetToken(IRealmFactory.FeeShare[] memory shares) internal returns (MockAssetPayingToken token) {
        token = new MockAssetPayingToken(handler, creator);
        token.registerFees(shares);
    }

    function _depositAsset(MockAssetPayingToken token, MockAsset asset, uint256 amount) internal {
        asset.mint(address(token), amount);
        token.accrueFees(address(asset), amount);
    }

    function _claimableIn(MockAssetPayingToken token, address asset, address account) internal view returns (uint256) {
        return handler.getClaimable(_single(address(token)), asset, account)[0];
    }

    function _claimAssetAs(address account, MockAssetPayingToken token, MockAsset asset) internal {
        vm.prank(account);
        handler.claim(_single(address(token)), address(asset));
    }

    /// @dev Every handler log in `logs`, filtered from the asset's own Transfer/Approval noise.
    function _handlerLogs(Vm.Log[] memory logs) internal view returns (Vm.Log[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(handler)) n++;
        }
        out = new Vm.Log[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(handler)) out[n++] = logs[i];
        }
    }

    /// @dev A direct receiver whose ERC20 forward fails: the deposit still lands, only the deposit event is
    ///      emitted, the slice is banked as pending, and `claim(tokens, asset)` pays it once transfers work.
    function _assertFailedForwardIsBankedThenClaimed(MockAsset asset) internal {
        MockAssetPayingToken token = _newAssetToken(_fsDirect(alice));
        asset.setBroken(true);

        vm.recordLogs();
        _depositAsset(token, asset, 1_000e18);
        Vm.Log[] memory logs = _handlerLogs(vm.getRecordedLogs());
        assertEq(logs.length, 1, "only the deposit event, no CreatorAssetClaimed");
        assertEq(logs[0].topics[0], IRealmMasterFeeHandler.CreatorAssetFeesDeposited.selector, "deposit event");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(token)))), "deposit event token");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(asset)))), "deposit event asset");
        assertEq(abi.decode(logs[0].data, (uint256)), 1_000e18, "deposit event amount");

        assertEq(asset.balanceOf(alice), 0, "nothing delivered");
        assertEq(asset.balanceOf(address(handler)), 1_000e18, "handler holds the slice");
        assertEq(_claimableIn(token, address(asset), alice), 1_000e18, "slice banked as pending");

        asset.setBroken(false);
        vm.expectEmit(address(handler));
        emit IRealmMasterFeeHandler.CreatorAssetClaimed(address(token), address(asset), alice, 1_000e18);
        _claimAssetAs(alice, token, asset);

        assertEq(asset.balanceOf(alice), 1_000e18, "paid on claim");
        assertEq(asset.balanceOf(address(handler)), 0, "nothing left behind");
        assertEq(_claimableIn(token, address(asset), alice), 0, "ledger closed");
    }

    // ======================== ERC20 direct receivers ========================

    /// @dev A single direct receiver is paid the whole ERC20 deposit synchronously, with both events.
    function test_directAsset_single_paidOnDeposit() public {
        MockAssetPayingToken token = _newAssetToken(_fsDirect(alice));
        assetA.mint(address(token), 1_000e18);

        vm.expectEmit(address(handler));
        emit IRealmMasterFeeHandler.CreatorAssetFeesDeposited(address(token), address(assetA), 1_000e18);
        vm.expectEmit(address(handler));
        emit IRealmMasterFeeHandler.CreatorAssetClaimed(address(token), address(assetA), alice, 1_000e18);
        token.accrueFees(address(assetA), 1_000e18);

        assertEq(assetA.balanceOf(alice), 1_000e18, "forwarded on deposit");
        assertEq(assetA.balanceOf(address(handler)), 0, "handler keeps nothing");
        assertEq(_claimableIn(token, address(assetA), alice), 0, "nothing pending");
    }

    /// @dev On a split, the direct receiver is paid its ERC20 slice on deposit and the rest accrues.
    function test_directAsset_split_paysSliceAndAccruesRest() public {
        MockAssetPayingToken token = _newAssetToken(_fs2(alice, 3_000, true, bob, 7_000, false));
        assetA.mint(address(token), 1_000e18);

        vm.expectEmit(address(handler));
        emit IRealmMasterFeeHandler.CreatorAssetFeesDeposited(address(token), address(assetA), 1_000e18);
        vm.expectEmit(address(handler));
        emit IRealmMasterFeeHandler.CreatorAssetClaimed(address(token), address(assetA), alice, 300e18);
        token.accrueFees(address(assetA), 1_000e18);

        assertEq(assetA.balanceOf(alice), 300e18, "direct slice forwarded");
        assertEq(_claimableIn(token, address(assetA), alice), 0, "direct receiver has nothing pending");
        assertEq(_claimableIn(token, address(assetA), bob), 700e18, "claimable slice accrued");
        assertEq(assetA.balanceOf(address(handler)), 700e18, "handler holds only the claimable slice");
    }

    /// @dev Empty returndata is success, as in SafeERC20: a USDT-style asset is forwarded, not banked.
    function test_directAsset_noReturnData_isForwarded() public {
        NoReturnDataAsset asset = new NoReturnDataAsset();
        MockAssetPayingToken token = _newAssetToken(_fsDirect(alice));
        asset.mint(address(token), 1_000e18);

        vm.expectEmit(address(handler));
        emit IRealmMasterFeeHandler.CreatorAssetClaimed(address(token), address(asset), alice, 1_000e18);
        token.accrueFees(address(asset), 1_000e18);

        assertEq(asset.balanceOf(alice), 1_000e18, "forwarded on deposit");
        assertEq(_claimableIn(token, address(asset), alice), 0, "nothing pending");
    }

    /// @dev A `transfer` returning false banks the slice instead of reverting the deposit.
    function test_directAsset_returnsFalse_banksSliceThenClaimPays() public {
        _assertFailedForwardIsBankedThenClaimed(new FalseReturningAsset());
    }

    /// @dev A reverting `transfer` banks the slice instead of reverting the deposit.
    function test_directAsset_reverts_banksSliceThenClaimPays() public {
        _assertFailedForwardIsBankedThenClaimed(new RevertingAsset());
    }

    /// @dev A USDT-style asset reverting with no data banks the slice instead of reverting the deposit.
    function test_directAsset_noReturnDataRevert_banksSliceThenClaimPays() public {
        _assertFailedForwardIsBankedThenClaimed(new NoReturnDataAsset());
    }

    /// @dev Returndata shorter than a word is failure, not a panic, even when its first byte is non-zero.
    function test_directAsset_shortReturnData_banksSliceThenClaimPays() public {
        _assertFailedForwardIsBankedThenClaimed(new ShortReturnDataAsset());
    }

    /// @dev A gas bomb is cut off at the forward's gas cap and banks the slice.
    function test_directAsset_burnsAllGas_banksSliceThenClaimPays() public {
        _assertFailedForwardIsBankedThenClaimed(new GasBurningAsset());
    }

    /// @dev The gas bomb costs the depositor a bounded amount: the 400k forward cap plus the deposit itself.
    function test_directAsset_burnsAllGas_depositGasIsBounded() public {
        GasBurningAsset asset = new GasBurningAsset();
        MockAssetPayingToken token = _newAssetToken(_fsDirect(alice));
        asset.mint(address(token), 1_000e18);
        asset.setBroken(true);

        uint256 gasBefore = gasleft();
        token.accrueFees(address(asset), 1_000e18);
        assertLt(gasBefore - gasleft(), 400_000 + 200_000, "griefing bounded by the forward cap");
        assertEq(_claimableIn(token, address(asset), alice), 1_000e18, "slice banked");
    }

    /// @dev On a split, a failed forward banks only the direct slice; the claimable accrual is untouched.
    function test_directAsset_splitFailure_banksOnlyTheDirectSlice() public {
        RevertingAsset asset = new RevertingAsset();
        MockAssetPayingToken token = _newAssetToken(_fs2(alice, 3_000, true, bob, 7_000, false));
        asset.setBroken(true);
        _depositAsset(token, asset, 1_000e18);

        assertEq(_claimableIn(token, address(asset), alice), 300e18, "direct slice banked");
        assertEq(_claimableIn(token, address(asset), bob), 700e18, "claimable slice accrued");

        asset.setBroken(false);
        _claimAssetAs(alice, token, asset);
        _claimAssetAs(bob, token, asset);
        assertEq(asset.balanceOf(alice), 300e18, "alice paid");
        assertEq(asset.balanceOf(bob), 700e18, "bob paid");
        assertEq(asset.balanceOf(address(handler)), 0, "nothing lost, nothing left");
    }

    // ======================== per-asset accounting on splits ========================

    /// @dev Native and each ERC20 accrue and are claimed on their own accumulators.
    function test_split_nativeAndAssetAccumulatorsAreIndependent() public {
        MockAssetPayingToken token = _newAssetToken(_fs2(alice, 7_000, false, bob, 3_000, false));
        _deposit(token, 1 ether);
        _depositAsset(token, assetA, 1_000e18);
        _depositAsset(token, assetB, 10e18);

        assertEq(_claimableIn(token, address(0), alice), 0.7 ether, "alice native");
        assertEq(_claimableIn(token, address(assetA), alice), 700e18, "alice A");
        assertEq(_claimableIn(token, address(assetB), alice), 7e18, "alice B");
        assertEq(_claimableIn(token, address(assetA), bob), 300e18, "bob A");

        _claimAs(alice, _single(address(token)));
        assertEq(alice.balance, 0.7 ether, "native claim paid native");
        assertEq(_claimableIn(token, address(assetA), alice), 700e18, "native claim left A intact");
        assertEq(_claimableIn(token, address(assetB), alice), 7e18, "native claim left B intact");

        _claimAssetAs(alice, token, assetA);
        assertEq(assetA.balanceOf(alice), 700e18, "A claim paid A");
        assertEq(_claimableIn(token, address(assetB), alice), 7e18, "A claim left B intact");

        _deposit(token, 2 ether);
        assertEq(_claimableIn(token, address(0), alice), 1.4 ether, "new native accrues");
        assertEq(_claimableIn(token, address(assetA), alice), 0, "native deposit does not move A");
        assertEq(_claimableIn(token, address(assetB), bob), 3e18, "native deposit does not move B");
    }

    /// @dev `setShares` after native AND ERC20 deposits banks every removed and kept recipient's accrual in
    ///      each asset: every recipient is paid exactly its share, and the handler ends empty in both.
    function test_setShares_afterNativeAndAssetDeposits_banksEveryRecipientInEveryAsset() public {
        MockAssetPayingToken token = _newAssetToken(_fs3(alice, 5_000, false, bob, 3_000, false, charlie, 2_000, false));
        _deposit(token, 1 ether);
        _depositAsset(token, assetA, 1_000e18);
        _claimAs(alice, _single(address(token))); // a kept recipient with a fresh native checkpoint

        // bob and charlie removed, alice kept at a new share, dave added.
        vm.prank(creator);
        handler.setShares(address(token), _fs2(alice, 4_000, false, dave, 6_000, false));

        assertEq(_claimableIn(token, address(0), bob), 0.3 ether, "removed bob keeps native");
        assertEq(_claimableIn(token, address(assetA), bob), 300e18, "removed bob keeps A");
        assertEq(_claimableIn(token, address(0), charlie), 0.2 ether, "removed charlie keeps native");
        assertEq(_claimableIn(token, address(assetA), charlie), 200e18, "removed charlie keeps A");
        assertEq(_claimableIn(token, address(0), alice), 0, "kept alice already claimed native");
        assertEq(_claimableIn(token, address(assetA), alice), 500e18, "kept alice keeps A");

        _deposit(token, 1 ether);
        _depositAsset(token, assetA, 1_000e18);

        assertEq(_claimableIn(token, address(0), alice), 0.4 ether, "alice native: new share only");
        assertEq(_claimableIn(token, address(assetA), alice), 900e18, "alice A: banked + new share");
        assertEq(_claimableIn(token, address(0), bob), 0.3 ether, "bob earns nothing after removal");
        assertEq(_claimableIn(token, address(assetA), dave), 600e18, "dave A: new share only");

        address[4] memory everyone = [alice, bob, charlie, dave];
        for (uint256 i; i < everyone.length; ++i) {
            _claimAs(everyone[i], _single(address(token)));
            _claimAssetAs(everyone[i], token, assetA);
        }
        assertEq(alice.balance, 0.5 ether + 0.4 ether, "alice native total");
        assertEq(assetA.balanceOf(alice), 900e18, "alice A total");
        assertEq(bob.balance + charlie.balance + dave.balance, 0.3 ether + 0.2 ether + 0.6 ether, "others native");
        assertEq(assetA.balanceOf(dave), 600e18, "dave A total");
        assertEq(address(handler).balance, 0, "native: nothing lost or double-counted");
        assertEq(assetA.balanceOf(address(handler)), 0, "A: nothing lost or double-counted");
    }

    /// @dev A recipient added by `setShares` starts at the current accumulator of every asset.
    function test_setShares_addedRecipientEarnsNothingFromEarlierDeposits() public {
        MockAssetPayingToken token = _newAssetToken(_fs2(alice, 5_000, false, bob, 5_000, false));
        _deposit(token, 1 ether);
        _depositAsset(token, assetA, 1_000e18);
        _depositAsset(token, assetB, 1_000e18);

        vm.prank(creator);
        handler.setShares(address(token), _fs3(alice, 5_000, false, bob, 2_500, false, charlie, 2_500, false));

        assertEq(_claimableIn(token, address(0), charlie), 0, "no native history");
        assertEq(_claimableIn(token, address(assetA), charlie), 0, "no A history");
        assertEq(_claimableIn(token, address(assetB), charlie), 0, "no B history");

        _deposit(token, 1 ether);
        _depositAsset(token, assetA, 1_000e18);
        assertEq(_claimableIn(token, address(0), charlie), 0.25 ether, "native from the update on");
        assertEq(_claimableIn(token, address(assetA), charlie), 250e18, "A from the update on");
        assertEq(_claimableIn(token, address(assetB), charlie), 0, "B still has no deposit since");
    }

    /// @dev Switching classes or dropping a direct receiver keeps every banked slice in each asset: a
    ///      claimable turned direct keeps its accrual, a direct turned claimable or removed keeps its pending.
    function test_setShares_classSwitchAndDirectRemoval_keepEveryAssetBalance() public {
        RevertingAsset asset = new RevertingAsset();
        MockAssetPayingToken token = _newAssetToken(_fs3(alice, 4_000, false, bob, 3_000, true, charlie, 3_000, true));
        _deposit(token, 1 ether); // bob and charlie forwarded natively
        asset.setBroken(true);
        _depositAsset(token, asset, 1_000e18); // bob and charlie banked in the asset

        // alice claimable -> direct, bob direct -> claimable, charlie (direct) removed.
        vm.prank(creator);
        handler.setShares(address(token), _fs2(alice, 5_000, true, bob, 5_000, false));

        assertEq(_claimableIn(token, address(0), alice), 0.4 ether, "alice keeps native accrual as direct");
        assertEq(_claimableIn(token, address(asset), alice), 400e18, "alice keeps asset accrual as direct");
        assertEq(_claimableIn(token, address(asset), bob), 300e18, "bob keeps asset pending as claimable");
        assertEq(_claimableIn(token, address(asset), charlie), 300e18, "removed charlie keeps asset pending");

        asset.setBroken(false);
        _deposit(token, 1 ether);
        _depositAsset(token, asset, 1_000e18);

        address[3] memory everyone = [alice, bob, charlie];
        for (uint256 i; i < everyone.length; ++i) {
            _claimAs(everyone[i], _single(address(token)));
            _claimAssetAs(everyone[i], token, asset);
        }
        assertEq(alice.balance, 0.4 ether + 0.5 ether, "alice native");
        assertEq(asset.balanceOf(alice), 400e18 + 500e18, "alice asset");
        assertEq(bob.balance, 0.3 ether + 0.5 ether, "bob native");
        assertEq(asset.balanceOf(bob), 300e18 + 500e18, "bob asset");
        assertEq(charlie.balance, 0.3 ether, "charlie native");
        assertEq(asset.balanceOf(charlie), 300e18, "charlie asset");
        assertEq(address(handler).balance, 0, "native: nothing lost or double-counted");
        assertEq(asset.balanceOf(address(handler)), 0, "asset: nothing lost or double-counted");
    }

    // ======================== assetsOf ========================

    /// @dev Native is listed first even before registration or any deposit.
    function test_assetsOf_nativeFirstBeforeAnyDeposit() public {
        address[] memory unregistered = handler.assetsOf(makeAddr("unregistered"));
        assertEq(unregistered.length, 1, "unregistered: native only");
        assertEq(unregistered[0], address(0), "unregistered: native");

        address[] memory fresh = handler.assetsOf(address(_newAssetToken(_fs(alice))));
        assertEq(fresh.length, 1, "fresh: native only");
        assertEq(fresh[0], address(0), "fresh: native");
    }

    /// @dev Each ERC20 is listed once, in first-payment order, and native deposits never add a second native.
    function test_assetsOf_firstPaymentOrderAndNativeNeverDuplicated() public {
        MockAssetPayingToken token = _newAssetToken(_fs2(alice, 5_000, false, bob, 5_000, false));
        _deposit(token, 1 ether);
        _depositAsset(token, assetB, 1e18);
        _deposit(token, 1 ether);
        _depositAsset(token, assetA, 1e18);
        _depositAsset(token, assetB, 1e18);
        _depositAsset(token, assetA, 1e18);
        _deposit(token, 1 ether);
        MockAsset unpaid = new MockAsset();
        vm.prank(address(token));
        handler.depositFees(address(token), address(unpaid), 0); // zero amount records nothing

        address[] memory assets = handler.assetsOf(address(token));
        assertEq(assets.length, 3, "native + two ERC20s");
        assertEq(assets[0], address(0), "native first");
        assertEq(assets[1], address(assetB), "B paid first");
        assertEq(assets[2], address(assetA), "A paid second");
    }

    // ======================== ERC20 deposit gates ========================

    /// @dev Only the token itself may deposit an ERC20 for itself; the gate precedes the asset check.
    function test_depositAsset_revertsUnlessCalledByTheToken() public {
        MockAssetPayingToken token = _newAssetToken(_fs(alice));
        MockAssetPayingToken other = _newAssetToken(_fs(bob));

        vm.expectRevert(IRealmMasterFeeHandler.Unauthorized.selector);
        handler.depositFees(address(token), address(assetA), 1e18);

        vm.prank(address(other));
        vm.expectRevert(IRealmMasterFeeHandler.Unauthorized.selector);
        handler.depositFees(address(token), address(assetA), 1e18);

        vm.expectRevert(IRealmMasterFeeHandler.Unauthorized.selector);
        handler.depositFees(address(token), address(0), 1e18);
    }

    /// @dev Native belongs on the payable overload: the ERC20 one rejects the `address(0)` sentinel.
    function test_depositAsset_revertsOnNativeSentinel() public {
        MockAssetPayingToken token = _newAssetToken(_fs(alice));
        vm.prank(address(token));
        vm.expectRevert(IRealmMasterFeeHandler.InvalidAsset.selector);
        handler.depositFees(address(token), address(0), 1e18);
    }

    /// @dev The 9th distinct ERC20 reverts `TooManyFeeAssets`; native and already-seen ERC20s still deposit.
    function test_depositAsset_ninthDistinctAssetReverts_nativeAndSeenAssetsStillWork() public {
        MockAssetPayingToken token = _newAssetToken(_fs2(alice, 5_000, false, bob, 5_000, false));
        MockAsset first;
        for (uint256 i; i < 8; ++i) {
            MockAsset asset = new MockAsset();
            if (i == 0) first = asset;
            _depositAsset(token, asset, 1e18);
        }

        MockAsset ninth = new MockAsset();
        ninth.mint(address(token), 1e18);
        vm.expectRevert(IRealmMasterFeeHandler.TooManyFeeAssets.selector);
        token.accrueFees(address(ninth), 1e18);

        _deposit(token, 1 ether);
        assertEq(_claimableIn(token, address(0), alice), 0.5 ether, "native still deposits");
        _depositAsset(token, first, 1e18);
        assertEq(_claimableIn(token, address(first), alice), 1e18, "a seen asset still deposits");
        assertEq(handler.assetsOf(address(token)).length, 9, "native + 8 ERC20s");
    }

    /// @dev A fee-on-transfer asset is credited only what arrived, so every claim is fully backed.
    function test_depositAsset_feeOnTransfer_creditsOnlyWhatArrived() public {
        FeeOnTransferAsset asset = new FeeOnTransferAsset();
        MockAssetPayingToken token = _newAssetToken(_fs2(alice, 5_000, false, bob, 5_000, false));
        asset.mint(address(token), 1_000e18);

        vm.expectEmit(address(handler));
        emit IRealmMasterFeeHandler.CreatorAssetFeesDeposited(address(token), address(asset), 900e18);
        token.accrueFees(address(asset), 1_000e18);

        assertEq(asset.balanceOf(address(handler)), 900e18, "arrived");
        assertEq(_claimableIn(token, address(asset), alice), 450e18, "alice credited on arrival");
        assertEq(_claimableIn(token, address(asset), bob), 450e18, "bob credited on arrival");

        _claimAssetAs(alice, token, asset);
        _claimAssetAs(bob, token, asset);
        assertEq(asset.balanceOf(address(handler)), 0, "claims exactly drain what arrived");
    }
}
