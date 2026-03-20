// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDiamondCut {
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    event DiamondCut(FacetCut[] diamondCut, address init, bytes data);

    function diamondCut(
        FacetCut[] calldata diamondCut,
        address init,
        bytes calldata data
    ) external;
}
