// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEdenAdminFacet } from "src/interfaces/IEdenAdminFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";

contract EdenAdminFacet is IEdenAdminFacet {
    error Unauthorized();
    error UnknownBasket(uint256 basketId);
    error InvalidArrayLength();
    error FeeCapExceeded();

    modifier onlyOwnerOrTimelock() {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        if (msg.sender != store.owner && msg.sender != store.timelock) revert Unauthorized();
        _;
    }

    modifier onlyTimelock() {
        if (msg.sender != LibEdenStorage.layout().timelock) revert Unauthorized();
        _;
    }

    modifier basketExists(
        uint256 basketId
    ) {
        if (basketId >= LibEdenStorage.layout().basketCount) revert UnknownBasket(basketId);
        _;
    }

    function setIndexFees(
        uint256 basketId,
        uint16[] calldata mintFeeBps,
        uint16[] calldata burnFeeBps,
        uint16 flashFeeBps
    ) external onlyOwnerOrTimelock basketExists(basketId) {
        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        uint256 len = basket.assets.length;
        if (mintFeeBps.length != len || burnFeeBps.length != len) revert InvalidArrayLength();
        if (flashFeeBps > 1000) revert FeeCapExceeded();

        for (uint256 i = 0; i < len; i++) {
            if (mintFeeBps[i] > 1000 || burnFeeBps[i] > 1000) revert FeeCapExceeded();
        }

        basket.mintFeeBps = mintFeeBps;
        basket.burnFeeBps = burnFeeBps;
        basket.flashFeeBps = flashFeeBps;
    }

    function setBasketMetadata(
        uint256 basketId,
        string calldata uri,
        uint8 basketType
    ) external onlyTimelock basketExists(basketId) {
        LibEdenStorage.BasketMetadata storage metadata =
            LibEdenStorage.layout().basketMetadata[basketId];
        metadata.uri = uri;
        metadata.basketType = basketType;
    }

    function setProtocolURI(
        string calldata uri
    ) external onlyTimelock {
        LibEdenStorage.layout().protocolURI = uri;
    }

    function setContractVersion(
        string calldata version
    ) external onlyTimelock {
        LibEdenStorage.layout().contractVersion = version;
    }

    function setFacetVersion(
        address facet,
        string calldata version
    ) external onlyTimelock {
        LibEdenStorage.layout().facetVersions[facet] = version;
    }

    function setTreasuryFeeBps(
        uint16 bps
    ) external onlyOwnerOrTimelock {
        if (bps > 5000) revert FeeCapExceeded();
        LibEdenStorage.layout().treasuryFeeBps = bps;
    }

    function setFeePotShareBps(
        uint16 bps
    ) external onlyOwnerOrTimelock {
        if (bps > 10_000) revert FeeCapExceeded();
        LibEdenStorage.layout().feePotShareBps = bps;
    }

    function setProtocolFeeSplitBps(
        uint16 bps
    ) external onlyOwnerOrTimelock {
        if (bps > 10_000) revert FeeCapExceeded();

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint16 oldBps = store.protocolFeeSplitBps;
        store.protocolFeeSplitBps = bps;
        emit ProtocolFeeSplitUpdated(oldBps, bps);
    }

    function setBasketCreationFee(
        uint256 fee
    ) external onlyOwnerOrTimelock {
        LibEdenStorage.layout().basketCreationFee = fee;
    }

    function setPaused(
        uint256 basketId,
        bool paused
    ) external onlyOwnerOrTimelock basketExists(basketId) {
        LibEdenStorage.layout().baskets[basketId].paused = paused;
    }

    function setTreasury(
        address treasury
    ) external onlyOwnerOrTimelock {
        LibEdenStorage.layout().treasury = treasury;
    }

    function setTimelock(
        address timelock
    ) external onlyOwnerOrTimelock {
        LibEdenStorage.layout().timelock = timelock;
    }

    function freezeFacet(
        address facetAddress
    ) external onlyOwnerOrTimelock {
        LibEdenStorage.layout().frozenFacets[facetAddress] = true;
        emit FacetFrozen(facetAddress);
    }
}
