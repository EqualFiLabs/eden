// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEdenMetadataFacet } from "src/interfaces/IEdenMetadataFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";

contract EdenMetadataFacet {
    error UnknownBasket(uint256 basketId);

    function basketCount() external view returns (uint256) {
        return LibEdenStorage.layout().basketCount;
    }

    function steveBasketId() external view returns (uint256) {
        return LibEdenStorage.layout().steveBasketId;
    }

    function getBasketIds(
        uint256 start,
        uint256 limit
    ) external view returns (uint256[] memory basketIds) {
        uint256 count = LibEdenStorage.layout().basketCount;
        if (start >= count || limit == 0) {
            return new uint256[](0);
        }

        uint256 remaining = count - start;
        uint256 resultLen = remaining < limit ? remaining : limit;
        basketIds = new uint256[](resultLen);
        for (uint256 i = 0; i < resultLen; i++) {
            basketIds[i] = start + i;
        }
    }

    function isStEVEBasket(
        uint256 basketId
    ) external view returns (bool) {
        _requireBasketExists(basketId);
        return basketId == LibEdenStorage.layout().steveBasketId;
    }

    function isSingleAssetBasket(
        uint256 basketId
    ) external view returns (bool) {
        return _basket(basketId).assets.length == 1;
    }

    function isBorrowEnabled(
        uint256 basketId
    ) public view returns (bool) {
        _requireBasketExists(basketId);
        return LibLendingStorage.layout().lendingConfigs[basketId].maxDuration > 0;
    }

    function isFlashEnabled(
        uint256 basketId
    ) public view returns (bool) {
        return _basket(basketId).flashFeeBps > 0;
    }

    function getBasketSummary(
        uint256 basketId
    ) public view returns (IEdenMetadataFacet.BasketSummary memory summary) {
        LibEdenStorage.Basket storage basket = _basket(basketId);
        LibEdenStorage.BasketMetadata storage metadata = LibEdenStorage.layout().basketMetadata[basketId];

        summary.basketId = basketId;
        summary.token = basket.token;
        summary.paused = basket.paused;
        summary.lendingEnabled = isBorrowEnabled(basketId);
        summary.flashEnabled = basket.flashFeeBps > 0;
        summary.totalUnits = basket.totalUnits;
        summary.flashFeeBps = basket.flashFeeBps;
        summary.assets = basket.assets;
        summary.bundleAmounts = basket.bundleAmounts;
        summary.name = metadata.name;
        summary.symbol = metadata.symbol;
        summary.uri = metadata.uri;
        summary.creator = metadata.creator;
        summary.createdAt = metadata.createdAt;
        summary.basketType = metadata.basketType;
    }

    function getBasketSummaries(
        uint256[] calldata basketIds
    ) external view returns (IEdenMetadataFacet.BasketSummary[] memory summaries) {
        uint256 len = basketIds.length;
        summaries = new IEdenMetadataFacet.BasketSummary[](len);
        for (uint256 i = 0; i < len; i++) {
            summaries[i] = getBasketSummary(basketIds[i]);
        }
    }

    function getBasketSummariesPaginated(
        uint256 start,
        uint256 limit
    ) external view returns (IEdenMetadataFacet.BasketSummary[] memory summaries) {
        uint256 count = LibEdenStorage.layout().basketCount;
        if (start >= count || limit == 0) {
            return new IEdenMetadataFacet.BasketSummary[](0);
        }

        uint256 remaining = count - start;
        uint256 resultLen = remaining < limit ? remaining : limit;
        summaries = new IEdenMetadataFacet.BasketSummary[](resultLen);
        for (uint256 i = 0; i < resultLen; i++) {
            summaries[i] = getBasketSummary(start + i);
        }
    }

    function basketURI(
        uint256 basketId
    ) external view returns (string memory) {
        _requireBasketExists(basketId);
        return LibEdenStorage.layout().basketMetadata[basketId].uri;
    }

    function _basket(
        uint256 basketId
    ) internal view returns (LibEdenStorage.Basket storage basket) {
        _requireBasketExists(basketId);
        return LibEdenStorage.layout().baskets[basketId];
    }

    function _requireBasketExists(
        uint256 basketId
    ) internal view {
        if (basketId >= LibEdenStorage.layout().basketCount) revert UnknownBasket(basketId);
    }
}
