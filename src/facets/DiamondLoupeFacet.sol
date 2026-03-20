// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IDiamondLoupe } from "src/interfaces/IDiamondLoupe.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";

contract DiamondLoupeFacet is IDiamondLoupe {
    function facets() external view returns (Facet[] memory facets_) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 facetCount = store.facetAddresses.length;
        facets_ = new Facet[](facetCount);

        for (uint256 i = 0; i < facetCount; i++) {
            address facetAddress_ = store.facetAddresses[i];
            facets_[i].facetAddress = facetAddress_;
            facets_[i].functionSelectors =
            store.facetFunctionSelectors[facetAddress_].functionSelectors;
        }
    }

    function facetFunctionSelectors(
        address facet
    ) external view returns (bytes4[] memory selectors_) {
        selectors_ = LibEdenStorage.layout().facetFunctionSelectors[facet].functionSelectors;
    }

    function facetAddresses() external view returns (address[] memory facetAddresses_) {
        facetAddresses_ = LibEdenStorage.layout().facetAddresses;
    }

    function facetAddress(
        bytes4 selector
    ) external view returns (address facetAddress_) {
        facetAddress_ = LibEdenStorage.layout().selectorToFacetAndPosition[selector].facetAddress;
    }
}
