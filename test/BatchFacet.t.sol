// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenBatchFacet } from "src/facets/EdenBatchFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenBatchFacet } from "src/interfaces/IEdenBatchFacet.sol";

library LibBatchHarnessStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("eden.test.batch.harness.storage");

    struct Layout {
        uint256 counter;
        address lastSender;
    }

    function layout() internal pure returns (Layout storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }
}

contract BatchHarnessFacet is EdenBatchFacet {
    function recordSender() external returns (address sender) {
        sender = msg.sender;
        LibBatchHarnessStorage.layout().lastSender = sender;
    }

    function incrementCounter(
        uint256 amount
    ) external returns (uint256 newCounter) {
        LibBatchHarnessStorage.Layout storage store = LibBatchHarnessStorage.layout();
        store.counter += amount;
        return store.counter;
    }

    function failWithReason() external pure {
        revert("batch failure");
    }

    function getCounter() external view returns (uint256) {
        return LibBatchHarnessStorage.layout().counter;
    }

    function getLastSender() external view returns (address) {
        return LibBatchHarnessStorage.layout().lastSender;
    }
}

contract BatchFacetTest is Test {
    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal alice = makeAddr("alice");

    EdenDiamond internal diamond;
    BatchHarnessFacet internal batchFacet;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        batchFacet = new BatchHarnessFacet();

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");
    }

    function test_Multicall_PreservesMsgSenderAndReturnsResults() public {
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(BatchHarnessFacet.recordSender, ());
        calls[1] = abi.encodeCall(BatchHarnessFacet.incrementCounter, (2));
        calls[2] = abi.encodeCall(BatchHarnessFacet.incrementCounter, (3));

        vm.prank(alice);
        bytes[] memory results = IEdenBatchFacet(address(diamond)).multicall(calls);

        assertEq(results.length, 3);
        assertEq(abi.decode(results[0], (address)), alice);
        assertEq(BatchHarnessFacet(address(diamond)).getLastSender(), alice);
        assertEq(abi.decode(results[1], (uint256)), 2);
        assertEq(abi.decode(results[2], (uint256)), 5);
        assertEq(BatchHarnessFacet(address(diamond)).getCounter(), 5);
    }

    function test_Multicall_IsAtomicOnRevert() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(BatchHarnessFacet.incrementCounter, (7));
        calls[1] = abi.encodeCall(BatchHarnessFacet.failWithReason, ());

        vm.expectRevert(bytes("batch failure"));
        IEdenBatchFacet(address(diamond)).multicall(calls);

        assertEq(BatchHarnessFacet(address(diamond)).getCounter(), 0);
    }

    function test_Multicall_RevertsOnNonZeroMsgValue() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(BatchHarnessFacet.incrementCounter, (1));

        vm.expectRevert(abi.encodeWithSelector(EdenBatchFacet.NativeValueUnsupported.selector, 1));
        IEdenBatchFacet(address(diamond)).multicall{ value: 1 }(calls);
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](1);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = IEdenBatchFacet.multicall.selector;
        selectors[1] = BatchHarnessFacet.recordSender.selector;
        selectors[2] = BatchHarnessFacet.incrementCounter.selector;
        selectors[3] = BatchHarnessFacet.failWithReason.selector;
        selectors[4] = BatchHarnessFacet.getCounter.selector;
        selectors[5] = BatchHarnessFacet.getLastSender.selector;
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(batchFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
    }
}
