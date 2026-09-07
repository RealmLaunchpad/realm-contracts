// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {ForkIntegrationConfig} from "test/integration/fork/config/ForkIntegrationConfig.t.sol";
import {ForkIntegrationCaseLib} from "test/integration/fork/base/ForkIntegrationCaseLib.t.sol";

import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {RealmQuoter} from "src/RealmQuoter.sol";
import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {RealmMasterFeeHandler} from "src/feeHandlers/RealmMasterFeeHandler.sol";
import {RealmSwapHook} from "src/hooks/RealmSwapHook.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmQuoter2} from "src/interfaces/IRealmQuoter2.sol";
import {LimitReason} from "src/interfaces/IRealmQuoter.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {TaxConfigInit, TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

interface ISniperProtectionRead {
    function maxBuyPerTxBps() external view returns (uint16);
    function maxWalletBps() external view returns (uint16);
    function protectionWindowSeconds() external view returns (uint40);
    function launchTimestamp() external view returns (uint40);
}

/// @notice Common setup and lifecycle helpers for chain-neutral Realm fork integration tests.
abstract contract ForkIntegrationBase is ForkIntegrationConfig {
    using ForkIntegrationCaseLib for *;

    uint256 internal constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant DEADLINE = type(uint256).max;

    uint16 internal constant TAX_BUY_BPS = 200;
    uint16 internal constant TAX_SELL_BPS = 400;
    uint32 internal constant TAX_DURATION_SECONDS = uint32(7 days);

    uint16 internal constant SNIPER_MAX_BUY_BPS = 300;
    uint16 internal constant SNIPER_MAX_WALLET_BPS = 300;
    uint40 internal constant SNIPER_WINDOW_SECONDS = uint40(1 hours);

    uint256 internal constant DEPLOYER_BUY_ETH = 0.02 ether;
    uint256 internal constant LAUNCHPAD_BUY_REQUEST_ETH = 0.08 ether;
    uint256 internal constant AMM_BUY_ETH = 0.1 ether;

    ForkIntegrationCaseLib.ForkChainConfig internal forkCfg;

    RealmLaunchpad internal launchpad;
    RealmQuoter internal quoter;
    RealmFactoryUniV2Unified internal factoryV2;
    RealmFactoryUniV4Unified internal factoryV4;
    RealmMasterFeeHandler internal feeHandler;

    struct CreateInputs {
        IRealmFactory.FeeShare[] fees;
        IRealmFactory.SupplyShare[] supply;
        uint256 ethValue;
        address impl;
        bytes32 salt;
        address expected;
    }

    uint256 internal _saltCounter;

    function _chainConfig() internal view virtual returns (ForkIntegrationCaseLib.ForkChainConfig memory);

    function setUp() public virtual {
        forkCfg = _chainConfig();
        string memory rpcUrl = vm.envString(forkCfg.rpcUrlEnv);
        if (forkCfg.forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkCfg.forkBlock);
        }
        assertEq(block.chainid, forkCfg.chainId, "wrong fork chain id");

        _assertCoreConfigPresent();

        launchpad = RealmLaunchpad(payable(forkCfg.launchpad));
        quoter = RealmQuoter(forkCfg.quoter);
        factoryV2 = RealmFactoryUniV2Unified(forkCfg.factoryV2Unified);
        factoryV4 = RealmFactoryUniV4Unified(forkCfg.factoryV4Unified);
        feeHandler = RealmMasterFeeHandler(forkCfg.masterFeeHandler);

        _assertDeployedAddressConfig();
    }

    function _assertCoreConfigPresent() internal view {
        require(forkCfg.launchpad != address(0), "missing launchpad");
        require(forkCfg.quoter != address(0), "missing quoter");
        require(forkCfg.bondingCurve != address(0), "missing bonding curve");
        require(forkCfg.graduatorV2 != address(0), "missing v2 graduator");
        require(forkCfg.graduatorV4 != address(0), "missing v4 graduator");
        require(forkCfg.masterFeeHandler != address(0), "missing master fee handler");
        require(forkCfg.factoryV2Unified != address(0), "missing v2 unified factory");
        require(forkCfg.factoryV4Unified != address(0), "missing v4 unified factory");
        require(forkCfg.tokenImpl != address(0), "missing token impl");
        require(forkCfg.taxTokenImpl != address(0), "missing tax token impl");
        require(forkCfg.weth != address(0), "missing WETH");
        require(forkCfg.uniV2Router != address(0), "missing UniV2 router");
        require(forkCfg.uniV2Factory != address(0), "missing UniV2 factory");
        require(forkCfg.uniV4PoolManager != address(0), "missing UniV4 pool manager");
        require(forkCfg.uniV4PositionManager != address(0), "missing UniV4 position manager");
        require(forkCfg.uniV4UniversalRouter != address(0), "missing UniV4 universal router");
        require(forkCfg.permit2 != address(0), "missing Permit2");
        require(forkCfg.uniV4Hook != address(0), "missing UniV4 hook");
    }

    function _assertDeployedAddressConfig() internal view {
        _assertCode(forkCfg.launchpad, "launchpad code missing");
        _assertCode(forkCfg.quoter, "quoter code missing");
        _assertCode(forkCfg.masterFeeHandler, "master fee handler code missing");
        _assertCode(forkCfg.factoryV2Unified, "v2 factory code missing");
        _assertCode(forkCfg.factoryV4Unified, "v4 factory code missing");
        _assertCode(forkCfg.uniV4Hook, "v4 hook code missing");

        assertTrue(launchpad.whitelistedFactories(forkCfg.factoryV2Unified), "v2 factory not whitelisted");
        assertTrue(launchpad.whitelistedFactories(forkCfg.factoryV4Unified), "v4 factory not whitelisted");

        assertEq(address(quoter.launchpad()), forkCfg.launchpad, "quoter launchpad mismatch");

        assertEq(address(factoryV2.LAUNCHPAD()), forkCfg.launchpad, "v2 launchpad mismatch");
        assertEq(address(factoryV2.BONDING_CURVE()), forkCfg.bondingCurve, "v2 curve mismatch");
        assertEq(address(factoryV2.GRADUATOR()), forkCfg.graduatorV2, "v2 graduator mismatch");
        assertEq(address(factoryV2.MASTER_FEE_HANDLER()), forkCfg.masterFeeHandler, "v2 handler mismatch");
        assertEq(factoryV2.TOKEN_IMPL_BASE(), forkCfg.tokenImpl, "v2 base impl mismatch");

        assertEq(address(factoryV4.LAUNCHPAD()), forkCfg.launchpad, "v4 launchpad mismatch");
        assertEq(address(factoryV4.BONDING_CURVE()), forkCfg.bondingCurve, "v4 curve mismatch");
        assertEq(address(factoryV4.GRADUATOR()), forkCfg.graduatorV4, "v4 graduator mismatch");
        assertEq(address(factoryV4.MASTER_FEE_HANDLER()), forkCfg.masterFeeHandler, "v4 handler mismatch");
        assertEq(factoryV4.TOKEN_IMPL_BASE(), forkCfg.tokenImpl, "v4 base impl mismatch");
        assertEq(factoryV4.TOKEN_IMPL_TAX(), forkCfg.taxTokenImpl, "v4 tax impl mismatch");

        assertEq(IUniswapV2Router(forkCfg.uniV2Router).WETH(), forkCfg.weth, "v2 router WETH mismatch");
        assertEq(IUniswapV2Router(forkCfg.uniV2Router).factory(), forkCfg.uniV2Factory, "v2 router factory mismatch");
    }

    function _assertCode(address target, string memory message) internal view {
        require(target.code.length > 0, message);
    }

    function _actors(uint256 caseIndex) internal returns (ForkIntegrationCaseLib.CaseActors memory a) {
        a.creator = _caseAddress(caseIndex, 1);
        a.launchBuyer = _caseAddress(caseIndex, 2);
        a.ammBuyer = _caseAddress(caseIndex, 3);
        a.feeDirect = _caseAddress(caseIndex, 4);
        a.feeA = _caseAddress(caseIndex, 5);
        a.feeB = _caseAddress(caseIndex, 6);
        a.supplyReceiver = _caseAddress(caseIndex, 7);

        vm.deal(a.creator, INITIAL_ETH_BALANCE);
        vm.deal(a.launchBuyer, INITIAL_ETH_BALANCE);
        vm.deal(a.ammBuyer, INITIAL_ETH_BALANCE);
    }

    function _caseAddress(uint256 caseIndex, uint256 role) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("REALM_FORK_INTEGRATION", caseIndex, role)))));
    }

    function _graduationBuyer(uint256 caseIndex, uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("REALM_FORK_INTEGRATION_GRAD", caseIndex, i)))));
    }

    function _isV4(ForkIntegrationCaseLib.IntegrationCase memory c) internal pure returns (bool) {
        return c.factoryKind == ForkIntegrationCaseLib.FactoryKind.UniV4;
    }

    function _hasTax(ForkIntegrationCaseLib.IntegrationCase memory c) internal pure returns (bool) {
        return c.taxMode == ForkIntegrationCaseLib.TaxMode.BuyAndSellTax;
    }

    function _hasSniper(ForkIntegrationCaseLib.IntegrationCase memory c) internal pure returns (bool) {
        return c.sniperMode == ForkIntegrationCaseLib.SniperMode.Sniper;
    }

    function _renouncesOwnership(ForkIntegrationCaseLib.IntegrationCase memory c) internal pure returns (bool) {
        return c.ownershipMode == ForkIntegrationCaseLib.OwnershipMode.RenounceOwnership;
    }

    function _factory(ForkIntegrationCaseLib.IntegrationCase memory c) internal view returns (address) {
        return _isV4(c) ? address(factoryV4) : address(factoryV2);
    }

    function _taxCfg(ForkIntegrationCaseLib.IntegrationCase memory c) internal pure returns (TaxConfigInit memory) {
        if (_hasTax(c)) {
            return TaxConfigInit({
                buyTaxBps: TAX_BUY_BPS,
                sellTaxBps: TAX_SELL_BPS,
                taxDurationSeconds: TAX_DURATION_SECONDS,
                startTaxFromLaunch: true
            });
        }
        return TaxConfigInit({buyTaxBps: 0, sellTaxBps: 0, taxDurationSeconds: 0, startTaxFromLaunch: false});
    }

    /// @dev Lift a legacy `TaxConfigInit` into the full `TaxConfigs` (decay fields zeroed) for the
    ///      `previewTokenImplementation` view, which now takes `TaxConfigs`. Local copy because this base
    ///      does not inherit the launchpad test base's `_toCfgs`.
    function _toCfgs(TaxConfigInit memory legacy) internal pure returns (TaxConfigs memory) {
        return TaxConfigs({
            buyTaxBps: legacy.buyTaxBps,
            sellTaxBps: legacy.sellTaxBps,
            taxDurationSeconds: legacy.taxDurationSeconds,
            startTaxFromLaunch: legacy.startTaxFromLaunch,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0
        });
    }

    function _antiSniperCfg(ForkIntegrationCaseLib.IntegrationCase memory c)
        internal
        pure
        returns (AntiSniperConfigs memory)
    {
        if (_hasSniper(c)) {
            return AntiSniperConfigs({
                maxBuyPerTxBps: SNIPER_MAX_BUY_BPS,
                maxWalletBps: SNIPER_MAX_WALLET_BPS,
                protectionWindowSeconds: SNIPER_WINDOW_SECONDS,
                whitelist: new address[](0)
            });
        }
        return AntiSniperConfigs({
            maxBuyPerTxBps: 0, maxWalletBps: 0, protectionWindowSeconds: 0, whitelist: new address[](0)
        });
    }

    function _feeShares(ForkIntegrationCaseLib.CaseActors memory a, ForkIntegrationCaseLib.FeeMode mode)
        internal
        pure
        returns (IRealmFactory.FeeShare[] memory fs)
    {
        if (mode == ForkIntegrationCaseLib.FeeMode.SingleClaimable) {
            fs = new IRealmFactory.FeeShare[](1);
            fs[0] = IRealmFactory.FeeShare({account: a.feeA, shares: 10_000, directFeesEnabled: false});
        } else if (mode == ForkIntegrationCaseLib.FeeMode.SingleDirect) {
            fs = new IRealmFactory.FeeShare[](1);
            fs[0] = IRealmFactory.FeeShare({account: a.feeDirect, shares: 10_000, directFeesEnabled: true});
        } else if (mode == ForkIntegrationCaseLib.FeeMode.MultipleClaimable) {
            fs = new IRealmFactory.FeeShare[](2);
            fs[0] = IRealmFactory.FeeShare({account: a.feeA, shares: 6_000, directFeesEnabled: false});
            fs[1] = IRealmFactory.FeeShare({account: a.feeB, shares: 4_000, directFeesEnabled: false});
        } else {
            fs = new IRealmFactory.FeeShare[](3);
            fs[0] = IRealmFactory.FeeShare({account: a.feeDirect, shares: 2_000, directFeesEnabled: true});
            fs[1] = IRealmFactory.FeeShare({account: a.feeA, shares: 5_000, directFeesEnabled: false});
            fs[2] = IRealmFactory.FeeShare({account: a.feeB, shares: 3_000, directFeesEnabled: false});
        }
    }

    function _supplyShares(ForkIntegrationCaseLib.CaseActors memory a, ForkIntegrationCaseLib.CreatorBuyMode mode)
        internal
        pure
        returns (IRealmFactory.SupplyShare[] memory ss, uint256 ethValue)
    {
        if (mode == ForkIntegrationCaseLib.CreatorBuyMode.None) {
            return (new IRealmFactory.SupplyShare[](0), 0);
        }

        ethValue = DEPLOYER_BUY_ETH;
        if (mode == ForkIntegrationCaseLib.CreatorBuyMode.SingleSupplyReceiver) {
            ss = new IRealmFactory.SupplyShare[](1);
            ss[0] = IRealmFactory.SupplyShare({account: a.creator, shares: 10_000});
        } else {
            ss = new IRealmFactory.SupplyShare[](2);
            ss[0] = IRealmFactory.SupplyShare({account: a.creator, shares: 7_000});
            ss[1] = IRealmFactory.SupplyShare({account: a.supplyReceiver, shares: 3_000});
        }
    }

    function _previewImplementation(
        ForkIntegrationCaseLib.IntegrationCase memory c,
        IRealmFactory.FeeShare[] memory fees,
        IRealmFactory.SupplyShare[] memory supply
    ) internal view returns (address impl) {
        AntiSniperConfigs memory sniper = _antiSniperCfg(c);
        if (_isV4(c)) {
            impl = factoryV4.previewTokenImplementation(fees, supply, _toCfgs(_taxCfg(c)), sniper);
        } else {
            impl = factoryV2.previewTokenImplementation(
                fees,
                supply,
                _toCfgs(TaxConfigInit({buyTaxBps: 0, sellTaxBps: 0, taxDurationSeconds: 0, startTaxFromLaunch: false})),
                sniper
            );
        }
    }

    /// @dev The factory namespaces the CREATE2 salt by the deployer (`keccak256(msg.sender, salt)`),
    ///      so mining/prediction must use the same namespaced salt for the deploying account.
    function _nextValidSalt(address factory, address impl, address deployer) internal returns (bytes32 salt) {
        for (uint256 i = _saltCounter;; ++i) {
            salt = bytes32(i);
            address predicted = Clones.predictDeterministicAddress(impl, _namespacedSalt(deployer, salt), factory);
            if (uint16(uint160(predicted)) == 0x1110 && predicted.code.length == 0) {
                _saltCounter = i + 1;
                return salt;
            }
        }
    }

    /// @dev keccak256(abi.encodePacked(deployer, salt)) in scratch space so the mining loop (which
    ///      calls this ~65k times per salt) doesn't leak memory (quadratic memory-expansion gas →
    ///      MemoryOOG).
    function _namespacedSalt(address deployer, bytes32 salt) internal pure returns (bytes32 result) {
        assembly {
            mstore(0x00, shl(96, deployer))
            mstore(0x14, salt)
            result := keccak256(0x00, 0x34)
        }
    }

    function _deployCaseToken(uint256 caseIndex, ForkIntegrationCaseLib.IntegrationCase memory c)
        internal
        returns (address token, ForkIntegrationCaseLib.CaseActors memory a)
    {
        a = _actors(caseIndex);
        CreateInputs memory input = _buildCreateInputs(c, a);
        token = _createToken(c, a.creator, input);

        assertEq(token, input.expected, "deployed token address mismatch");
        assertEq(uint16(uint160(token)), 0x1110, "token suffix mismatch");
        _assertTokenDeployment(c, token, a, input.impl, input.ethValue);
    }

    function _buildCreateInputs(
        ForkIntegrationCaseLib.IntegrationCase memory c,
        ForkIntegrationCaseLib.CaseActors memory a
    ) internal returns (CreateInputs memory input) {
        input.fees = _feeShares(a, c.feeMode);
        (input.supply, input.ethValue) = _supplyShares(a, c.creatorBuyMode);
        input.impl = _previewImplementation(c, input.fees, input.supply);
        input.salt = _nextValidSalt(_factory(c), input.impl, a.creator);
        input.expected =
            Clones.predictDeterministicAddress(input.impl, _namespacedSalt(a.creator, input.salt), _factory(c));
    }

    function _createToken(ForkIntegrationCaseLib.IntegrationCase memory c, address creator, CreateInputs memory input)
        internal
        returns (address token)
    {
        vm.prank(creator);
        if (_isV4(c)) {
            token = factoryV4.createToken{value: input.ethValue}(
                "Realm Integration",
                "REALMI",
                input.salt,
                input.fees,
                input.supply,
                _renouncesOwnership(c),
                _taxCfg(c),
                _antiSniperCfg(c)
            );
        } else {
            token = factoryV2.createToken{value: input.ethValue}(
                "Realm Integration",
                "REALMI",
                input.salt,
                input.fees,
                input.supply,
                TaxConfigInit({buyTaxBps: 0, sellTaxBps: 0, taxDurationSeconds: 0, startTaxFromLaunch: false}),
                _antiSniperCfg(c)
            );
        }
    }

    function _assertTokenDeployment(
        ForkIntegrationCaseLib.IntegrationCase memory c,
        address token,
        ForkIntegrationCaseLib.CaseActors memory a,
        address impl,
        uint256 deployerBuyEth
    ) internal view {
        assertEq(impl, _expectedImplFromConfig(c), "expected impl mismatch");
        assertEq(address(launchpad.getTokenConfig(token).bondingCurve), forkCfg.bondingCurve, "token curve mismatch");
        assertEq(IRealmToken(token).feeHandler(), forkCfg.masterFeeHandler, "token handler mismatch");
        assertEq(IRealmToken(token).graduator(), _isV4(c) ? forkCfg.graduatorV4 : forkCfg.graduatorV2, "graduator");

        if (!_isV4(c) || _renouncesOwnership(c)) {
            assertEq(IRealmToken(token).owner(), address(0), "owner should be renounced");
        } else {
            assertEq(IRealmToken(token).owner(), a.creator, "owner should be creator");
        }

        _assertTaxConfig(c, token);
        _assertSniperConfig(c, token);
        _assertFeeConfig(c, token, a);
        _assertCreatorBuyDistribution(c, token, a, deployerBuyEth);
    }

    function _expectedImplFromConfig(ForkIntegrationCaseLib.IntegrationCase memory c) internal view returns (address) {
        // Anti-sniper is a gated feature of the base/tax impls, so it no longer selects a distinct
        // implementation — only whether the token is taxable does.
        if (_isV4(c) && _hasTax(c)) return forkCfg.taxTokenImpl;
        return forkCfg.tokenImpl;
    }

    function _assertTaxConfig(ForkIntegrationCaseLib.IntegrationCase memory c, address token) internal view {
        IRealmToken.TaxConfig memory tax = IRealmToken(token).getTaxConfig();
        if (_hasTax(c)) {
            assertEq(tax.buyTaxBps, TAX_BUY_BPS, "buy tax mismatch");
            assertEq(tax.sellTaxBps, TAX_SELL_BPS, "sell tax mismatch");
            assertEq(tax.taxDurationSeconds, TAX_DURATION_SECONDS, "tax duration mismatch");
        } else {
            assertEq(tax.buyTaxBps, 0, "unexpected buy tax");
            assertEq(tax.sellTaxBps, 0, "unexpected sell tax");
            assertEq(tax.taxDurationSeconds, 0, "unexpected tax duration");
        }
    }

    function _assertSniperConfig(ForkIntegrationCaseLib.IntegrationCase memory c, address token) internal view {
        if (_hasSniper(c)) {
            ISniperProtectionRead sniper = ISniperProtectionRead(token);
            assertEq(sniper.maxBuyPerTxBps(), SNIPER_MAX_BUY_BPS, "sniper max buy mismatch");
            assertEq(sniper.maxWalletBps(), SNIPER_MAX_WALLET_BPS, "sniper max wallet mismatch");
            assertEq(sniper.protectionWindowSeconds(), SNIPER_WINDOW_SECONDS, "sniper window mismatch");
            assertGt(sniper.launchTimestamp(), 0, "missing launch timestamp");
        } else {
            assertEq(IRealmToken(token).maxTokenPurchase(address(0xBEEF)), type(uint256).max, "unexpected sniper cap");
        }
    }

    function _assertFeeConfig(
        ForkIntegrationCaseLib.IntegrationCase memory c,
        address token,
        ForkIntegrationCaseLib.CaseActors memory a
    ) internal view {
        if (c.feeMode == ForkIntegrationCaseLib.FeeMode.SingleClaimable) {
            _assertRecipient(token, a.feeA, 10_000, false);
            _assertDirectReceiverCount(token, 0);
        } else if (c.feeMode == ForkIntegrationCaseLib.FeeMode.SingleDirect) {
            _assertRecipient(token, a.feeDirect, 10_000, true);
            _assertDirectReceiverCount(token, 1);
        } else if (c.feeMode == ForkIntegrationCaseLib.FeeMode.MultipleClaimable) {
            _assertRecipient(token, a.feeA, 6_000, false);
            _assertRecipient(token, a.feeB, 4_000, false);
            _assertDirectReceiverCount(token, 0);
        } else {
            _assertRecipient(token, a.feeDirect, 2_000, true);
            _assertRecipient(token, a.feeA, 5_000, false);
            _assertRecipient(token, a.feeB, 3_000, false);
            _assertDirectReceiverCount(token, 1);
        }
    }

    function _assertRecipient(address token, address account, uint256 expectedBps, bool expectedDirect) internal view {
        (address[] memory recipients, uint256[] memory bps) = feeHandler.getRecipients(token);
        bool found;
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == account) {
                found = true;
                assertEq(bps[i], expectedBps, "recipient bps mismatch");
                break;
            }
        }
        assertTrue(found, "recipient missing");
        assertEq(feeHandler.isDirectReceiver(token, account), expectedDirect, "direct flag mismatch");
    }

    function _assertDirectReceiverCount(address token, uint256 expected) internal view {
        assertEq(feeHandler.getDirectReceivers(token).length, expected, "direct receiver count mismatch");
    }

    function _assertCreatorBuyDistribution(
        ForkIntegrationCaseLib.IntegrationCase memory c,
        address token,
        ForkIntegrationCaseLib.CaseActors memory a,
        uint256 deployerBuyEth
    ) internal view {
        uint256 creatorBal = IERC20(token).balanceOf(a.creator);
        uint256 receiverBal = IERC20(token).balanceOf(a.supplyReceiver);
        uint256 releasedSupply = launchpad.getTokenState(token).releasedSupply;
        assertEq(IERC20(token).balanceOf(_factory(c)), 0, "factory token dust");

        if (deployerBuyEth == 0) {
            assertEq(creatorBal, 0, "unexpected creator deployer-buy balance");
            assertEq(receiverBal, 0, "unexpected receiver deployer-buy balance");
            assertEq(releasedSupply, 0, "unexpected released supply");
            return;
        }

        assertGt(releasedSupply, 0, "missing deployer-buy released supply");

        if (c.creatorBuyMode == ForkIntegrationCaseLib.CreatorBuyMode.SingleSupplyReceiver) {
            assertEq(creatorBal, releasedSupply, "single supply receiver mismatch");
            assertEq(receiverBal, 0, "unexpected secondary supply receiver balance");
        } else if (c.creatorBuyMode == ForkIntegrationCaseLib.CreatorBuyMode.MultipleSupplyReceivers) {
            assertEq(creatorBal + receiverBal, releasedSupply, "multi supply total mismatch");
            assertApproxEqRel(creatorBal, releasedSupply * 7 / 10, 1e15, "creator supply share mismatch");
            assertApproxEqRel(receiverBal, releasedSupply * 3 / 10, 1e15, "receiver supply share mismatch");
        }
    }

    function _buyFromLaunchpadWithQuoter(address token, address buyer, uint256 requestedEth)
        internal
        returns (uint256 receivedTokens)
    {
        IRealmQuoter2.BuyExactEthQuote memory q = quoter.quoteBuyTokensWithExactEth(token, buyer, requestedEth);
        assertTrue(
            q.reason == LimitReason.NONE || q.reason == LimitReason.GRADUATION_EXCESS
                || q.reason == LimitReason.SNIPER_CAP,
            "unexpected buy quote reason"
        );
        assertGt(q.ethSpent, 0, "empty buy quote");
        assertGt(q.tokensToReceive, 0, "empty token quote");

        if (buyer.balance < q.ethSpent) vm.deal(buyer, q.ethSpent);
        uint256 beforeBal = IERC20(token).balanceOf(buyer);
        vm.prank(buyer);
        receivedTokens = launchpad.buyTokensWithExactEth{value: q.ethSpent}(token, 0, DEADLINE);
        assertEq(receivedTokens, q.tokensToReceive, "launchpad buy output mismatch");
        assertGt(IERC20(token).balanceOf(buyer), beforeBal, "launchpad buy did not deliver tokens");
    }

    function _sellToLaunchpadWithQuoter(address token, address seller, uint256 requestedTokens)
        internal
        returns (uint256 receivedEth)
    {
        IRealmQuoter2.SellExactTokensQuote memory q = quoter.quoteSellExactTokens(token, requestedTokens);
        assertEq(uint256(q.reason), uint256(LimitReason.NONE), "unexpected sell quote reason");
        assertGt(q.tokensSold, 0, "empty sell quote");
        assertGt(q.ethForSeller, 0, "empty ETH sell quote");

        uint256 beforeEth = seller.balance;
        vm.startPrank(seller);
        IERC20(token).approve(address(launchpad), q.tokensSold);
        receivedEth = launchpad.sellExactTokens(token, q.tokensSold, 0, DEADLINE);
        vm.stopPrank();

        assertEq(receivedEth, q.ethForSeller, "launchpad sell output mismatch");
        assertGt(seller.balance, beforeEth, "launchpad sell did not deliver ETH");
    }

    function _graduateWithQuoter(address token, uint256 caseIndex, bool hasSniper) internal {
        uint256 maxIterations = hasSniper ? 128 : 4;
        for (uint256 i; i < maxIterations; ++i) {
            if (launchpad.getTokenState(token).graduated) break;

            address buyer = hasSniper ? _graduationBuyer(caseIndex, i) : _graduationBuyer(caseIndex, 999);
            vm.deal(buyer, INITIAL_ETH_BALANCE);
            (uint256 maxEth, LimitReason reason) = quoter.getMaxEthToSpend(token, buyer);
            assertTrue(
                reason == LimitReason.GRADUATION_EXCESS || reason == LimitReason.SNIPER_CAP, "unexpected max buy reason"
            );
            assertGt(maxEth, 0, "empty max buy");
            _buyFromLaunchpadWithQuoter(token, buyer, maxEth);
        }

        assertTrue(launchpad.getTokenState(token).graduated, "launchpad did not graduate token");
        assertTrue(IRealmToken(token).graduated(), "token did not mark graduated");
    }

    function _singleToken(address token) internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = token;
    }

    function _claimable(address token, address account) internal view returns (uint256) {
        return feeHandler.getClaimable(_singleToken(token), account)[0];
    }

    function _claim(address token, address account) internal {
        vm.prank(account);
        feeHandler.claim(_singleToken(token));
    }

    function _assertFeeClaimsAndDirectReceivers(
        ForkIntegrationCaseLib.IntegrationCase memory c,
        address token,
        ForkIntegrationCaseLib.CaseActors memory a,
        uint256 directBalanceBeforeFees
    ) internal {
        if (c.feeMode == ForkIntegrationCaseLib.FeeMode.SingleClaimable) {
            _assertClaimIncreasesBalance(token, a.feeA);
        } else if (c.feeMode == ForkIntegrationCaseLib.FeeMode.SingleDirect) {
            assertGt(a.feeDirect.balance, directBalanceBeforeFees, "direct receiver did not receive ETH");
            assertEq(_claimable(token, a.feeDirect), 0, "direct receiver should not have pending claims");
        } else if (c.feeMode == ForkIntegrationCaseLib.FeeMode.MultipleClaimable) {
            uint256 claimA = _claimable(token, a.feeA);
            uint256 claimB = _claimable(token, a.feeB);
            assertGt(claimA, 0, "feeA missing claimable ETH");
            assertGt(claimB, 0, "feeB missing claimable ETH");
            assertApproxEqRel(claimA * 4, claimB * 6, 1e15, "claimable ratio mismatch");
            _claimAndAssertAmount(token, a.feeA, claimA);
            _claimAndAssertAmount(token, a.feeB, claimB);
        } else {
            assertGt(a.feeDirect.balance, directBalanceBeforeFees, "mixed direct receiver did not receive ETH");
            uint256 claimA = _claimable(token, a.feeA);
            uint256 claimB = _claimable(token, a.feeB);
            assertGt(claimA, 0, "mixed feeA missing claimable ETH");
            assertGt(claimB, 0, "mixed feeB missing claimable ETH");
            assertApproxEqRel(claimA * 3, claimB * 5, 1e15, "mixed claimable ratio mismatch");
            _claimAndAssertAmount(token, a.feeA, claimA);
            _claimAndAssertAmount(token, a.feeB, claimB);
        }
    }

    function _assertClaimIncreasesBalance(address token, address account) internal {
        uint256 amount = _claimable(token, account);
        assertGt(amount, 0, "missing claimable ETH");
        _claimAndAssertAmount(token, account, amount);
    }

    function _claimAndAssertAmount(address token, address account, uint256 expectedAmount) internal {
        uint256 beforeBal = account.balance;
        _claim(token, account);
        assertEq(account.balance - beforeBal, expectedAmount, "claim amount mismatch");
        assertEq(_claimable(token, account), 0, "claimable not cleared");
    }

    function _assertTaxLogSeen() internal {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 want = RealmSwapHook.CreatorTaxesAccrued.selector;
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == want) {
                found = true;
                break;
            }
        }
        assertTrue(found, "expected CreatorTaxesAccrued");
    }
}
