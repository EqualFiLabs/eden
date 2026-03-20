// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEdenTwabHook {
    function onStEVETransfer(
        address from,
        address to,
        uint256 value
    ) external;
}
