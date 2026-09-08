// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmGraduator} from "src/interfaces/IRealmGraduator.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";

import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {SniperProtection, AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {DeploymentAddressesEthereumMainnet} from "src/config/DeploymentAddresses.sol";

/// @dev Minimal graduator mock — returns a caller-chosen `pair` address from `initialize()`
///      and lets the test drive `markGraduated` on the token.
contract MockGraduator is IRealmGraduator {
    address public immutable PAIR;

    constructor(address pair_) {
        PAIR = pair_;
    }

    function initialize(address) external view returns (address) {
        return PAIR;
    }

    function graduateToken(address, uint256) external payable {}
}

/// @dev Minimal launchpad stub. The sniper-protection check no longer queries this contract, but
///      a standalone address is still used as the "launchpad" from the token's perspective.
contract MockLaunchpad {
    function launchToken(address, address) external {}
}

/// @dev Shared test base for both sniper-protected variants. Subclasses wire in the concrete
///      token type and the appropriate pair address.
abstract contract SniperProtectionBaseTest is Test {
    address internal tokenOwner = makeAddr("tokenOwner");
    address internal feeHandler = makeAddr("feeHandler");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal buyer = makeAddr("buyer");
    address internal buyer2 = makeAddr("buyer2");
    address internal seller = makeAddr("seller");
    address internal factory = makeAddr("factory");
    address internal deployer = makeAddr("deployer");
    address internal whitelisted1 = makeAddr("whitelisted1");
    address internal whitelisted2 = makeAddr("whitelisted2");

    MockLaunchpad internal launchpadMock;
    MockGraduator internal graduator;

    address internal launchpad; // cached address(launchpadMock) for terse assertions

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    // Default AntiSniperConfigs values used by subclass setUp(). Match the old hardcoded behavior
    // so tests that don't care about configurability continue to make sense (3% / 3% / 3h).
    uint16 internal constant DEFAULT_MAX_BUY_BPS = 300;
    uint16 internal constant DEFAULT_MAX_WALLET_BPS = 300;
    uint40 internal constant DEFAULT_WINDOW = 3 hours;

    uint256 internal constant MAX_BUY_PER_TX = 30_000_000e18; // 3% of 1B
    uint256 internal constant MAX_WALLET = 30_000_000e18; // 3% of 1B

    function _token() internal view virtual returns (RealmToken);

    /// @dev Passed to the token's initializer by subclass setUp(). Single hook so individual tests
    ///      can override by re-deploying before their own setUp.
    function _defaultCfg() internal view returns (AntiSniperConfigs memory cfg) {
        address[] memory wl = new address[](2);
        wl[0] = whitelisted1;
        wl[1] = whitelisted2;
        cfg = AntiSniperConfigs({
            maxBuyPerTxBps: DEFAULT_MAX_BUY_BPS,
            maxWalletBps: DEFAULT_MAX_WALLET_BPS,
            protectionWindowSeconds: DEFAULT_WINDOW,
            whitelist: wl
        });
    }

    /// @dev Called via prank(launchpad) to simulate a curve buy.
    function _curveBuy(address to, uint256 amount) internal {
        vm.prank(launchpad);
        _token().transfer(to, amount);
    }

    /// @dev Pretend a user sells back to the curve.
    function _curveSell(address from, uint256 amount) internal {
        vm.prank(from);
        _token().transfer(launchpad, amount);
    }

    /// -------------------- TESTS --------------------

    function test_initialMintNotBlocked() public view {
        assertEq(_token().balanceOf(launchpad), TOTAL_SUPPLY);
    }

    function test_launchTimestampRecorded() public view {
        uint40 ts = IRealmToken(address(_token())).launchTimestamp();
        assertGt(ts, 0);
        assertEq(ts, uint40(block.timestamp));
    }

    function test_configsStored() public view {
        SniperProtection sp = SniperProtection(address(_token()));
        assertEq(sp.maxBuyPerTxBps(), DEFAULT_MAX_BUY_BPS);
        assertEq(sp.maxWalletBps(), DEFAULT_MAX_WALLET_BPS);
        assertEq(uint256(sp.protectionWindowSeconds()), DEFAULT_WINDOW);
    }

    function test_whitelistRecorded() public view {
        SniperProtection sp = SniperProtection(address(_token()));
        assertTrue(sp.sniperBypass(whitelisted1));
        assertTrue(sp.sniperBypass(whitelisted2));
        assertFalse(sp.sniperBypass(buyer));
    }

    function test_maxBuyPerTx_boundary() public {
        _curveBuy(buyer, MAX_BUY_PER_TX);
        assertEq(_token().balanceOf(buyer), MAX_BUY_PER_TX);
    }

    function test_maxBuyPerTx_reverts() public {
        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxBuyPerTxExceeded.selector);
        _token().transfer(buyer, MAX_BUY_PER_TX + 1);
    }

    function test_maxWallet_boundary() public {
        _curveBuy(buyer, MAX_BUY_PER_TX);
        _curveBuy(buyer, MAX_WALLET - MAX_BUY_PER_TX);
        assertEq(_token().balanceOf(buyer), MAX_WALLET);
    }

    function test_maxWallet_reverts() public {
        _curveBuy(buyer, MAX_WALLET);

        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxWalletExceeded.selector);
        _token().transfer(buyer, 1);
    }

    function test_sellsUnaffected() public {
        _curveBuy(seller, MAX_BUY_PER_TX);
        _curveSell(seller, MAX_BUY_PER_TX);
        assertEq(_token().balanceOf(seller), 0);
    }

    /// Wallet-to-wallet transfers within the protection window are subject to the same caps as
    /// curve buys. A transfer that keeps the recipient under both caps is allowed.
    function test_walletToWallet_underCap_succeeds_withinWindow() public {
        _curveBuy(buyer, MAX_BUY_PER_TX);
        assertLt(block.timestamp, IRealmToken(address(_token())).launchTimestamp() + DEFAULT_WINDOW);

        vm.prank(buyer);
        _token().transfer(buyer2, MAX_BUY_PER_TX);
        assertEq(_token().balanceOf(buyer2), MAX_BUY_PER_TX);
    }

    /// The per-tx cap is intentionally NOT applied to wallet-to-wallet transfers — only to
    /// bonding-curve buys. With asymmetric configs (maxBuyPerTx < maxWallet), a wallet holding
    /// > maxBuyPerTx can push the full balance to a fresh recipient in one transfer as long as
    /// the recipient stays under `maxWallet`.
    function test_walletToWallet_perTxCap_notEnforcedWithinWindow() public {
        // 1% per-tx, 3% per-wallet, default window.
        uint16 tightBuyBps = 100; // 1% → 10_000_000e18
        uint16 tightWalletBps = 300; // 3% → 30_000_000e18
        address[] memory wl = new address[](1);
        wl[0] = whitelisted1;
        RealmToken t = _deployCustom(tightBuyBps, tightWalletBps, DEFAULT_WINDOW, wl);

        uint256 tightMaxBuy = (TOTAL_SUPPLY * tightBuyBps) / 10_000;
        uint256 tightMaxWallet = (TOTAL_SUPPLY * tightWalletBps) / 10_000;

        // Load `whitelisted1` with `tightMaxWallet` (bypasses per-tx and per-wallet caps).
        vm.prank(launchpad);
        t.transfer(whitelisted1, tightMaxWallet);

        // Wallet-to-wallet transfer of an amount above the per-tx cap is allowed as long as the
        // recipient ends up under the per-wallet cap.
        assertGt(tightMaxWallet, tightMaxBuy);
        vm.prank(whitelisted1);
        t.transfer(buyer, tightMaxWallet);
        assertEq(t.balanceOf(buyer), tightMaxWallet);
    }

    /// A wallet-to-wallet transfer whose recipient would end up over the per-wallet cap must
    /// revert, even if the amount itself is under the per-tx cap. This is the primary defense
    /// against the sybil-buy → consolidate attack: a sniper cannot fragment buys across many
    /// wallets and then transfer them all to a single wallet.
    function test_walletToWallet_perWalletCap_revertsWithinWindow() public {
        _curveBuy(buyer, MAX_WALLET);
        _curveBuy(seller, MAX_BUY_PER_TX);

        // `seller` is at maxBuyPerTx (< maxWallet here — but with default 3%/3% configs they're
        // equal). Any non-zero transfer to `buyer` would push `buyer` above the wallet cap.
        vm.prank(seller);
        vm.expectRevert(SniperProtection.MaxWalletExceeded.selector);
        _token().transfer(buyer, 1);
    }

    /// End-to-end sybil consolidation attempt: multiple wallets each buy at the cap, then try to
    /// funnel into one wallet. The consolidating transfer must revert.
    function test_walletToWallet_sybilConsolidation_blockedWithinWindow() public {
        address sybil1 = makeAddr("sybil1");
        address sybil2 = makeAddr("sybil2");
        address sink = makeAddr("sink");

        _curveBuy(sybil1, MAX_WALLET);
        _curveBuy(sybil2, MAX_WALLET);
        _curveBuy(sink, MAX_WALLET);

        // Each sybil sitting at maxWallet attempts to push everything to `sink`.
        vm.prank(sybil1);
        vm.expectRevert(SniperProtection.MaxWalletExceeded.selector);
        _token().transfer(sink, MAX_WALLET);
    }

    /// After the window expires, wallet-to-wallet transfers of any size are allowed.
    function test_walletToWallet_afterWindow_uncapped() public {
        _curveBuy(buyer, MAX_WALLET);
        _curveBuy(buyer2, MAX_WALLET);

        uint40 launchTs = IRealmToken(address(_token())).launchTimestamp();
        vm.warp(launchTs + DEFAULT_WINDOW + 1);

        vm.prank(buyer);
        _token().transfer(buyer2, MAX_WALLET);
        assertEq(_token().balanceOf(buyer2), MAX_WALLET * 2);
    }

    /// Whitelisted recipient bypasses caps on wallet-to-wallet transfers too, not just on curve
    /// buys.
    function test_walletToWallet_whitelistedRecipient_bypassesCaps() public {
        _curveBuy(buyer, MAX_WALLET);
        _curveBuy(buyer2, MAX_WALLET);

        vm.prank(buyer);
        _token().transfer(whitelisted1, MAX_WALLET);
        vm.prank(buyer2);
        _token().transfer(whitelisted1, MAX_WALLET);
        assertEq(_token().balanceOf(whitelisted1), MAX_WALLET * 2);
    }

    function test_windowExpiry_capsLift() public {
        uint40 launchTs = IRealmToken(address(_token())).launchTimestamp();
        vm.warp(launchTs + DEFAULT_WINDOW + 1);

        _curveBuy(buyer, MAX_BUY_PER_TX + 1);
        assertEq(_token().balanceOf(buyer), MAX_BUY_PER_TX + 1);

        _curveBuy(buyer, MAX_WALLET * 2);
        assertEq(_token().balanceOf(buyer), MAX_BUY_PER_TX + 1 + MAX_WALLET * 2);
    }

    function test_postGraduationBypass_withinWindow() public {
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(address(graduator));
        _token().markGraduated();

        _curveBuy(buyer, MAX_BUY_PER_TX + 1);
        assertEq(_token().balanceOf(buyer), MAX_BUY_PER_TX + 1);
    }

    function test_walletToWalletUnaffected_postGraduation() public {
        _curveBuy(buyer, MAX_BUY_PER_TX);

        vm.prank(address(graduator));
        _token().markGraduated();

        vm.prank(buyer);
        _token().transfer(buyer2, MAX_BUY_PER_TX);
        assertEq(_token().balanceOf(buyer2), MAX_BUY_PER_TX);
    }

    function test_multipleBuyersIndependentWalletCaps() public {
        _curveBuy(buyer, MAX_WALLET);
        _curveBuy(buyer2, MAX_WALLET);
        assertEq(_token().balanceOf(buyer), MAX_WALLET);
        assertEq(_token().balanceOf(buyer2), MAX_WALLET);
    }

    /// Deployer-buy path: launchpad → factory → supplyShares. The launchpad → factory hop can move a
    /// large share of supply (the deploy buy is uncapped, bounded only by graduation) — here 10%, far
    /// above the 3% cap. The recipient-is-factory exemption lets this pass.
    /// @dev `tokenFactory` lives in transient storage on the token, so the recipient-is-factory
    ///      exemption only fires while init and the deployer-buy hop run in the same tx — which
    ///      mirrors the production flow (the factory's `createToken` does both atomically). We
    ///      clone + init a fresh token inside this test method so the simulation runs in a
    ///      single tx, just like production.
    function test_deployerBuyViaDeployingFactory_bypassesCaps() public {
        uint256 deployerBuyAmount = TOTAL_SUPPLY / 10; // 10%

        RealmToken freshToken =
            _deployCustom(DEFAULT_MAX_BUY_BPS, DEFAULT_MAX_WALLET_BPS, DEFAULT_WINDOW, new address[](0));
        address deployingFactory = address(this);

        vm.prank(launchpad);
        freshToken.transfer(deployingFactory, deployerBuyAmount);
        assertEq(freshToken.balanceOf(deployingFactory), deployerBuyAmount);

        // Factory → deployer: passes via the `from == factoryAddr` exemption, which exists so the
        // factory's intra-`createToken` distribution to supplyShare recipients isn't capped.
        vm.prank(deployingFactory);
        freshToken.transfer(deployer, deployerBuyAmount);
        assertEq(freshToken.balanceOf(deployer), deployerBuyAmount);
    }

    /// Once `createToken` has finished, the transient `tokenFactory` slot reads `address(0)`,
    /// so the `from == factoryAddr` exemption no longer applies to the deploying address. A wallet
    /// holding the deployer-buy amount cannot use that exemption to flood another wallet during
    /// the protection window.
    /// @dev Simulated in-test by using `_curveBuy` (still inside the same test tx, so the slot is
    ///      set) to load a recipient up; then the recipient — which is NOT the factory — tries to
    ///      push past the wallet cap and reverts.
    function test_deployerBuyRecipient_stillCappedOnRetransfer() public {
        // The deployer-buy recipient is `deployer`. Whitelist them so they can receive 10% from
        // the launchpad without tripping the per-tx cap on the inbound transfer.
        address[] memory wl = new address[](1);
        wl[0] = deployer;
        RealmToken t = _deployCustom(DEFAULT_MAX_BUY_BPS, DEFAULT_MAX_WALLET_BPS, DEFAULT_WINDOW, wl);

        vm.prank(launchpad);
        t.transfer(deployer, TOTAL_SUPPLY / 10);

        // `deployer` now holds 10% of supply. Pushing >maxWallet to a fresh wallet reverts on the
        // per-wallet cap (the per-tx cap doesn't apply to wallet-to-wallet transfers).
        vm.prank(deployer);
        vm.expectRevert(SniperProtection.MaxWalletExceeded.selector);
        t.transfer(buyer, MAX_WALLET + 1);

        // Filling a wallet exactly to the cap is fine; one wei more reverts.
        vm.prank(deployer);
        t.transfer(buyer, MAX_WALLET);
        vm.prank(deployer);
        vm.expectRevert(SniperProtection.MaxWalletExceeded.selector);
        t.transfer(buyer, 1);
    }

    /// Non-factory, non-whitelisted recipients are still capped — ensures the bypass is scoped.
    function test_nonWhitelistedRecipient_stillCapped() public {
        address otherContract = makeAddr("otherContract");

        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxBuyPerTxExceeded.selector);
        _token().transfer(otherContract, MAX_BUY_PER_TX + 1);
    }

    function test_devWhitelistBypassesMaxBuyPerTx() public {
        _curveBuy(whitelisted1, MAX_BUY_PER_TX * 5);
        assertEq(_token().balanceOf(whitelisted1), MAX_BUY_PER_TX * 5);
    }

    function test_devWhitelistBypassesMaxWallet() public {
        _curveBuy(whitelisted1, MAX_WALLET);
        _curveBuy(whitelisted1, MAX_WALLET * 3);
        assertEq(_token().balanceOf(whitelisted1), MAX_WALLET * 4);
    }

    function test_devWhitelist_onlyAppliesToWhitelistedAddresses() public {
        _curveBuy(whitelisted2, MAX_BUY_PER_TX * 4);
        assertEq(_token().balanceOf(whitelisted2), MAX_BUY_PER_TX * 4);

        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxBuyPerTxExceeded.selector);
        _token().transfer(buyer, MAX_BUY_PER_TX + 1);
    }

    function test_customConfigsEnforced() public {
        // Deploy a second token with tight configs: 1% / 3% / 10 min. Wallet cap is a 3x multiple
        // of the per-tx cap so we can fill a wallet with exactly 3 back-to-back max-per-tx buys.
        uint16 tightBuyBps = 100; // 1% → 10_000_000e18
        uint16 tightWalletBps = 300; // 3% → 30_000_000e18
        uint40 shortWindow = 10 minutes;

        RealmToken t = _deployCustom(tightBuyBps, tightWalletBps, shortWindow, new address[](0));

        uint256 tightMaxBuy = (TOTAL_SUPPLY * tightBuyBps) / 10_000;
        uint256 tightMaxWallet = (TOTAL_SUPPLY * tightWalletBps) / 10_000;

        // Boundary passes.
        vm.prank(launchpad);
        t.transfer(buyer, tightMaxBuy);
        assertEq(t.balanceOf(buyer), tightMaxBuy);

        // One wei over the tx cap reverts.
        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxBuyPerTxExceeded.selector);
        t.transfer(buyer2, tightMaxBuy + 1);

        // Fill the wallet to the cap with additional max-per-tx buys.
        vm.prank(launchpad);
        t.transfer(buyer, tightMaxBuy);
        vm.prank(launchpad);
        t.transfer(buyer, tightMaxBuy);
        assertEq(t.balanceOf(buyer), tightMaxWallet);

        // One more wei reverts on MaxWallet.
        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxWalletExceeded.selector);
        t.transfer(buyer, 1);

        // Window expires after 10 minutes; caps lift. Send well above the former per-tx cap.
        vm.warp(block.timestamp + shortWindow + 1);
        vm.prank(launchpad);
        t.transfer(buyer2, tightMaxBuy * 10);
        assertEq(t.balanceOf(buyer2), tightMaxBuy * 10);
    }

    function test_emitsSniperProtectionInitialized() public {
        address[] memory wl = new address[](1);
        wl[0] = whitelisted1;

        vm.expectEmit(true, true, true, true);
        emit SniperProtection.SniperProtectionInitialized(123, 234, 1 hours, wl);
        _deployCustom(123, 234, 1 hours, wl);
    }

    function test_revertsMaxBuyPerTxBpsTooLow() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.MaxBuyPerTxBpsTooLow.selector);
        _initClone(clone, 9, DEFAULT_MAX_WALLET_BPS, DEFAULT_WINDOW, new address[](0));
    }

    function test_revertsMaxBuyPerTxBpsTooHigh() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.MaxBuyPerTxBpsTooHigh.selector);
        _initClone(clone, 301, DEFAULT_MAX_WALLET_BPS, DEFAULT_WINDOW, new address[](0));
    }

    function test_revertsMaxWalletBpsTooLow() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.MaxWalletBpsTooLow.selector);
        _initClone(clone, DEFAULT_MAX_BUY_BPS, 9, DEFAULT_WINDOW, new address[](0));
    }

    function test_revertsMaxWalletBpsTooHigh() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.MaxWalletBpsTooHigh.selector);
        _initClone(clone, DEFAULT_MAX_BUY_BPS, 301, DEFAULT_WINDOW, new address[](0));
    }

    function test_revertsMaxBuyPerTxBpsExceedsMaxWalletBps() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.MaxBuyPerTxBpsExceedsMaxWalletBps.selector);
        _initClone(clone, 200, 100, DEFAULT_WINDOW, new address[](0));
    }

    function test_revertsProtectionWindowTooShort() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.ProtectionWindowTooShort.selector);
        _initClone(clone, DEFAULT_MAX_BUY_BPS, DEFAULT_MAX_WALLET_BPS, 59 seconds, new address[](0));
    }

    function test_revertsProtectionWindowTooLong() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.ProtectionWindowTooLong.selector);
        _initClone(clone, DEFAULT_MAX_BUY_BPS, DEFAULT_MAX_WALLET_BPS, 1 days + 1, new address[](0));
    }

    function test_revertsWhitelistTooLong() public {
        uint256 max = SniperProtection(address(_token())).MAX_WHITELISTED();
        address[] memory wl = new address[](max + 1);
        for (uint256 i; i < wl.length; ++i) {
            wl[i] = address(uint160(0x1000 + i));
        }
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.WhitelistTooLong.selector);
        _initClone(clone, DEFAULT_MAX_BUY_BPS, DEFAULT_MAX_WALLET_BPS, DEFAULT_WINDOW, wl);
    }

    function test_acceptsWhitelistAtMaxLength() public {
        uint256 max = SniperProtection(address(_token())).MAX_WHITELISTED();
        address[] memory wl = new address[](max);
        for (uint256 i; i < max; ++i) {
            wl[i] = address(uint160(0x2000 + i));
        }
        RealmToken t = _deployCustom(DEFAULT_MAX_BUY_BPS, DEFAULT_MAX_WALLET_BPS, DEFAULT_WINDOW, wl);

        SniperProtection sp = SniperProtection(address(t));
        for (uint256 i; i < max; ++i) {
            assertTrue(sp.sniperBypass(wl[i]));
        }
    }

    /// @dev Deploy a fresh clone (pre-init). Split from `_initClone` so revert tests can
    ///      wrap only the init call with `expectRevert` (the CREATE opcode otherwise confuses it).
    function _cloneImpl() internal virtual returns (address);

    /// @dev Initialize a clone with the given configs.
    function _initClone(address clone, uint16 maxBuyBps, uint16 maxWalletBps, uint40 window, address[] memory whitelist)
        internal
        virtual;

    /// @dev Convenience: clone + init in one step, returning the typed token.
    function _deployCustom(uint16 maxBuyBps, uint16 maxWalletBps, uint40 window, address[] memory whitelist)
        internal
        returns (RealmToken)
    {
        address clone = _cloneImpl();
        _initClone(clone, maxBuyBps, maxWalletBps, window, whitelist);
        return RealmToken(payable(clone));
    }

    /// @dev Generic accessor for `maxTokenPurchase` against the variant under test.
    function _maxBuy(address account) internal view returns (uint256) {
        return _token().maxTokenPurchase(account);
    }

    /// -------------------- maxTokenPurchase tests --------------------

    function test_maxTokenPurchase_freshBuyerReturnsMaxTx() public view {
        // Defaults: MAX_BUY_PER_TX == MAX_WALLET. With balance=0, walletRemaining == MAX_WALLET,
        // so min(MAX_BUY_PER_TX, MAX_WALLET) == MAX_BUY_PER_TX.
        assertEq(_maxBuy(buyer), MAX_BUY_PER_TX);
    }

    function test_maxTokenPurchase_partialBalanceShrinksReturn() public {
        _curveBuy(buyer, MAX_BUY_PER_TX / 2);
        // walletRemaining = MAX_WALLET - MAX_BUY_PER_TX/2 < MAX_BUY_PER_TX, so wallet binds.
        assertEq(_maxBuy(buyer), MAX_WALLET - MAX_BUY_PER_TX / 2);
    }

    function test_maxTokenPurchase_walletAtCapReturnsZero() public {
        _curveBuy(buyer, MAX_WALLET);
        assertEq(_maxBuy(buyer), 0);
    }

    function test_maxTokenPurchase_whitelistedReturnsMax() public view {
        assertEq(_maxBuy(whitelisted1), type(uint256).max);
        assertEq(_maxBuy(whitelisted2), type(uint256).max);
    }

    function test_maxTokenPurchase_afterWindowReturnsMax() public {
        uint40 launchTs = IRealmToken(address(_token())).launchTimestamp();
        vm.warp(launchTs + DEFAULT_WINDOW);
        assertEq(_maxBuy(buyer), type(uint256).max);
    }

    function test_maxTokenPurchase_afterGraduationReturnsMax() public {
        vm.prank(address(graduator));
        _token().markGraduated();
        assertEq(_maxBuy(buyer), type(uint256).max);
    }

    /// @dev With asymmetric configs (maxBuyPerTxBps < maxWalletBps), the tx cap binds for a
    ///      fresh buyer regardless of the wallet cap.
    function test_maxTokenPurchase_txCapBindsForFreshBuyerWithAsymmetricConfigs() public {
        uint16 buyBps = 100; // 1%
        uint16 walletBps = 300; // 3%
        RealmToken t = _deployCustom(buyBps, walletBps, DEFAULT_WINDOW, new address[](0));

        uint256 expectedMaxTx = (TOTAL_SUPPLY * buyBps) / 10_000;
        assertEq(t.maxTokenPurchase(buyer), expectedMaxTx);
    }

    /// @dev Returned value matches the largest non-reverting buy: buying exactly that amount
    ///      succeeds, while one wei over reverts. Anchors the view to the enforcement path.
    function test_maxTokenPurchase_matchesEnforcementBoundary() public {
        uint256 max = _maxBuy(buyer);

        // Boundary buy succeeds.
        _curveBuy(buyer, max);
        assertEq(_token().balanceOf(buyer), max);

        // One wei over the (now-reduced) returned value reverts.
        uint256 maxAfter = _maxBuy(buyer);
        if (maxAfter > 0) {
            vm.prank(launchpad);
            vm.expectRevert();
            _token().transfer(buyer, maxAfter + 1);
        }
    }
}

