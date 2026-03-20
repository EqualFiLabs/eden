// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEdenFlashReceiver {
    function onEdenFlashLoan(
        uint256 basketId,
        uint256 units,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata data
    ) external;
}
