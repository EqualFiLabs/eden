// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenAdminFacet } from "src/facets/EdenAdminFacet.sol";
import { EdenMetadataFacet } from "src/facets/EdenMetadataFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenAdminFacet } from "src/interfaces/IEdenAdminFacet.sol";
import { IEdenMetadataFacet } from "src/interfaces/IEdenMetadataFacet.sol";

contract TimelockDummyFacet {
    function ping() external pure returns (uint256) {
        return 42;
    }
}

contract TimelockGovernanceTest is Test {
    uint256 internal constant TIMELOCK_DELAY_SECONDS = 7 days;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");

    TimelockController internal timelock;
    EdenDiamond internal diamond;
    EdenAdminFacet internal adminFacet;
    EdenMetadataFacet internal metadataFacet;

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = owner;

        timelock = new TimelockController(TIMELOCK_DELAY_SECONDS, proposers, executors, owner);
        diamond = new EdenDiamond(owner, address(timelock));
        adminFacet = new EdenAdminFacet();
        metadataFacet = new EdenMetadataFacet();

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_initialFacetCuts(), address(0), "");
    }

    function test_TimelockGovernance_DelayIsFixedAtSevenDays() public {
        vm.prank(owner);
        IEdenAdminFacet(address(diamond)).completeBootstrap();

        IEdenMetadataFacet.ProtocolConfig memory config =
            IEdenMetadataFacet(address(diamond)).getProtocolConfig();
        assertEq(config.timelockDelaySeconds, TIMELOCK_DELAY_SECONDS);
        assertEq(config.owner, address(timelock));
        assertEq(config.timelock, address(timelock));
        assertEq(timelock.getMinDelay(), TIMELOCK_DELAY_SECONDS);

        bytes memory data = abi.encodeCall(IEdenAdminFacet.setProtocolURI, ("ipfs://eden"));
        bytes32 salt = keccak256("protocol-uri");

        vm.prank(owner);
        timelock.schedule(address(diamond), 0, data, bytes32(0), salt, TIMELOCK_DELAY_SECONDS);

        vm.warp(block.timestamp + TIMELOCK_DELAY_SECONDS - 1);
        vm.prank(owner);
        vm.expectRevert();
        timelock.execute(address(diamond), 0, data, bytes32(0), salt);

        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        timelock.execute(address(diamond), 0, data, bytes32(0), salt);

        assertEq(IEdenMetadataFacet(address(diamond)).protocolURI(), "ipfs://eden");
    }

    function test_TimelockGovernance_PrivilegedActionsAreTimelockOnlyAfterBootstrap() public {
        vm.prank(owner);
        IEdenAdminFacet(address(diamond)).completeBootstrap();

        vm.prank(owner);
        vm.expectRevert(EdenAdminFacet.Unauthorized.selector);
        IEdenAdminFacet(address(diamond)).setTreasury(treasury);

        vm.prank(owner);
        vm.expectRevert(EdenAdminFacet.Unauthorized.selector);
        IEdenAdminFacet(address(diamond)).setProtocolURI("ipfs://blocked");

        TimelockDummyFacet dummyFacet = new TimelockDummyFacet();
        bytes4[] memory dummySelectors = new bytes4[](1);
        dummySelectors[0] = TimelockDummyFacet.ping.selector;
        IDiamondCut.FacetCut[] memory addDummyCut = new IDiamondCut.FacetCut[](1);
        addDummyCut[0] = IDiamondCut.FacetCut({
            facetAddress: address(dummyFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: dummySelectors
        });

        vm.prank(owner);
        vm.expectRevert(EdenDiamond.Unauthorized.selector);
        IDiamondCut(address(diamond)).diamondCut(addDummyCut, address(0), "");

        _scheduleAndExecute(
            abi.encodeCall(IEdenAdminFacet.setTreasury, (treasury)), keccak256("treasury")
        );
        assertEq(IEdenMetadataFacet(address(diamond)).getProtocolConfig().treasury, treasury);

        _scheduleAndExecute(
            abi.encodeCall(IEdenAdminFacet.setProtocolURI, ("ipfs://timelocked")),
            keccak256("protocol-uri-execute")
        );
        assertEq(IEdenMetadataFacet(address(diamond)).protocolURI(), "ipfs://timelocked");

        _scheduleAndExecute(
            abi.encodeCall(IDiamondCut.diamondCut, (addDummyCut, address(0), bytes(""))),
            keccak256("diamond-cut")
        );

        (bool success, bytes memory data) =
            address(diamond).call(abi.encodeCall(TimelockDummyFacet.ping, ()));
        assertTrue(success);
        assertEq(abi.decode(data, (uint256)), 42);
    }

    function _scheduleAndExecute(
        bytes memory data,
        bytes32 salt
    ) internal {
        vm.prank(owner);
        timelock.schedule(address(diamond), 0, data, bytes32(0), salt, TIMELOCK_DELAY_SECONDS);

        vm.warp(block.timestamp + TIMELOCK_DELAY_SECONDS);
        vm.prank(owner);
        timelock.execute(address(diamond), 0, data, bytes32(0), salt);
    }

    function _initialFacetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](2);

        bytes4[] memory adminSelectors = new bytes4[](3);
        adminSelectors[0] = IEdenAdminFacet.completeBootstrap.selector;
        adminSelectors[1] = IEdenAdminFacet.setTreasury.selector;
        adminSelectors[2] = IEdenAdminFacet.setProtocolURI.selector;

        bytes4[] memory metadataSelectors = new bytes4[](2);
        metadataSelectors[0] = IEdenMetadataFacet.getProtocolConfig.selector;
        metadataSelectors[1] = IEdenMetadataFacet.protocolURI.selector;

        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(adminFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: adminSelectors
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(metadataFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: metadataSelectors
        });
    }
}
