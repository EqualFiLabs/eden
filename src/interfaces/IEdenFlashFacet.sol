// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IEdenEvents } from "./IEdenEvents.sol";

interface IEdenFlashFacet is IEdenEvents {
    function flashLoan(
        uint256 basketId,
        uint256 units,
        address receiver,
        bytes calldata data
    ) external;
}
