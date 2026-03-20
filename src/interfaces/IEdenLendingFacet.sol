// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IEdenEvents } from "./IEdenEvents.sol";

interface IEdenLendingFacet is IEdenEvents {
    function borrow(
        uint256 basketId,
        uint256 collateralUnits,
        uint40 duration
    ) external payable returns (uint256 loanId);

    function repay(
        uint256 loanId
    ) external;
    function extend(
        uint256 loanId,
        uint40 addedDuration
    ) external payable;
    function recoverExpired(
        uint256 loanId
    ) external;
    function configureLending(
        uint256 basketId,
        uint40 minDuration,
        uint40 maxDuration
    ) external;

    function configureBorrowFeeTiers(
        uint256 basketId,
        uint256[] calldata minCollateralUnits,
        uint256[] calldata flatFeeNative
    ) external;
}
