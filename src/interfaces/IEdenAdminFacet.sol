// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IEdenEvents } from "./IEdenEvents.sol";

interface IEdenAdminFacet is IEdenEvents {
    function completeBootstrap() external;

    function setBasketMetadata(
        uint256 basketId,
        string calldata uri,
        uint8 basketType
    ) external;
    function setProtocolURI(
        string calldata uri
    ) external;
    function setContractVersion(
        string calldata version
    ) external;
    function setFacetVersion(
        address facet,
        string calldata version
    ) external;

    function setIndexFees(
        uint256 basketId,
        uint16[] calldata mintFeeBps,
        uint16[] calldata burnFeeBps,
        uint16 flashFeeBps
    ) external;

    function setTreasuryFeeBps(
        uint16 bps
    ) external;
    function setFeePotShareBps(
        uint16 bps
    ) external;
    function setProtocolFeeSplitBps(
        uint16 bps
    ) external;
    function setBasketCreationFee(
        uint256 fee
    ) external;
    function setPaused(
        uint256 basketId,
        bool paused
    ) external;
    function setTreasury(
        address treasury
    ) external;
    function setTimelock(
        address timelock
    ) external;
    function freezeFacet(
        address facetAddress
    ) external;
}
