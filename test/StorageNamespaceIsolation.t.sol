// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibStEVEStorage } from "src/libraries/LibStEVEStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";

contract StorageSlotHarness {
    function coreSlot() external pure returns (bytes32) {
        return LibEdenStorage.storagePosition();
    }

    function steveSlot() external pure returns (bytes32) {
        return LibStEVEStorage.storagePosition();
    }

    function lendingSlot() external pure returns (bytes32) {
        return LibLendingStorage.storagePosition();
    }
}

contract StorageNamespaceIsolationTest is Test {
    StorageSlotHarness internal harness;

    function setUp() external {
        harness = new StorageSlotHarness();
    }

    function test_storageNamespaceIsolation_hashesMatchSpec() external view {
        assertEq(harness.coreSlot(), keccak256("eden.core.storage"));
        assertEq(harness.steveSlot(), keccak256("eden.steve.storage"));
        assertEq(harness.lendingSlot(), keccak256("eden.lending.storage"));
    }

    function test_storageNamespaceIsolation_slotsAreUnique() external view {
        bytes32 core = harness.coreSlot();
        bytes32 steve = harness.steveSlot();
        bytes32 lending = harness.lendingSlot();

        assertTrue(core != steve, "core and steve storage slots must differ");
        assertTrue(core != lending, "core and lending storage slots must differ");
        assertTrue(steve != lending, "steve and lending storage slots must differ");
    }
}
