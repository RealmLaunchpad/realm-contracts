// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Chain-neutral data model for Realm fork integration happy-path cases.
library ForkIntegrationCaseLib {
    enum FactoryKind {
        UniV2,
        UniV4
    }

    enum TaxMode {
        NoTax,
        BuyAndSellTax
    }

    enum SniperMode {
        NoSniper,
        Sniper
    }

    enum OwnershipMode {
        KeepOwner,
        RenounceOwnership
    }

    enum CreatorBuyMode {
        None,
        SingleSupplyReceiver,
        MultipleSupplyReceivers
    }

    enum FeeMode {
        SingleClaimable,
        SingleDirect,
        MultipleClaimable,
        MultipleClaimablePlusOneDirect
    }

    struct IntegrationCase {
        FactoryKind factoryKind;
        TaxMode taxMode;
        SniperMode sniperMode;
        OwnershipMode ownershipMode;
        CreatorBuyMode creatorBuyMode;
        FeeMode feeMode;
    }

    struct ForkChainConfig {
        string rpcUrlEnv;
        uint256 chainId;
        uint256 forkBlock;
        address launchpad;
        address quoter;
        address bondingCurve;
        address graduatorV2;
        address graduatorV4;
        address masterFeeHandler;
        address factoryV2Unified;
        address factoryV4Unified;
        address tokenImpl;
        address taxTokenImpl;
        address weth;
        address uniV2Router;
        address uniV2Factory;
        bytes32 uniV2PairInitCodeHash;
        address uniV4PoolManager;
        address uniV4PositionManager;
        address uniV4UniversalRouter;
        address permit2;
        address uniV4Hook;
    }

    struct CaseActors {
        address creator;
        address launchBuyer;
        address ammBuyer;
        address feeDirect;
        address feeA;
        address feeB;
        address supplyReceiver;
    }
}