/// -------------------- Plain variant --------------------

contract RealmTokenSniperProtectedTest is SniperProtectionBaseTest {
    RealmToken internal token;
    RealmToken internal impl;

    function setUp() public {
        launchpadMock = new MockLaunchpad();
        launchpad = address(launchpadMock);

        graduator = new MockGraduator(makeAddr("pair"));
        impl = new RealmToken();
        token = RealmToken(Clones.clone(address(impl)));
        token.initialize(
            IRealmToken.InitializeParams({
                name: "TestSniper",
                symbol: "TSNP",
                tokenOwner: tokenOwner,
                graduator: address(graduator),
                launchpad: launchpad,
                feeHandler: feeHandler,
                vaultAllocation: 0,
                lpFeeBps: 100,
                treasuryShareBps: 10_000,
                swapLpFeeBps: 0
            }),
            _defaultCfg()
        );
    }

    function _token() internal view override returns (RealmToken) {
        return RealmToken(address(token));
    }

    function _cloneImpl() internal override returns (address) {
        return Clones.clone(address(impl));
    }

    function _initClone(address clone, uint16 maxBuyBps, uint16 maxWalletBps, uint40 window, address[] memory whitelist)
        internal
        override
    {
        RealmToken(clone)
            .initialize(
                IRealmToken.InitializeParams({
                    name: "CustomSniper",
                    symbol: "CSNP",
                    tokenOwner: tokenOwner,
                    graduator: address(graduator),
                    launchpad: launchpad,
                    feeHandler: feeHandler,
                    vaultAllocation: 0,
                    lpFeeBps: 100,
                    treasuryShareBps: 10_000,
                    swapLpFeeBps: 0
                }),
                AntiSniperConfigs({
                    maxBuyPerTxBps: maxBuyBps,
                    maxWalletBps: maxWalletBps,
                    protectionWindowSeconds: window,
                    whitelist: whitelist
                })
            );
    }
}

