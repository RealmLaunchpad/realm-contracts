// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RealmMasterFeeHandler} from "src/feeHandlers/RealmMasterFeeHandler.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

/// @dev Minimal token double for standalone RealmMasterFeeHandler tests.
///      The handler only needs `feeHandler()` during registration and `owner()` during setShares.
contract MockMasterFeeToken {
    RealmMasterFeeHandler public feeHandler;
    address public owner;

    constructor(RealmMasterFeeHandler handler_, address owner_) {
        feeHandler = handler_;
        owner = owner_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function registerFees(IRealmFactory.FeeShare[] calldata feeShares) external {
        feeHandler.registerToken(feeShares);
    }

    function accrueFees() external payable {
        feeHandler.depositFees{value: msg.value}(address(this));
    }
}

/// @dev Receiver that rejects ETH transfers; used to exercise fallback-to-pending and claim failures.
contract MasterFeeEthRejecter {
    receive() external payable {
        revert("rejected");
    }
}

abstract contract MasterFeeHandlerTestHelpers is Test {
    RealmMasterFeeHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    function setUp() public virtual {
        vm.prank(owner);
        handler = new RealmMasterFeeHandler();
        vm.deal(address(this), 1_000 ether);
    }

    function _newToken(address tokenOwner) internal returns (MockMasterFeeToken) {
        return new MockMasterFeeToken(handler, tokenOwner);
    }

    function _register(MockMasterFeeToken token, IRealmFactory.FeeShare[] memory shares) internal {
        token.registerFees(shares);
    }

    function _newRegisteredToken(address tokenOwner, IRealmFactory.FeeShare[] memory shares)
        internal
        returns (MockMasterFeeToken token)
    {
        token = _newToken(tokenOwner);
        _register(token, shares);
    }

    function _deposit(MockMasterFeeToken token, uint256 amount) internal {
        handler.depositFees{value: amount}(address(token));
    }

    function _claimAs(address account, address[] memory tokens) internal {
        vm.prank(account);
        handler.claim(tokens);
    }

    function _single(address token) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = token;
    }

    function _tokens(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _tokens(address a, address b, address c) internal pure returns (address[] memory arr) {
        arr = new address[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }

    function _claimable(address token, address account) internal view returns (uint256) {
        return handler.getClaimable(_single(token), account)[0];
    }

    function _fs(address account) internal pure returns (IRealmFactory.FeeShare[] memory arr) {
        arr = new IRealmFactory.FeeShare[](1);
        arr[0] = IRealmFactory.FeeShare({account: account, shares: 10_000, directFeesEnabled: false});
    }

    function _fsDirect(address account) internal pure returns (IRealmFactory.FeeShare[] memory arr) {
        arr = new IRealmFactory.FeeShare[](1);
        arr[0] = IRealmFactory.FeeShare({account: account, shares: 10_000, directFeesEnabled: true});
    }

    function _fs2(address a, uint256 aShare, bool aDirect, address b, uint256 bShare, bool bDirect)
        internal
        pure
        returns (IRealmFactory.FeeShare[] memory arr)
    {
        arr = new IRealmFactory.FeeShare[](2);
        arr[0] = IRealmFactory.FeeShare({account: a, shares: aShare, directFeesEnabled: aDirect});
        arr[1] = IRealmFactory.FeeShare({account: b, shares: bShare, directFeesEnabled: bDirect});
    }

    function _fs3(
        address a,
        uint256 aShare,
        bool aDirect,
        address b,
        uint256 bShare,
        bool bDirect,
        address c,
        uint256 cShare,
        bool cDirect
    ) internal pure returns (IRealmFactory.FeeShare[] memory arr) {
        arr = new IRealmFactory.FeeShare[](3);
        arr[0] = IRealmFactory.FeeShare({account: a, shares: aShare, directFeesEnabled: aDirect});
        arr[1] = IRealmFactory.FeeShare({account: b, shares: bShare, directFeesEnabled: bDirect});
        arr[2] = IRealmFactory.FeeShare({account: c, shares: cShare, directFeesEnabled: cDirect});
    }
}
