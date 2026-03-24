// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";
import { EdenLendingFacet } from "src/facets/EdenLendingFacet.sol";
import { EdenMetadataFacet } from "src/facets/EdenMetadataFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenCoreFacet } from "src/interfaces/IEdenCoreFacet.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { IEdenMetadataFacet } from "src/interfaces/IEdenMetadataFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { LibStEVEStorage } from "src/libraries/LibStEVEStorage.sol";

contract MetadataMockERC20 is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) { }
}

contract MetadataHarnessFacet is EdenMetadataFacet {
    function getStoredBasketMetadata(
        uint256 basketId
    )
        external
        view
        returns (
            string memory name,
            string memory symbol,
            string memory uri,
            address creator,
            uint64 createdAt,
            uint8 basketType
        )
    {
        LibEdenStorage.BasketMetadata storage metadata = LibEdenStorage.layout().basketMetadata[basketId];
        return (
            metadata.name,
            metadata.symbol,
            metadata.uri,
            metadata.creator,
            metadata.createdAt,
            metadata.basketType
        );
    }

    function setProtocolConfigValues(
        address treasury,
        uint16 treasuryFeeBps,
        uint16 feePotShareBps,
        uint16 protocolFeeSplitBps,
        uint256 basketCreationFee
    ) external {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        store.treasury = treasury;
        store.treasuryFeeBps = treasuryFeeBps;
        store.feePotShareBps = feePotShareBps;
        store.protocolFeeSplitBps = protocolFeeSplitBps;
        store.basketCreationFee = basketCreationFee;
    }

    function setVersionMetadata(
        string calldata protocolUri_,
        string calldata contractVersion_,
        address facet,
        string calldata facetVersion_
    ) external {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        store.protocolURI = protocolUri_;
        store.contractVersion = contractVersion_;
        store.facetVersions[facet] = facetVersion_;
    }

    function setFrozenFacetState(
        address facet,
        bool frozen
    ) external {
        LibEdenStorage.layout().frozenFacets[facet] = frozen;
    }

    function setRewardState(
        uint256 genesisTimestamp,
        uint256 epochDuration,
        uint256 halvingInterval,
        uint256 maxPeriods,
        uint256 baseRewardPerEpoch,
        uint256 totalEpochs,
        uint256 rewardReserve,
        uint256 rewardPerEpochOverride,
        uint256 maxRewardPerEpochOverride
    ) external {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        st.genesisTimestamp = genesisTimestamp;
        st.epochDuration = epochDuration;
        st.halvingInterval = halvingInterval;
        st.maxPeriods = maxPeriods;
        st.baseRewardPerEpoch = baseRewardPerEpoch;
        st.totalEpochs = totalEpochs;
        st.rewardReserve = rewardReserve;
        st.rewardPerEpochOverride = rewardPerEpochOverride;
        st.maxRewardPerEpochOverride = maxRewardPerEpochOverride;
    }
}