/// -------------------- Taxable variant --------------------

contract RealmTaxableTokenUniV4SniperProtectedTest is SniperProtectionBaseTest {
    RealmTaxableTokenUniV4 internal token;
    RealmTaxableTokenUniV4 internal impl;

    function setUp() public {
        vm.chainId(DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID);

        launchpadMock = new MockLaunchpad();
        launchpad = address(launchpadMock);

        graduator = new MockGraduator(DeploymentAddressesEthereumMainnet.UNIV4_POOL_MANAGER);
        impl = new RealmTaxableTokenUniV4();
        token = RealmTaxableTokenUniV4(payable(Clones.clone(address(impl))));
        token.initialize(
            IRealmToken.InitializeParams({
                name: "TestSniperTax",
                symbol: "TSNT",
                tokenOwner: tokenOwner,
                graduator: address(graduator),
                launchpad: launchpad,
                feeHandler: feeHandler,
                vaultAllocation: 0,
                lpFeeBps: 100,
                treasuryShareBps: 10_000,
                swapLpFeeBps: 100
            }),
            TaxConfigs({
                buyTaxBps: 100,
                sellTaxBps: 100,
                taxDurationSeconds: uint32(1 days),
                startTaxFromLaunch: true,
                buyTaxDecayStartBps: 0,
                sellTaxDecayStartBps: 0,
                taxDecayDuration: 0
            }),
            _defaultCfg()
        );
    }

    function _token() internal view override returns (RealmToken) {
        return RealmToken(payable(address(token)));
    }

    function _cloneImpl() internal override returns (address) {
        return Clones.clone(address(impl));
    }

    function _initClone(address clone, uint16 maxBuyBps, uint16 maxWalletBps, uint40 window, address[] memory whitelist)
        internal
        override
    {
        RealmTaxableTokenUniV4(payable(clone))
            .initialize(
                IRealmToken.InitializeParams({
                    name: "CustomSniperTax",
                    symbol: "CSNT",
                    tokenOwner: tokenOwner,
                    graduator: address(graduator),
                    launchpad: launchpad,
                    feeHandler: feeHandler,
                    vaultAllocation: 0,
                    lpFeeBps: 100,
                    treasuryShareBps: 10_000,
                    swapLpFeeBps: 100
                }),
                TaxConfigs({
                    buyTaxBps: 100,
                    sellTaxBps: 100,
                    taxDurationSeconds: uint32(1 days),
                    startTaxFromLaunch: true,
                    buyTaxDecayStartBps: 0,
                    sellTaxDecayStartBps: 0,
                    taxDecayDuration: 0
                }),
                AntiSniperConfigs({
                    maxBuyPerTxBps: maxBuyBps,
                    maxWalletBps: maxWalletBps,
                    protectionWindowSeconds: window,
                    whitelist: whitelist
                })
            );
    }
}
