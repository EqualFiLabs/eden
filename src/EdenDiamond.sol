// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenEvents } from "src/interfaces/IEdenEvents.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";

contract EdenDiamond is IDiamondCut, IEdenEvents {
    error Unauthorized();
    error ZeroAddress();
    error NoSelectorsProvided();
    error InvalidFacetAddress(address facetAddress);
    error SelectorAlreadyExists(bytes4 selector);
    error SelectorDoesNotExist(bytes4 selector);
    error SelectorIsImmutable(bytes4 selector);
    error ReplaceWithSameFacet(address facetAddress);
    error FacetIsFrozen(address facetAddress);
    error InvalidInitialization();
    error InitializationFailed(bytes revertData);
    error FunctionNotFound(bytes4 selector);

    constructor(
        address owner_,
        address timelock_
    ) {
        if (owner_ == address(0)) revert ZeroAddress();

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        store.owner = owner_;
        store.timelock = timelock_;
        store.reentrancyStatus = LibEdenStorage.REENTRANCY_NOT_ENTERED;
    }

    modifier onlyOwnerOrTimelock() {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        if (msg.sender != store.owner && msg.sender != store.timelock) {
            revert Unauthorized();
        }
        _;
    }

    receive() external payable { }

    fallback() external payable {
        address facet = LibEdenStorage.layout().selectorToFacetAndPosition[msg.sig].facetAddress;
        if (facet == address(0)) revert FunctionNotFound(msg.sig);

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function diamondCut(
        FacetCut[] calldata diamondCut_,
        address init,
        bytes calldata data
    ) external onlyOwnerOrTimelock {
        uint256 len = diamondCut_.length;
        for (uint256 i = 0; i < len; i++) {
            FacetCutAction action = diamondCut_[i].action;
            if (action == FacetCutAction.Add) {
                _enforceFacetNotFrozen(diamondCut_[i].facetAddress);
                _requireHasCode(diamondCut_[i].facetAddress);
                _addFunctions(diamondCut_[i].facetAddress, diamondCut_[i].functionSelectors);
            } else if (action == FacetCutAction.Replace) {
                _enforceFacetNotFrozen(diamondCut_[i].facetAddress);
                _requireHasCode(diamondCut_[i].facetAddress);
                _replaceFunctions(diamondCut_[i].facetAddress, diamondCut_[i].functionSelectors);
            } else {
                if (diamondCut_[i].facetAddress != address(0)) {
                    revert InvalidFacetAddress(diamondCut_[i].facetAddress);
                }
                _removeFunctions(diamondCut_[i].functionSelectors);
            }
        }

        emit DiamondCut(diamondCut_, init, data);
        _initializeDiamondCut(init, data);
    }

    function freezeFacet(
        address facetAddress
    ) external onlyOwnerOrTimelock {
        if (facetAddress == address(0)) revert ZeroAddress();

        LibEdenStorage.layout().frozenFacets[facetAddress] = true;
        emit FacetFrozen(facetAddress);
    }

    function isFacetFrozen(
        address facetAddress
    ) external view returns (bool) {
        return LibEdenStorage.layout().frozenFacets[facetAddress];
    }

    function owner() external view returns (address) {
        return LibEdenStorage.layout().owner;
    }

    function timelock() external view returns (address) {
        return LibEdenStorage.layout().timelock;
    }

    function _addFunctions(
        address facetAddress,
        bytes4[] calldata selectors
    ) internal {
        uint256 selectorCount = selectors.length;
        if (selectorCount == 0) revert NoSelectorsProvided();

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibEdenStorage.FacetFunctionSelectors storage facetSelectors =
            store.facetFunctionSelectors[facetAddress];

        if (facetSelectors.functionSelectors.length == 0) {
            facetSelectors.facetAddressPosition = store.facetAddresses.length;
            store.facetAddresses.push(facetAddress);
        }

        for (uint256 i = 0; i < selectorCount; i++) {
            bytes4 selector = selectors[i];
            if (store.selectorToFacetAndPosition[selector].facetAddress != address(0)) {
                revert SelectorAlreadyExists(selector);
            }

            facetSelectors.functionSelectors.push(selector);
            store.selectorToFacetAndPosition[selector] = LibEdenStorage.FacetAddressAndPosition({
                facetAddress: facetAddress,
                functionSelectorPosition: uint96(facetSelectors.functionSelectors.length - 1)
            });
        }
    }

    function _replaceFunctions(
        address facetAddress,
        bytes4[] calldata selectors
    ) internal {
        uint256 selectorCount = selectors.length;
        if (selectorCount == 0) revert NoSelectorsProvided();

        for (uint256 i = 0; i < selectorCount; i++) {
            bytes4 selector = selectors[i];
            address oldFacetAddress =
                LibEdenStorage.layout().selectorToFacetAndPosition[selector].facetAddress;

            if (oldFacetAddress == address(0)) revert SelectorDoesNotExist(selector);
            if (oldFacetAddress == facetAddress) revert ReplaceWithSameFacet(facetAddress);

            _enforceFacetNotFrozen(oldFacetAddress);
            _removeFunction(oldFacetAddress, selector);
            _addSingleFunction(facetAddress, selector);
        }
    }

    function _removeFunctions(
        bytes4[] calldata selectors
    ) internal {
        uint256 selectorCount = selectors.length;
        if (selectorCount == 0) revert NoSelectorsProvided();

        for (uint256 i = 0; i < selectorCount; i++) {
            bytes4 selector = selectors[i];
            address oldFacetAddress =
                LibEdenStorage.layout().selectorToFacetAndPosition[selector].facetAddress;

            if (oldFacetAddress == address(0)) revert SelectorDoesNotExist(selector);
            _enforceFacetNotFrozen(oldFacetAddress);
            _removeFunction(oldFacetAddress, selector);
        }
    }

    function _addSingleFunction(
        address facetAddress,
        bytes4 selector
    ) internal {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibEdenStorage.FacetFunctionSelectors storage facetSelectors =
            store.facetFunctionSelectors[facetAddress];

        if (facetSelectors.functionSelectors.length == 0) {
            facetSelectors.facetAddressPosition = store.facetAddresses.length;
            store.facetAddresses.push(facetAddress);
        }

        facetSelectors.functionSelectors.push(selector);
        store.selectorToFacetAndPosition[selector] = LibEdenStorage.FacetAddressAndPosition({
            facetAddress: facetAddress,
            functionSelectorPosition: uint96(facetSelectors.functionSelectors.length - 1)
        });
    }

    function _removeFunction(
        address facetAddress,
        bytes4 selector
    ) internal {
        if (facetAddress == address(this)) revert SelectorIsImmutable(selector);

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibEdenStorage.FacetFunctionSelectors storage facetSelectors =
            store.facetFunctionSelectors[facetAddress];
        uint256 selectorPosition =
            store.selectorToFacetAndPosition[selector].functionSelectorPosition;
        uint256 lastSelectorPosition = facetSelectors.functionSelectors.length - 1;

        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = facetSelectors.functionSelectors[lastSelectorPosition];
            facetSelectors.functionSelectors[selectorPosition] = lastSelector;
            store.selectorToFacetAndPosition[lastSelector].functionSelectorPosition =
                uint96(selectorPosition);
        }

        facetSelectors.functionSelectors.pop();
        delete store.selectorToFacetAndPosition[selector];

        if (facetSelectors.functionSelectors.length == 0) {
            uint256 oldFacetAddressPosition = facetSelectors.facetAddressPosition;
            uint256 lastFacetAddressPosition = store.facetAddresses.length - 1;

            if (oldFacetAddressPosition != lastFacetAddressPosition) {
                address lastFacetAddress = store.facetAddresses[lastFacetAddressPosition];
                store.facetAddresses[oldFacetAddressPosition] = lastFacetAddress;
                store.facetFunctionSelectors[lastFacetAddress].facetAddressPosition =
                oldFacetAddressPosition;
            }

            store.facetAddresses.pop();
            delete store.facetFunctionSelectors[facetAddress].facetAddressPosition;
        }
    }

    function _initializeDiamondCut(
        address init,
        bytes calldata data
    ) internal {
        if (init == address(0)) {
            if (data.length != 0) revert InvalidInitialization();
            return;
        }

        if (data.length == 0) revert InvalidInitialization();
        _requireHasCode(init);

        (bool success, bytes memory revertData) = init.delegatecall(data);
        if (!success) revert InitializationFailed(revertData);
    }

    function _enforceFacetNotFrozen(
        address facetAddress
    ) internal view {
        if (LibEdenStorage.layout().frozenFacets[facetAddress]) {
            revert FacetIsFrozen(facetAddress);
        }
    }

    function _requireHasCode(
        address account
    ) internal view {
        if (account == address(0) || account.code.length == 0) {
            revert InvalidFacetAddress(account);
        }
    }
}
