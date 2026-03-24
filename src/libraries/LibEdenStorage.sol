// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library LibEdenStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("eden.core.storage");
    uint256 internal constant REENTRANCY_NOT_ENTERED = 1;
    uint256 internal constant REENTRANCY_ENTERED = 2;

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition;
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition;
    }

    struct Basket {
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
        uint256 totalUnits;
        address token;
        bool paused;
    }

    struct BasketMetadata {
        string name;
        string symbol;
        string uri;
        address creator;
        uint64 createdAt;
        uint8 basketType;
    }

    struct EdenStorage {
        uint256 basketCount;
        uint256 steveBasketId;
        address owner;
        address timelock;
        address treasury;
        uint16 treasuryFeeBps;
        uint16 feePotShareBps;
        uint16 protocolFeeSplitBps;
        uint256 basketCreationFee;
        mapping(uint256 => Basket) baskets;
        mapping(uint256 => mapping(address => uint256)) vaultBalances;
        mapping(uint256 => mapping(address => uint256)) feePots;
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        address[] facetAddresses;
        mapping(address => bool) frozenFacets;
        uint256 reentrancyStatus;
        mapping(uint256 => BasketMetadata) basketMetadata;
        string protocolURI;
        string contractVersion;
        mapping(address => string) facetVersions;
    }

    function layout() internal pure returns (EdenStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function storagePosition() internal pure returns (bytes32 position) {
        return STORAGE_POSITION;
    }
}
