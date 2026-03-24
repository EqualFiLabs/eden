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
}

contract MetadataFacetTest is Test {
    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");

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

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](3);

        bytes4[] memory coreSelectors = new bytes4[](1);
        coreSelectors[0] = IEdenCoreFacet.createBasket.selector;
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(coreFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: coreSelectors
        });

        bytes4[] memory lendingSelectors = new bytes4[](1);
        lendingSelectors[0] = IEdenLendingFacet.configureLending.selector;
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(lendingFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: lendingSelectors
        });

        bytes4[] memory metadataSelectors = new bytes4[](12);
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
        metadataSelectors[11] = MetadataHarnessFacet.getStoredBasketMetadata.selector;
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(metadataFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: metadataSelectors
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
