// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IEdenStEVEFacet } from "./IEdenStEVEFacet.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";

interface IEdenMetadataFacet {
    struct BasketSummary {
        uint256 basketId;
        address token;
        bool paused;
        bool lendingEnabled;
        bool flashEnabled;
        uint256 totalUnits;
        uint16 flashFeeBps;
        address[] assets;
        uint256[] bundleAmounts;
        string name;
        string symbol;
        string uri;
        address creator;
        uint64 createdAt;
        uint8 basketType;
    }

    struct ProtocolConfig {
        address owner;
        address timelock;
        uint256 timelockDelaySeconds;
        address treasury;
        uint16 treasuryFeeBps;
        uint16 feePotShareBps;
        uint16 protocolFeeSplitBps;
        uint256 basketCreationFee;
    }

    struct BasketFeeConfig {
        uint256 basketId;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
    }

    struct LendingConfigView {
        uint256 basketId;
        bool enabled;
        uint40 minDuration;
        uint40 maxDuration;
        uint16 ltvBps;
        LibLendingStorage.BorrowFeeTier[] tiers;
    }

    struct FeatureFlags {
        bool rewardsEnabled;
        bool lendingEnabled;
        bool flashEnabled;
        bool permissionlessCreationEnabled;
    }

    struct ProtocolState {
        ProtocolConfig config;
        IEdenStEVEFacet.RewardConfig rewards;
        uint256 basketCount;
        uint256 loanCount;
        uint256 steveBasketId;
        address[] frozenFacets;
        FeatureFlags featureFlags;
    }

    function basketCount() external view returns (uint256);
    function steveBasketId() external view returns (uint256);
    function getBasketIds(uint256 start, uint256 limit) external view returns (uint256[] memory);
    function isStEVEBasket(uint256 basketId) external view returns (bool);
    function isSingleAssetBasket(uint256 basketId) external view returns (bool);
    function isBorrowEnabled(uint256 basketId) external view returns (bool);
    function isFlashEnabled(uint256 basketId) external view returns (bool);

    function getBasketSummary(
        uint256 basketId
    ) external view returns (BasketSummary memory);
    function getBasketSummaries(
        uint256[] calldata basketIds
    ) external view returns (BasketSummary[] memory);
    function getBasketSummariesPaginated(
        uint256 start,
        uint256 limit
    ) external view returns (BasketSummary[] memory);
    function basketURI(
        uint256 basketId
    ) external view returns (string memory);

    function getProtocolConfig() external view returns (ProtocolConfig memory);
    function getBasketFeeConfig(
        uint256 basketId
    ) external view returns (BasketFeeConfig memory);
    function getLendingConfig(
        uint256 basketId
    ) external view returns (LendingConfigView memory);
    function getBorrowFeeTiers(
        uint256 basketId
    ) external view returns (LibLendingStorage.BorrowFeeTier[] memory);
    function getFrozenFacets() external view returns (address[] memory);
    function facetFrozen(
        address facet
    ) external view returns (bool);

    function featureFlags() external view returns (FeatureFlags memory);
    function protocolURI() external view returns (string memory);
    function contractVersion() external view returns (string memory);
    function facetVersion(
        address facet
    ) external view returns (string memory);

    function getAdminState() external view returns (ProtocolState memory);
    function getFacetRegistry() external view returns (address[] memory facets, bool[] memory frozen);
    function getFacetSelectors(
        address facet
    ) external view returns (bytes4[] memory);
}
