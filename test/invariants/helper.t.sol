// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {TaxConfigInit} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {TokenState} from "src/types/tokenData.sol";

contract InvariantsHelperLaunchpad is Test {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");

    address public currentActor;
    EnumerableSet.AddressSet internal _actors;

    // non graduated tokens
    EnumerableSet.AddressSet internal _tokens;
    // graduated tokens
    EnumerableSet.AddressSet internal _graduatedTokens;

    address public selectedToken;
    uint256 public timestamp;

    uint256 MAX_TIME_JUMP = 1 days;
    uint256 MIN_TIME_JUMP = 1; // seconds

    RealmLaunchpad public launchpad;

    RealmFactoryUniV2Unified public factoryV2;
    RealmFactoryUniV4Unified public factoryV4;
    address public tokenImpl;

    mapping(address => uint256) public aggregatedEthForBuys;
    mapping(address => uint256) public aggregatedTokensBought;
    mapping(address => uint256) public aggregatedTokensSold;
    mapping(address => uint256) public aggregatedEthFromSells;
    mapping(address => bool) public graduatedTokens;

    uint256 public globalAggregatedEthForBuys;
    uint256 public globalAggregatedTokensBought;
    uint256 public globalAggregatedTokensSold;
    uint256 public globalAggregatedEthFromSells;

    uint256 constant FAR_IN_FUTURE = 9758664012;
    uint256 internal _saltCounter;

    /// @dev The factory namespaces the CREATE2 salt by the deployer (`keccak256(msg.sender, salt)`),
    ///      so mining must predict against the same namespaced salt for the account that will deploy.
    function _nextValidSalt(address factory, address impl, address deployer) internal returns (bytes32) {
        for (uint256 i = _saltCounter;; i++) {
            bytes32 salt = bytes32(i);
            address predicted = Clones.predictDeterministicAddress(impl, _namespacedSalt(deployer, salt), factory);
            if (uint16(uint160(predicted)) == 0x1110) {
                _saltCounter = i + 1;
                return salt;
            }
        }
    }

    /// @dev keccak256(abi.encodePacked(deployer, salt)) in scratch space — the loop above calls this
    ///      ~65k times per salt, and `abi.encodePacked` would leak memory each call (quadratic
    ///      memory-expansion gas → MemoryOOG).
    function _namespacedSalt(address deployer, bytes32 salt) internal pure returns (bytes32 result) {
        assembly {
            mstore(0x00, shl(96, deployer))
            mstore(0x14, salt)
            result := keccak256(0x00, 0x34)
        }
    }

    /////////////////////////////////////////////////////
    constructor(
        RealmLaunchpad _launchpad,
        RealmFactoryUniV2Unified _factoryV2,
        RealmFactoryUniV4Unified _factoryV4,
        address _tokenImpl
    ) {
        launchpad = _launchpad;
        factoryV2 = _factoryV2;
        factoryV4 = _factoryV4;
        tokenImpl = _tokenImpl;

        _actors.add(address(makeAddr("actor1")));
        _actors.add(address(makeAddr("actor2")));
        _actors.add(address(makeAddr("actor3")));
        _actors.add(address(makeAddr("actor4")));
        _actors.add(address(makeAddr("actor5")));
        _actors.add(address(makeAddr("actor6")));
        _actors.add(address(makeAddr("actor7")));
        _actors.add(address(makeAddr("actor8")));
        _actors.add(address(makeAddr("actor9")));
        _actors.add(address(makeAddr("actor10")));

        for (uint256 i = 0; i < _actors.length(); i++) {
            deal(_actors.at(i), 100 ether);
        }

        // Add the treasury to _actors, but without ether
        _actors.add(admin);
        _actors.add(treasury);
    }

    modifier passTime(uint256 seed) {
        timestamp += _bound(seed, MIN_TIME_JUMP, MAX_TIME_JUMP);
        vm.warp(timestamp);
        _;
    }

    modifier choseActor(uint256 seed) {
        currentActor = _actors.at(seed % _actors.length());
        _;
    }

    modifier selectToken(uint256 seed) {
        if (_tokens.length() == 0) {
            selectedToken = address(0);
        } else {
            selectedToken = _tokens.at(seed % _tokens.length());
        }
        _;
    }

    //////////////////////////////////////////////////////////
    // UTILS
    //////////////////////////////////////////////////////////

    function createToken(uint256 seed) public passTime(seed) choseActor(seed) {
        address token;
        IRealmFactory.SupplyShare[] memory noSs = new IRealmFactory.SupplyShare[](0);
        IRealmFactory.FeeShare[] memory creatorFs = new IRealmFactory.FeeShare[](1);
        creatorFs[0] = IRealmFactory.FeeShare({account: currentActor, shares: 10_000, directFeesEnabled: false});
        if (seed % 2 == 0) {
            bytes32 salt = _nextValidSalt(address(factoryV2), tokenImpl, currentActor);
            vm.prank(currentActor);
            token = factoryV2.createToken(
                "TestToken", "TEST", salt, creatorFs, noSs, _emptyTaxCfg(), _emptyAntiSniperCfg()
            );
        } else {
            bytes32 salt = _nextValidSalt(address(factoryV4), tokenImpl, currentActor);
            vm.prank(currentActor);
            token = factoryV4.createToken(
                "TestToken", "TEST", salt, creatorFs, noSs, false, _emptyTaxCfg(), _emptyAntiSniperCfg()
            );
        }
        _tokens.add(token);
    }

    function _emptyTaxCfg() internal pure returns (TaxConfigInit memory) {
        return TaxConfigInit({buyTaxBps: 0, sellTaxBps: 0, taxDurationSeconds: 0, startTaxFromLaunch: false});
    }

    function _emptyAntiSniperCfg() internal pure returns (AntiSniperConfigs memory) {
        return AntiSniperConfigs({
            maxBuyPerTxBps: 0, maxWalletBps: 0, protectionWindowSeconds: 0, whitelist: new address[](0)
        });
    }

    function buy1(uint256 seed, uint256 amount) public {
        if (_tokens.length() == 0) return;
        _launchpadBuy(seed, amount);
    }

    function buy2(uint256 seed, uint256 amount) public {
        if (_tokens.length() == 0) return;
        _launchpadBuy(seed, amount);
    }

    function sell1(uint256 seed, uint256 amount) public {
        if (_tokens.length() == 0) return;
        _sell(seed, amount);
    }

    function sell2(uint256 seed, uint256 amount) public {
        if (_tokens.length() == 0) return;
        _sell(seed, amount);
    }

    function _launchpadBuy(uint256 seed, uint256 amount) internal passTime(seed) choseActor(seed) selectToken(seed) {
        if (selectedToken == address(0)) return;
        TokenState memory state = launchpad.getTokenState(selectedToken);
        if (state.graduated) return;

        uint256 maxEthToBuy = launchpad.getMaxEthToSpend(selectedToken) - state.ethCollected;

        // graduation happens at roughly 8 eth
        // purchase exceeds when trying to purchase more than 8.5 eth more or less
        uint256 ethToSpend = _bound(amount, 1, maxEthToBuy + 0.1 ether);
        deal(currentActor, ethToSpend);

        vm.prank(currentActor);
        uint256 tokensReceived = launchpad.buyTokensWithExactEth{value: ethToSpend}(selectedToken, 0, FAR_IN_FUTURE);

        aggregatedEthForBuys[selectedToken] += ethToSpend;
        aggregatedTokensBought[selectedToken] += tokensReceived;
        globalAggregatedEthForBuys += ethToSpend;
        globalAggregatedTokensBought += tokensReceived;

        if (launchpad.getTokenState(selectedToken).graduated) {
            graduatedTokens[selectedToken] = true;
            _tokens.remove(selectedToken);
            _graduatedTokens.add(selectedToken);
        }
    }

    function _sell(uint256 seed, uint256 amount) internal passTime(seed) choseActor(seed) selectToken(seed) {
        if (selectedToken == address(0)) return;

        uint256 tokenBalance = IERC20(selectedToken).balanceOf(currentActor);
        if (tokenBalance == 0) return;

        TokenState memory state = launchpad.getTokenState(selectedToken);
        if (state.graduated) return;

        uint256 tokensToSell = _bound(amount, 1, tokenBalance);

        vm.prank(currentActor);
        uint256 ethReceived = launchpad.sellExactTokens(selectedToken, tokensToSell, 0, FAR_IN_FUTURE);

        aggregatedTokensSold[selectedToken] += tokensToSell;
        aggregatedEthFromSells[selectedToken] += ethReceived;
        globalAggregatedTokensSold += tokensToSell;
        globalAggregatedEthFromSells += ethReceived;
    }

    //////////////////////////// utility functions ///////////////////////
    function ethCollected(address token) public view returns (uint256) {
        TokenState memory state = launchpad.getTokenState(token);
        return state.ethCollected;
    }

    function actorAt(uint256 i) public view returns (address) {
        return _actors.at(i);
    }

    function nActors() public view returns (uint256) {
        return _actors.length();
    }

    function tokenAt(uint256 i) public view returns (address) {
        return _tokens.at(i);
    }

    function nTokens() public view returns (uint256) {
        return _tokens.length();
    }

    function graduatedTokenAt(uint256 i) public view returns (address) {
        return _graduatedTokens.at(i);
    }

    function nGraduatedTokens() public view returns (uint256) {
        return _graduatedTokens.length();
    }
}
