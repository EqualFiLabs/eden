// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { DiamondLoupeFacet } from "src/facets/DiamondLoupeFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "src/interfaces/IDiamondLoupe.sol";

library LibMockFacetStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("eden.test.mockfacet.storage");

    struct Layout {
        uint256 value;
    }

    function layout() internal pure returns (Layout storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }
}

interface IMockStateFacet {
    function setValue(
        uint256 newValue
    ) external;
    function value() external view returns (uint256);
}

interface IVersionFacet {
    function version() external view returns (uint256);
}

contract MockStateFacet {
    function setValue(
        uint256 newValue
    ) external {
        LibMockFacetStorage.layout().value = newValue;
    }

    function value() external view returns (uint256) {
        return LibMockFacetStorage.layout().value;
    }
}

contract MockVersionFacetV1 {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract MockVersionFacetV2 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract DiamondTest is Test {
    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");

    EdenDiamond internal diamond;
    DiamondLoupeFacet internal loupeFacet;
    MockStateFacet internal stateFacet;
    MockVersionFacetV1 internal versionFacetV1;
    MockVersionFacetV2 internal versionFacetV2;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        loupeFacet = new DiamondLoupeFacet();
        stateFacet = new MockStateFacet();
        versionFacetV1 = new MockVersionFacetV1();
        versionFacetV2 = new MockVersionFacetV2();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = _facetCut(address(loupeFacet), IDiamondCut.FacetCutAction.Add, _loupeSelectors());
        cuts[1] = _facetCut(address(stateFacet), IDiamondCut.FacetCutAction.Add, _stateSelectors());
        cuts[2] =
            _facetCut(address(versionFacetV1), IDiamondCut.FacetCutAction.Add, _versionSelectors());

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    function test_SelectorRoutingCorrectness() public {
        IMockStateFacet(address(diamond)).setValue(42);
        assertEq(IMockStateFacet(address(diamond)).value(), 42);
        assertEq(IVersionFacet(address(diamond)).version(), 1);

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _facetCut(
            address(versionFacetV2), IDiamondCut.FacetCutAction.Replace, _versionSelectors()
        );

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        assertEq(IVersionFacet(address(diamond)).version(), 2);

        (bool success,) =
            address(diamond).call(abi.encodeWithSelector(bytes4(keccak256("missing()"))));
        assertFalse(success);
    }

    function test_FacetRegistrationCompleteness() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));

        address[] memory facetAddresses_ = loupe.facetAddresses();
        assertEq(facetAddresses_.length, 3);
        assertEq(facetAddresses_[0], address(loupeFacet));
        assertEq(facetAddresses_[1], address(stateFacet));
        assertEq(facetAddresses_[2], address(versionFacetV1));

        bytes4[] memory selectors = loupe.facetFunctionSelectors(address(stateFacet));
        assertEq(selectors.length, 2);
        assertEq(selectors[0], IMockStateFacet.setValue.selector);
        assertEq(selectors[1], IMockStateFacet.value.selector);

        IDiamondLoupe.Facet[] memory allFacets = loupe.facets();
        assertEq(allFacets.length, 3);
        assertEq(allFacets[1].facetAddress, address(stateFacet));
        assertEq(allFacets[1].functionSelectors.length, 2);
    }

    function test_RemoveUpdatesLoupeAndDeregistersSelector() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _facetCut(address(0), IDiamondCut.FacetCutAction.Remove, _versionSelectors());

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        assertEq(loupe.facetAddress(IVersionFacet.version.selector), address(0));
        assertEq(loupe.facetFunctionSelectors(address(versionFacetV1)).length, 0);
        assertEq(loupe.facetAddresses().length, 2);
    }

    function test_FreezeDisablesDiamondCut() public {
        vm.prank(owner);
        diamond.freezeFacet(address(stateFacet));

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _facetCut(address(0), IDiamondCut.FacetCutAction.Remove, _stateSelectors());

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(EdenDiamond.FacetIsFrozen.selector, address(stateFacet))
        );
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    function test_FreezeIsIrreversible() public {
        vm.prank(owner);
        diamond.freezeFacet(address(versionFacetV1));
        assertTrue(diamond.isFacetFrozen(address(versionFacetV1)));

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _facetCut(
            address(versionFacetV2), IDiamondCut.FacetCutAction.Replace, _versionSelectors()
        );

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(EdenDiamond.FacetIsFrozen.selector, address(versionFacetV1))
        );
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        assertTrue(diamond.isFacetFrozen(address(versionFacetV1)));
    }

    function _facetCut(
        address facetAddress,
        IDiamondCut.FacetCutAction action,
        bytes4[] memory selectors
    ) internal pure returns (IDiamondCut.FacetCut memory cut) {
        cut.facetAddress = facetAddress;
        cut.action = action;
        cut.functionSelectors = selectors;
    }

    function _loupeSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
    }

    function _stateSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IMockStateFacet.setValue.selector;
        selectors[1] = IMockStateFacet.value.selector;
    }

    function _versionSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IVersionFacet.version.selector;
    }
}
