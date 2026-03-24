// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEdenBasketPositionHook {
    function onBasketTokenTransfer(
        address from,
        address to,
        uint256 value
    ) external;
}