contract MetadataFacetTest is Test {
    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");

    EdenDiamond internal diamond;
    EdenCoreFacet internal coreFacet;
    EdenLendingFacet internal lendingFacet;
    MetadataHarnessFacet internal metadataFacet;
    MetadataMockERC20 internal eve;
    MetadataMockERC20 internal alt;
    address internal stEveToken;
    address internal basketToken;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        coreFacet = new EdenCoreFacet();
        lendingFacet = new EdenLendingFacet();
        metadataFacet = new MetadataHarnessFacet();
        eve = new MetadataMockERC20("EVE", "EVE");
        alt = new MetadataMockERC20("ALT", "ALT");

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");

        IEdenCoreFacet.CreateBasketParams memory steveParams = IEdenCoreFacet.CreateBasketParams({
            name: "stEVE",
            symbol: "stEVE",
            assets: _singleAddressArray(address(eve)),
            bundleAmounts: _singleUintArray(1_000e18),
            mintFeeBps: _singleUint16Array(0),
            burnFeeBps: _singleUint16Array(0),
            flashFeeBps: 30
        });

        IEdenCoreFacet.CreateBasketParams memory indexParams = IEdenCoreFacet.CreateBasketParams({
            name: "Basket",
            symbol: "BASK",
            assets: _doubleAddressArray(address(eve), address(alt)),
            bundleAmounts: _doubleUintArray(100e18, 50e18),
            mintFeeBps: _doubleUint16Array(0, 0),
            burnFeeBps: _doubleUint16Array(0, 0),
            flashFeeBps: 0
        });

        vm.startPrank(owner);
        (, stEveToken) = IEdenCoreFacet(address(diamond)).createBasket(steveParams);
        (, basketToken) = IEdenCoreFacet(address(diamond)).createBasket(indexParams);
        IEdenLendingFacet(address(diamond)).configureLending(1, 1 days, 7 days);
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(
            1, _doubleUintArray(1e18, 2e18), _doubleUintArray(0.2 ether, 0.02 ether)
        );
        vm.stopPrank();
    }

    function test_BasketDiscovery_ReflectsCreatedBasketsAndConfig() public {
        assertEq(IEdenMetadataFacet(address(diamond)).basketCount(), 2);
        assertEq(IEdenMetadataFacet(address(diamond)).steveBasketId(), 0);

        uint256[] memory basketIds = IEdenMetadataFacet(address(diamond)).getBasketIds(0, 5);
        assertEq(basketIds.length, 2);
        assertEq(basketIds[0], 0);
        assertEq(basketIds[1], 1);

        uint256[] memory page = IEdenMetadataFacet(address(diamond)).getBasketIds(1, 1);
        assertEq(page.length, 1);
        assertEq(page[0], 1);

        uint256[] memory emptyPage = IEdenMetadataFacet(address(diamond)).getBasketIds(3, 2);
        assertEq(emptyPage.length, 0);

        assertTrue(IEdenMetadataFacet(address(diamond)).isStEVEBasket(0));
        assertFalse(IEdenMetadataFacet(address(diamond)).isStEVEBasket(1));
        assertTrue(IEdenMetadataFacet(address(diamond)).isSingleAssetBasket(0));
        assertFalse(IEdenMetadataFacet(address(diamond)).isSingleAssetBasket(1));
        assertFalse(IEdenMetadataFacet(address(diamond)).isBorrowEnabled(0));
        assertTrue(IEdenMetadataFacet(address(diamond)).isBorrowEnabled(1));
        assertTrue(IEdenMetadataFacet(address(diamond)).isFlashEnabled(0));
        assertFalse(IEdenMetadataFacet(address(diamond)).isFlashEnabled(1));
    }

    function test_BasketSummaries_AreCompleteAndConsistent() public {
        IEdenMetadataFacet.BasketSummary memory steveSummary =
            IEdenMetadataFacet(address(diamond)).getBasketSummary(0);
        assertEq(steveSummary.basketId, 0);
        assertEq(steveSummary.token, stEveToken);
        assertFalse(steveSummary.paused);
        assertFalse(steveSummary.lendingEnabled);
        assertTrue(steveSummary.flashEnabled);
        assertEq(steveSummary.flashFeeBps, 30);
        assertEq(steveSummary.assets.length, 1);
        assertEq(steveSummary.assets[0], address(eve));
        assertEq(steveSummary.bundleAmounts[0], 1_000e18);
        assertEq(steveSummary.name, "stEVE");
        assertEq(steveSummary.symbol, "stEVE");
        assertEq(steveSummary.uri, "");
        assertEq(steveSummary.creator, owner);
        assertEq(steveSummary.createdAt, uint64(block.timestamp));
        assertEq(steveSummary.basketType, 1);

        (
            string memory storedName,
            string memory storedSymbol,
            string memory storedUri,
            address storedCreator,
            uint64 storedCreatedAt,
            uint8 storedBasketType
        ) = MetadataHarnessFacet(address(diamond)).getStoredBasketMetadata(0);
        assertEq(storedName, "stEVE");
        assertEq(storedSymbol, "stEVE");
        assertEq(storedUri, "");
        assertEq(storedCreator, owner);
        assertEq(storedCreatedAt, uint64(block.timestamp));
        assertEq(storedBasketType, 1);

        IEdenMetadataFacet.BasketSummary[] memory summaries =
            IEdenMetadataFacet(address(diamond)).getBasketSummaries(_doubleUintArray(0, 1));
        assertEq(summaries.length, 2);
        assertEq(summaries[0].token, stEveToken);
        assertEq(summaries[1].token, basketToken);
        assertTrue(summaries[1].lendingEnabled);
        assertFalse(summaries[1].flashEnabled);
        assertEq(summaries[1].assets.length, 2);
        assertEq(summaries[1].bundleAmounts[0], 100e18);
        assertEq(summaries[1].bundleAmounts[1], 50e18);
        assertEq(summaries[1].name, "Basket");
        assertEq(summaries[1].symbol, "BASK");
        assertEq(summaries[1].basketType, 0);

        assertEq(IEdenMetadataFacet(address(diamond)).basketURI(1), "");
    }

    function test_BasketSummaries_PaginationAndUnknownBasketBehavior() public {
        IEdenMetadataFacet.BasketSummary[] memory summaries =
            IEdenMetadataFacet(address(diamond)).getBasketSummariesPaginated(0, 5);
        assertEq(summaries.length, 2);
        assertEq(summaries[0].basketId, 0);
        assertEq(summaries[1].basketId, 1);

        IEdenMetadataFacet.BasketSummary[] memory paginated =
            IEdenMetadataFacet(address(diamond)).getBasketSummariesPaginated(1, 1);
        assertEq(paginated.length, 1);
        assertEq(paginated[0].basketId, 1);

        IEdenMetadataFacet.BasketSummary[] memory empty =
            IEdenMetadataFacet(address(diamond)).getBasketSummariesPaginated(2, 1);
        assertEq(empty.length, 0);

        vm.expectRevert(abi.encodeWithSelector(EdenMetadataFacet.UnknownBasket.selector, 2));
        IEdenMetadataFacet(address(diamond)).getBasketSummary(2);

        vm.expectRevert(abi.encodeWithSelector(EdenMetadataFacet.UnknownBasket.selector, 2));
        IEdenMetadataFacet(address(diamond)).isFlashEnabled(2);
    }

    function test_ProtocolConfig_AndFrozenFacetViewsReflectStorage() public {
        MetadataHarnessFacet(address(diamond)).setProtocolConfigValues(treasury, 150, 2500, 4200, 1 ether);
        MetadataHarnessFacet(address(diamond)).setFrozenFacetState(address(lendingFacet), true);

        IEdenMetadataFacet.ProtocolConfig memory config =
            IEdenMetadataFacet(address(diamond)).getProtocolConfig();
        assertEq(config.owner, owner);
        assertEq(config.timelock, timelock);
        assertEq(config.timelockDelaySeconds, 7 days);
        assertEq(config.treasury, treasury);
        assertEq(config.treasuryFeeBps, 150);
        assertEq(config.feePotShareBps, 2500);
        assertEq(config.protocolFeeSplitBps, 4200);
        assertEq(config.basketCreationFee, 1 ether);

        IEdenMetadataFacet.BasketFeeConfig memory basketFeeConfig =
            IEdenMetadataFacet(address(diamond)).getBasketFeeConfig(1);
        assertEq(basketFeeConfig.basketId, 1);
        assertEq(basketFeeConfig.mintFeeBps.length, 2);
        assertEq(basketFeeConfig.burnFeeBps.length, 2);
        assertEq(basketFeeConfig.flashFeeBps, 0);

        IEdenMetadataFacet.LendingConfigView memory lendingConfig =
            IEdenMetadataFacet(address(diamond)).getLendingConfig(1);
        assertTrue(lendingConfig.enabled);
        assertEq(lendingConfig.minDuration, 1 days);
        assertEq(lendingConfig.maxDuration, 7 days);
        assertEq(lendingConfig.ltvBps, 10_000);
        assertEq(lendingConfig.tiers.length, 2);
        assertEq(lendingConfig.tiers[0].minCollateralUnits, 1e18);
        assertEq(lendingConfig.tiers[1].flatFeeNative, 0.02 ether);

        LibLendingStorage.BorrowFeeTier[] memory tiers =
            IEdenMetadataFacet(address(diamond)).getBorrowFeeTiers(1);
        assertEq(tiers.length, 2);
        assertEq(tiers[0].flatFeeNative, 0.2 ether);

        address[] memory frozenFacets = IEdenMetadataFacet(address(diamond)).getFrozenFacets();
        assertEq(frozenFacets.length, 1);
        assertEq(frozenFacets[0], address(lendingFacet));
        assertTrue(IEdenMetadataFacet(address(diamond)).facetFrozen(address(lendingFacet)));
        assertFalse(IEdenMetadataFacet(address(diamond)).facetFrozen(address(coreFacet)));
    }

    function test_FeatureFlags_Versioning_AndAdminStateReflectStorage() public {
        vm.warp(2 days);
        MetadataHarnessFacet(address(diamond)).setProtocolConfigValues(treasury, 99, 1111, 2222, 0.5 ether);
        MetadataHarnessFacet(address(diamond)).setVersionMetadata(
            "ipfs://protocol", "1.2.3", address(metadataFacet), "metadata-1.2.3"
        );
        MetadataHarnessFacet(address(diamond)).setRewardState(
            block.timestamp - 1 days, 1 days, 183, 3, 100e18, 10, 500e18, 0, 100e18
        );
        MetadataHarnessFacet(address(diamond)).setFrozenFacetState(address(coreFacet), true);

        IEdenMetadataFacet.FeatureFlags memory flags =
            IEdenMetadataFacet(address(diamond)).featureFlags();
        assertTrue(flags.rewardsEnabled);
        assertTrue(flags.lendingEnabled);
        assertTrue(flags.flashEnabled);
        assertTrue(flags.permissionlessCreationEnabled);

        assertEq(IEdenMetadataFacet(address(diamond)).protocolURI(), "ipfs://protocol");
        assertEq(IEdenMetadataFacet(address(diamond)).contractVersion(), "1.2.3");
        assertEq(
            IEdenMetadataFacet(address(diamond)).facetVersion(address(metadataFacet)),
            "metadata-1.2.3"
        );

        IEdenMetadataFacet.ProtocolState memory adminState =
            IEdenMetadataFacet(address(diamond)).getAdminState();
        assertEq(adminState.config.owner, owner);
        assertEq(adminState.config.treasury, treasury);
        assertEq(adminState.config.basketCreationFee, 0.5 ether);
        assertEq(adminState.rewards.epochDuration, 1 days);
        assertEq(adminState.rewards.totalEpochs, 10);
        assertEq(adminState.rewards.rewardReserve, 500e18);
        assertEq(adminState.basketCount, 2);
        assertEq(adminState.loanCount, 0);
        assertEq(adminState.steveBasketId, 0);
        assertEq(adminState.frozenFacets.length, 1);
        assertEq(adminState.frozenFacets[0], address(coreFacet));
        assertTrue(adminState.featureFlags.rewardsEnabled);
        assertTrue(adminState.featureFlags.lendingEnabled);
        assertTrue(adminState.featureFlags.flashEnabled);
        assertTrue(adminState.featureFlags.permissionlessCreationEnabled);
    }

    function test_FacetRegistry_AndSelectorsReflectDiamondStorage() public {
        MetadataHarnessFacet(address(diamond)).setFrozenFacetState(address(coreFacet), true);
        MetadataHarnessFacet(address(diamond)).setFrozenFacetState(address(metadataFacet), true);

        (address[] memory facets, bool[] memory frozen) =
            IEdenMetadataFacet(address(diamond)).getFacetRegistry();
        assertEq(facets.length, 3);
        assertEq(frozen.length, 3);
        assertEq(facets[0], address(coreFacet));
        assertEq(facets[1], address(lendingFacet));
        assertEq(facets[2], address(metadataFacet));
        assertTrue(frozen[0]);
        assertFalse(frozen[1]);
        assertTrue(frozen[2]);

        bytes4[] memory coreSelectors =
            IEdenMetadataFacet(address(diamond)).getFacetSelectors(address(coreFacet));
        assertEq(coreSelectors.length, 1);
        assertEq(coreSelectors[0], IEdenCoreFacet.createBasket.selector);

        bytes4[] memory lendingSelectors =
            IEdenMetadataFacet(address(diamond)).getFacetSelectors(address(lendingFacet));
        assertEq(lendingSelectors.length, 2);
        assertEq(lendingSelectors[0], IEdenLendingFacet.configureLending.selector);
        assertEq(lendingSelectors[1], IEdenLendingFacet.configureBorrowFeeTiers.selector);

        bytes4[] memory metadataSelectors =
            IEdenMetadataFacet(address(diamond)).getFacetSelectors(address(metadataFacet));
        assertEq(metadataSelectors.length, 29);
        assertEq(metadataSelectors[0], IEdenMetadataFacet.basketCount.selector);
        assertEq(metadataSelectors[28], MetadataHarnessFacet.setRewardState.selector);
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](3);

        bytes4[] memory coreSelectors = new bytes4[](1);
        coreSelectors[0] = IEdenCoreFacet.createBasket.selector;
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(coreFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: coreSelectors
        });

        bytes4[] memory lendingSelectors = new bytes4[](2);
        lendingSelectors[0] = IEdenLendingFacet.configureLending.selector;
        lendingSelectors[1] = IEdenLendingFacet.configureBorrowFeeTiers.selector;
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(lendingFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: lendingSelectors
        });

        bytes4[] memory metadataSelectors = new bytes4[](24);
        metadataSelectors[0] = IEdenMetadataFacet.basketCount.selector;
        metadataSelectors[1] = IEdenMetadataFacet.steveBasketId.selector;
        metadataSelectors[2] = IEdenMetadataFacet.getBasketIds.selector;
        metadataSelectors[3] = IEdenMetadataFacet.isStEVEBasket.selector;
        metadataSelectors[4] = IEdenMetadataFacet.isSingleAssetBasket.selector;
        metadataSelectors[5] = IEdenMetadataFacet.isBorrowEnabled.selector;
        metadataSelectors[6] = IEdenMetadataFacet.isFlashEnabled.selector;
        metadataSelectors[7] = IEdenMetadataFacet.getBasketSummary.selector;
        metadataSelectors[8] = IEdenMetadataFacet.getBasketSummaries.selector;
        metadataSelectors[9] = IEdenMetadataFacet.getBasketSummariesPaginated.selector;
        metadataSelectors[10] = IEdenMetadataFacet.basketURI.selector;
        metadataSelectors[11] = IEdenMetadataFacet.getProtocolConfig.selector;
        metadataSelectors[12] = IEdenMetadataFacet.getBasketFeeConfig.selector;
        metadataSelectors[13] = IEdenMetadataFacet.getLendingConfig.selector;
        metadataSelectors[14] = IEdenMetadataFacet.getBorrowFeeTiers.selector;
        metadataSelectors[15] = IEdenMetadataFacet.getFrozenFacets.selector;
        metadataSelectors[16] = IEdenMetadataFacet.facetFrozen.selector;
        metadataSelectors[17] = IEdenMetadataFacet.featureFlags.selector;
        metadataSelectors[18] = IEdenMetadataFacet.protocolURI.selector;
        metadataSelectors[19] = IEdenMetadataFacet.contractVersion.selector;
        metadataSelectors[20] = IEdenMetadataFacet.facetVersion.selector;
        metadataSelectors[21] = IEdenMetadataFacet.getAdminState.selector;
        metadataSelectors[22] = IEdenMetadataFacet.getFacetRegistry.selector;
        metadataSelectors[23] = IEdenMetadataFacet.getFacetSelectors.selector;
        bytes4[] memory metadataHarnessSelectors = new bytes4[](4);
        metadataHarnessSelectors[0] = MetadataHarnessFacet.getStoredBasketMetadata.selector;
        metadataHarnessSelectors[1] = MetadataHarnessFacet.setProtocolConfigValues.selector;
        metadataHarnessSelectors[2] = MetadataHarnessFacet.setVersionMetadata.selector;
        metadataHarnessSelectors[3] = MetadataHarnessFacet.setFrozenFacetState.selector;

        bytes4[] memory rewardHarnessSelectors = new bytes4[](1);
        rewardHarnessSelectors[0] = MetadataHarnessFacet.setRewardState.selector;

        bytes4[] memory allMetadataSelectors =
            new bytes4[](metadataSelectors.length + metadataHarnessSelectors.length + rewardHarnessSelectors.length);
        for (uint256 i = 0; i < metadataSelectors.length; i++) {
            allMetadataSelectors[i] = metadataSelectors[i];
        }
        for (uint256 i = 0; i < metadataHarnessSelectors.length; i++) {
            allMetadataSelectors[metadataSelectors.length + i] = metadataHarnessSelectors[i];
        }
        allMetadataSelectors[metadataSelectors.length + metadataHarnessSelectors.length] =
            rewardHarnessSelectors[0];
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(metadataFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: allMetadataSelectors
        });
    }

    function _singleAddressArray(
        address a0
    ) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = a0;
    }

    function _doubleAddressArray(
        address a0,
        address a1
    ) internal pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = a0;
        values[1] = a1;
    }

    function _singleUintArray(
        uint256 v0
    ) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = v0;
    }

    function _doubleUintArray(
        uint256 v0,
        uint256 v1
    ) internal pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = v0;
        values[1] = v1;
    }

    function _singleUint16Array(
        uint16 v0
    ) internal pure returns (uint16[] memory values) {
        values = new uint16[](1);
        values[0] = v0;
    }

    function _doubleUint16Array(
        uint16 v0,
        uint16 v1
    ) internal pure returns (uint16[] memory values) {
        values = new uint16[](2);
        values[0] = v0;
        values[1] = v1;
    }
}
