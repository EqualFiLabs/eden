// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";

abstract contract EdenReentrancyGuard {
    error Reentrancy();

    modifier nonReentrant() {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        if (store.reentrancyStatus == LibEdenStorage.REENTRANCY_ENTERED) revert Reentrancy();
        store.reentrancyStatus = LibEdenStorage.REENTRANCY_ENTERED;
        _;
        store.reentrancyStatus = LibEdenStorage.REENTRANCY_NOT_ENTERED;
    }
}
