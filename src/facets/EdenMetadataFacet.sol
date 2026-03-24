// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { IEdenMetadataFacet } from "src/interfaces/IEdenMetadataFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { LibStEVEStorage } from "src/libraries/LibStEVEStorage.sol";

contract EdenMetadataFacet is IEdenMetadataFacet {
    uint256 internal constant TIMELOCK_DELAY_SECONDS = 7 days;

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

    function getProtocolConfig() public view returns (ProtocolConfig memory config) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        config = ProtocolConfig({
            owner: store.owner,
            timelock: store.timelock,
            timelockDelaySeconds: TIMELOCK_DELAY_SECONDS,
            treasury: store.treasury,
            treasuryFeeBps: store.treasuryFeeBps,
            feePotShareBps: store.feePotShareBps,
            protocolFeeSplitBps: store.protocolFeeSplitBps,
            basketCreationFee: store.basketCreationFee
        });
    }

    function getBasketFeeConfig(
        uint256 basketId
    ) external view returns (BasketFeeConfig memory config) {
        LibEdenStorage.Basket storage basket = _basket(basketId);
        config.basketId = basketId;
        config.mintFeeBps = basket.mintFeeBps;
        config.burnFeeBps = basket.burnFeeBps;
        config.flashFeeBps = basket.flashFeeBps;
    }

    function getLendingConfig(
        uint256 basketId
    ) public view returns (LendingConfigView memory config) {
        _requireBasketExists(basketId);
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        LibLendingStorage.LendingConfig storage lendingConfig = lending.lendingConfigs[basketId];

        config.basketId = basketId;
        config.enabled = lendingConfig.maxDuration > 0;
        config.minDuration = lendingConfig.minDuration;
        config.maxDuration = lendingConfig.maxDuration;
        config.ltvBps = LibLendingStorage.DEFAULT_LTV_BPS;
        config.tiers = _borrowFeeTiers(basketId);
    }

    function getBorrowFeeTiers(
        uint256 basketId
    ) external view returns (LibLendingStorage.BorrowFeeTier[] memory) {
        _requireBasketExists(basketId);
        return _borrowFeeTiers(basketId);
    }

    function getFrozenFacets() public view returns (address[] memory frozenFacets_) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 len = store.facetAddresses.length;
        uint256 frozenCount;
        for (uint256 i = 0; i < len; i++) {
            if (store.frozenFacets[store.facetAddresses[i]]) {
                frozenCount++;
            }
        }

        frozenFacets_ = new address[](frozenCount);
        uint256 index;
        for (uint256 i = 0; i < len; i++) {
            address facet = store.facetAddresses[i];
            if (store.frozenFacets[facet]) {
                frozenFacets_[index++] = facet;
            }
        }
    }

    function facetFrozen(
        address facet
    ) external view returns (bool) {
        return LibEdenStorage.layout().frozenFacets[facet];
    }

    function featureFlags() public view returns (FeatureFlags memory flags) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        uint256 count = store.basketCount;

        flags.rewardsEnabled = st.totalEpochs > 0 && st.epochDuration > 0;
        flags.permissionlessCreationEnabled = store.basketCreationFee > 0;

        for (uint256 basketId = 0; basketId < count; basketId++) {
            if (!flags.lendingEnabled && LibLendingStorage.layout().lendingConfigs[basketId].maxDuration > 0) {
                flags.lendingEnabled = true;
            }
            if (!flags.flashEnabled && store.baskets[basketId].flashFeeBps > 0) {
                flags.flashEnabled = true;
            }

            if (flags.lendingEnabled && flags.flashEnabled) {
                break;
            }
        }
    }

    function protocolURI() external view returns (string memory) {
        return LibEdenStorage.layout().protocolURI;
    }

    function contractVersion() external view returns (string memory) {
        return LibEdenStorage.layout().contractVersion;
    }

    function facetVersion(
        address facet
    ) external view returns (string memory) {
        return LibEdenStorage.layout().facetVersions[facet];
    }

    function getAdminState() external view returns (ProtocolState memory state) {
        state.config = getProtocolConfig();
        state.rewards = _rewardConfig();
        state.basketCount = LibEdenStorage.layout().basketCount;
        state.loanCount = LibLendingStorage.layout().nextLoanId;
        state.steveBasketId = LibEdenStorage.layout().steveBasketId;
        state.frozenFacets = getFrozenFacets();
        state.featureFlags = featureFlags();
    }

    function getFacetRegistry() external view returns (address[] memory facets, bool[] memory frozen) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 len = store.facetAddresses.length;
        facets = new address[](len);
        frozen = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            address facet = store.facetAddresses[i];
            facets[i] = facet;
            frozen[i] = store.frozenFacets[facet];
        }
    }

    function getFacetSelectors(
        address facet
    ) external view returns (bytes4[] memory selectors) {
        return LibEdenStorage.layout().facetFunctionSelectors[facet].functionSelectors;
    }

    function _basket(
        uint256 basketId
    ) internal view returns (LibEdenStorage.Basket storage basket) {
        _requireBasketExists(basketId);
        return LibEdenStorage.layout().baskets[basketId];
    }

    function _borrowFeeTiers(
        uint256 basketId
    ) internal view returns (LibLendingStorage.BorrowFeeTier[] memory tiers) {
        LibLendingStorage.BorrowFeeTier[] storage storedTiers =
            LibLendingStorage.layout().borrowFeeTiers[basketId];
        uint256 len = storedTiers.length;
        tiers = new LibLendingStorage.BorrowFeeTier[](len);
        for (uint256 i = 0; i < len; i++) {
            tiers[i] = storedTiers[i];
        }
    }

    function _rewardConfig() internal view returns (IEdenStEVEFacet.RewardConfig memory config) {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        config = IEdenStEVEFacet.RewardConfig({
            genesisTimestamp: st.genesisTimestamp,
            epochDuration: st.epochDuration,
            halvingInterval: st.halvingInterval,
            maxPeriods: st.maxPeriods,
            baseRewardPerEpoch: st.baseRewardPerEpoch,
            totalEpochs: st.totalEpochs,
            rewardReserve: st.rewardReserve,
            rewardPerEpochOverride: st.rewardPerEpochOverride,
            maxRewardPerEpochOverride: st.maxRewardPerEpochOverride
        });
    }

    function _requireBasketExists(
        uint256 basketId
    ) internal view {
        if (basketId >= LibEdenStorage.layout().basketCount) revert UnknownBasket(basketId);
    }
}
