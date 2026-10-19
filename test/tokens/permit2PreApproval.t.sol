// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V4SwapHelpers} from "test/e2e/base/V4SwapHelpers.t.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IUniversalRouter, IV4RouterSwaps} from "src/interfaces/IUniswapV4UniversalRouter.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";

/// @notice Aim: a holder who never approved anything sells a Realm V4 token with ONE signature and ONE
///         transaction, while the Permit2 pre-approval hands no third party any power over their tokens
///         and the holder keeps a way to cut the router off.
contract Permit2PreApprovalTests is V4SwapHelpers {
    bytes32 constant PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 constant PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );
    bytes1 constant PERMIT2_PERMIT = 0x0a;
    bytes1 constant V4_SWAP = 0x10;

    address holder;
    uint256 holderKey;
    address attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        (holder, holderKey) = makeAddrAndKey("holder");
    }

    /////////////////////////// HELPERS ///////////////////////////

    /// @dev A token whose fresh `holder` owns `amount`, received by plain transfer, so the holder has
    ///      never touched an approval (the buy helper approves on the buyer's behalf).
    function _tokenHeldBy(bool taxable) internal returns (address token, uint256 amount) {
        TaxConfigs memory tax = taxable ? _taxCfg(0, 300, uint32(4 days)) : _emptyTaxCfg();
        token = _createDirectToken(tax);
        vm.deal(alice, 1 ether);
        _swapBuyV4(alice, token, 0.5 ether, 0, true);
        amount = IERC20(token).balanceOf(alice);
        vm.prank(alice);
        IERC20(token).transfer(holder, amount);
    }

    function _permit(address token, uint160 amount, uint48 nonce)
        internal
        view
        returns (IAllowanceTransfer.PermitSingle memory p)
    {
        p.details = IAllowanceTransfer.PermitDetails({
            token: token, amount: amount, expiration: type(uint48).max, nonce: nonce
        });
        p.spender = universalRouter;
        p.sigDeadline = block.timestamp + 1 hours;
    }

    function _sign(IAllowanceTransfer.PermitSingle memory p, uint256 key) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_SINGLE_TYPEHASH,
                keccak256(abi.encode(PERMIT_DETAILS_TYPEHASH, p.details)),
                p.spender,
                p.sigDeadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IPermit2(permit2Address).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return bytes.concat(r, s, bytes1(v));
    }

    function _sellInput(address token, uint256 amountIn) internal view returns (bytes memory) {
        PoolKey memory key = _v4PoolKey(token);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4RouterSwaps.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency1, amountIn);
        params[2] = abi.encode(key.currency0, uint256(0));
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        return abi.encode(actions, params);
    }

    /// @dev The single transaction the frontend sends: permit + swap in one `execute`.
    function _sellWithPermit(address seller_, address token, uint256 amountIn, bytes memory sig) internal {
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(_permit(token, type(uint160).max, 0), sig);
        inputs[1] = _sellInput(token, amountIn);
        vm.prank(seller_);
        IUniversalRouter(universalRouter).execute(abi.encodePacked(PERMIT2_PERMIT, V4_SWAP), inputs, block.timestamp);
    }

    /// @dev A later sale that relies on an allowance already living in Permit2 (no new signature).
    function _sellNoPermit(address seller_, address token, uint256 amountIn) internal {
        _sellNoPermit(seller_, token, amountIn, false);
    }

    function _sellNoPermit(address seller_, address token, uint256 amountIn, bool reverts) internal {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _sellInput(token, amountIn);
        vm.prank(seller_);
        if (reverts) vm.expectRevert();
        IUniversalRouter(universalRouter).execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp);
    }

    /////////////////////////// ONE-TX SALE ///////////////////////////

    function test_neverApprovedHolderSellsInOneTransaction() public {
        _assertOneTxSale(false);
    }

    /// @dev The taxable impl is a separate clone target; it must inherit the pre-approval too.
    function test_neverApprovedHolderSellsTaxableTokenInOneTransaction() public {
        _assertOneTxSale(true);
    }

    function _assertOneTxSale(bool taxable) internal {
        (address token, uint256 amount) = _tokenHeldBy(taxable);
        bytes memory sig = _sign(_permit(token, type(uint160).max, 0), holderKey);

        uint256 ethBefore = holder.balance;
        _sellWithPermit(holder, token, amount / 2, sig);

        assertEq(IERC20(token).balanceOf(holder), amount - amount / 2, "sold exactly the signed sale");
        assertGt(holder.balance, ethBefore, "holder got paid");

        // The signature was long-lived: the next sale needs neither an approval nor a signature.
        _sellNoPermit(holder, token, amount / 4);
        assertEq(IERC20(token).balanceOf(holder), amount - amount / 2 - amount / 4);
    }

    /////////////////////////// NO POWER TO THIRD PARTIES ///////////////////////////

    /// @dev The ERC20-level pre-approval is worthless without the holder's own Permit2 grant.
    function test_nobodyCanPullAHoldersTokensThroughPermit2WithoutTheirSignature() public {
        (address token, uint256 amount) = _tokenHeldBy(false);

        vm.startPrank(attacker);
        vm.expectRevert(); // no Permit2 allowance holder -> attacker
        IPermit2(permit2Address).transferFrom(holder, attacker, uint160(amount), token);

        // A grant signed by anyone but the holder is rejected.
        IAllowanceTransfer.PermitSingle memory p = _permit(token, type(uint160).max, 0);
        p.spender = attacker;
        (, uint256 attackerKey) = makeAddrAndKey("attacker");
        bytes memory forged = _sign(p, attackerKey);
        vm.expectRevert();
        IPermit2(permit2Address).permit(holder, p, forged);
        vm.stopPrank();

        assertEq(IERC20(token).balanceOf(holder), amount, "holder untouched");
    }

    /// @dev Permit signatures are public calldata. Anyone replaying the holder's signature only grants the
    ///      router, and the router only ever spends its caller's own balance.
    function test_replayingAHoldersSignatureGivesTheReplayerNothing() public {
        (address token, uint256 amount) = _tokenHeldBy(false);
        IAllowanceTransfer.PermitSingle memory p = _permit(token, type(uint160).max, 0);
        bytes memory sig = _sign(p, holderKey);

        vm.prank(attacker);
        IPermit2(permit2Address).permit(holder, p, sig);

        vm.prank(attacker);
        vm.expectRevert();
        IPermit2(permit2Address).transferFrom(holder, attacker, uint160(amount), token);

        // The attacker driving the router sells THEIR balance (none), not the holder's.
        _sellNoPermit(attacker, token, amount, true);

        assertEq(IERC20(token).balanceOf(holder), amount, "holder untouched");
    }

    /// @dev Only Permit2 (and the launchpad, as before) is pre-approved: no other contract the token
    ///      routinely meets, nor any arbitrary address, gains an allowance.
    function testFuzz_preApprovalIsScopedToPermit2(address spender) public {
        (address token, uint256 amount) = _tokenHeldBy(false);
        // address(0): direct tokens have no launchpad, so it reads as pre-approved (unexploitable, no pkey)
        vm.assume(
            spender != address(0) && spender != permit2Address && spender != address(launchpad) && spender != holder
        );

        assertEq(IERC20(token).allowance(holder, spender), 0);
        assertEq(IERC20(token).allowance(holder, universalRouter), 0);
        assertEq(IERC20(token).allowance(holder, poolManagerAddress), 0);

        vm.prank(spender);
        vm.expectRevert();
        IERC20(token).transferFrom(holder, spender, amount);
    }

    /////////////////////////// HOLDER'S ESCAPE HATCH ///////////////////////////

    /// @dev The ERC20 allowance can't be revoked (approve(PERMIT2, 0) is a no-op), so the escape hatch is
    ///      Permit2's `lockdown`: after it, a long-lived router grant no longer moves the holder's tokens.
    function test_holderCanCutOffTheRouterDespiteTheIrrevocableAllowance() public {
        (address token, uint256 amount) = _tokenHeldBy(false);
        _sellWithPermit(holder, token, amount / 4, _sign(_permit(token, type(uint160).max, 0), holderKey));

        vm.prank(holder);
        IERC20(token).approve(permit2Address, 0);
        assertEq(IERC20(token).allowance(holder, permit2Address), type(uint256).max, "ERC20 revoke is a no-op");

        IAllowanceTransfer.TokenSpenderPair[] memory pairs = new IAllowanceTransfer.TokenSpenderPair[](1);
        pairs[0] = IAllowanceTransfer.TokenSpenderPair({token: token, spender: universalRouter});
        vm.prank(holder);
        IPermit2(permit2Address).lockdown(pairs);

        uint256 left = IERC20(token).balanceOf(holder);
        _sellNoPermit(holder, token, left, true);
        assertEq(IERC20(token).balanceOf(holder), left, "locked-down router moved nothing");
    }
}
