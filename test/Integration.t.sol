// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { DiamondLoupeFacet } from "src/facets/DiamondLoupeFacet.sol";
import { EdenAdminFacet } from "src/facets/EdenAdminFacet.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";
import { EdenFlashFacet } from "src/facets/EdenFlashFacet.sol";
import { EdenLendingFacet } from "src/facets/EdenLendingFacet.sol";
import { EdenStEVEFacet } from "src/facets/EdenStEVEFacet.sol";
import { EdenViewFacet } from "src/facets/EdenViewFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "src/interfaces/IDiamondLoupe.sol";
import { IEdenAdminFacet } from "src/interfaces/IEdenAdminFacet.sol";
import { IEdenCoreFacet } from "src/interfaces/IEdenCoreFacet.sol";
import { IEdenEvents } from "src/interfaces/IEdenEvents.sol";
import { IEdenFlashFacet } from "src/interfaces/IEdenFlashFacet.sol";
import { IEdenFlashReceiver } from "src/interfaces/IEdenFlashReceiver.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { IEdenViewFacet } from "src/interfaces/IEdenViewFacet.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";
import { StEVEToken } from "src/tokens/StEVEToken.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RecordingFlashReceiver is IEdenFlashReceiver {
    uint256 public lastBasketId;
    uint256 public lastUnits;
    address[] internal lastAssets;
    uint256[] internal lastAmounts;
    uint256[] internal lastFees;

    function getLastLoan()
        external
        view
        returns (
            uint256 basketId,
            uint256 units,
            address[] memory assets,
            uint256[] memory amounts,
            uint256[] memory fees
        )
    {
        return (lastBasketId, lastUnits, lastAssets, lastAmounts, lastFees);
    }

    function onEdenFlashLoan(
        uint256 basketId,
        uint256 units,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata
    ) external {
        delete lastAssets;
        delete lastAmounts;
        delete lastFees;

        lastBasketId = basketId;
        lastUnits = units;

        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            lastAssets.push(assets[i]);
            lastAmounts.push(amounts[i]);
            lastFees.push(feeAmounts[i]);
            ERC20(assets[i]).transfer(msg.sender, amounts[i] + feeAmounts[i]);
        }
    }
}

contract IntegrationTest is Test, IEdenEvents {
    bytes32 internal constant MINT_FEE_SOURCE = keccak256("MINT_FEE");
    bytes32 internal constant PROTOCOL_FEE_SELF_SOURCE = keccak256("PROTOCOL_FEE_SELF");
    bytes32 internal constant PROTOCOL_FEE_STEVE_SOURCE = keccak256("PROTOCOL_FEE_STEVE");
    bytes32 internal constant PROTOCOL_FEE_ORIGIN_SOURCE = keccak256("PROTOCOL_FEE_ORIGIN");

    uint256 internal constant UNIT = 1e18;
    uint256 internal constant DAY = 1 days;
    uint256 internal constant BASE_REWARD = 100e18;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    EdenDiamond internal diamond;
    DiamondLoupeFacet internal loupeFacet;
    EdenCoreFacet internal coreFacet;
    EdenStEVEFacet internal stEveFacet;
    EdenLendingFacet internal lendingFacet;
    EdenAdminFacet internal adminFacet;
    EdenViewFacet internal viewFacet;
    EdenFlashFacet internal flashFacet;

    MockERC20 internal eve;
    MockERC20 internal alt;
    RecordingFlashReceiver internal receiver;
    StEVEToken internal stEveToken;
    BasketToken internal basketToken;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        loupeFacet = new DiamondLoupeFacet();
        coreFacet = new EdenCoreFacet();
        stEveFacet = new EdenStEVEFacet();
        lendingFacet = new EdenLendingFacet();
        adminFacet = new EdenAdminFacet();
        viewFacet = new EdenViewFacet();
        flashFacet = new EdenFlashFacet();

        eve = new MockERC20("EVE", "EVE");
        alt = new MockERC20("ALT", "ALT");
        receiver = new RecordingFlashReceiver();

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");

        vm.startPrank(owner);
        IEdenAdminFacet(address(diamond)).setTreasury(treasury);
        IEdenAdminFacet(address(diamond)).setTreasuryFeeBps(1000);
        IEdenAdminFacet(address(diamond)).setFeePotShareBps(6000);
        IEdenAdminFacet(address(diamond)).setProtocolFeeSplitBps(7500);
        vm.stopPrank();

        eve.mint(owner, 20_000_000e18);
        eve.mint(alice, 20_000_000e18);
        eve.mint(bob, 20_000_000e18);
        eve.mint(address(receiver), 20_000_000e18);
        alt.mint(alice, 20_000_000e18);
        alt.mint(bob, 20_000_000e18);
        alt.mint(address(receiver), 20_000_000e18);

        vm.prank(owner);
        (, address stEveTokenAddress) = IEdenCoreFacet(address(diamond)).createBasket(_stEveParams());
        stEveToken = StEVEToken(stEveTokenAddress);

        vm.prank(owner);
        (, address basketTokenAddress) = IEdenCoreFacet(address(diamond)).createBasket(_basketParams());
        basketToken = BasketToken(basketTokenAddress);

        vm.startPrank(owner);
        IEdenStEVEFacet(address(diamond)).configureRewards(
            block.timestamp,
            DAY,
            183,
            3,
            BASE_REWARD,
            548,
            BASE_REWARD
        );
        eve.approve(address(diamond), type(uint256).max);
        IEdenStEVEFacet(address(diamond)).fundRewards(10_000e18);

        IEdenLendingFacet(address(diamond)).configureLending(0, 1 days, 10 days);
        IEdenLendingFacet(address(diamond)).configureLending(1, 1 days, 10 days);
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(
            0, _u256Array(UNIT, 2 * UNIT), _u256Array(0.1 ether, 0.01 ether)
        );
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(
            1, _u256Array(UNIT, 2 * UNIT), _u256Array(0.2 ether, 0.02 ether)
        );
        vm.stopPrank();

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        alt.approve(address(diamond), type(uint256).max);
        stEveToken.approve(address(diamond), type(uint256).max);
        basketToken.approve(address(diamond), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        eve.approve(address(diamond), type(uint256).max);
        alt.approve(address(diamond), type(uint256).max);
        stEveToken.approve(address(diamond), type(uint256).max);
        basketToken.approve(address(diamond), type(uint256).max);
        vm.stopPrank();

        vm.deal(alice, 20 ether);
        vm.deal(bob, 20 ether);
    }

    function test_Integration_MintBurnFlowAndFeeRouting() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);

        assertEq(basketToken.balanceOf(alice), UNIT);
        assertEq(eve.balanceOf(treasury), 1e18);
        assertEq(alt.balanceOf(treasury), 0.5e18);
        assertEq(IEdenViewFacet(address(diamond)).getFeePot(1, address(eve)), 6.3e18);
        assertEq(IEdenViewFacet(address(diamond)).getFeePot(1, address(alt)), 3.15e18);
        assertEq(IEdenViewFacet(address(diamond)).getFeePot(0, address(eve)), 2.7e18);
        assertEq(IEdenViewFacet(address(diamond)).getFeePot(0, address(alt)), 1.35e18);

        uint256 eveBefore = eve.balanceOf(alice);
        uint256 altBefore = alt.balanceOf(alice);

        vm.prank(alice);
        uint256[] memory assetsOut = IEdenCoreFacet(address(diamond)).burn(1, UNIT, alice);

        assertEq(assetsOut.length, 2);
        assertEq(assetsOut[0], 95.67e18);
        assertEq(assetsOut[1], 47.835e18);
        assertEq(eve.balanceOf(alice) - eveBefore, 95.67e18);
        assertEq(alt.balanceOf(alice) - altBefore, 47.835e18);
        assertEq(basketToken.balanceOf(alice), 0);
        assertEq(basketToken.totalSupply(), 0);
        assertGt(IEdenViewFacet(address(diamond)).getFeePot(0, address(eve)), 2.7e18);
        assertGt(IEdenViewFacet(address(diamond)).getFeePot(0, address(alt)), 1.35e18);
    }

    function test_Integration_ClaimRewardsUsesEpochTwab() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(0, UNIT, alice);

        uint256 start = block.timestamp;
        vm.warp(block.timestamp + (DAY / 2));

        vm.prank(alice);
        stEveToken.transfer(bob, 0.5e18);

        vm.warp(start + DAY + 1);

        assertEq(IEdenStEVEFacet(address(diamond)).getUserTwab(alice, start, start + DAY), 0.75e18);
        assertEq(IEdenStEVEFacet(address(diamond)).getUserTwab(bob, start, start + DAY), 0.25e18);

        uint256 aliceBefore = eve.balanceOf(alice);
        uint256 bobBefore = eve.balanceOf(bob);

        vm.prank(alice);
        uint256 aliceClaim = IEdenStEVEFacet(address(diamond)).claimRewards();
        vm.prank(bob);
        uint256 bobClaim = IEdenStEVEFacet(address(diamond)).claimRewards();

        assertEq(aliceClaim, 75e18);
        assertEq(bobClaim, 25e18);
        assertEq(eve.balanceOf(alice) - aliceBefore, 75e18);
        assertEq(eve.balanceOf(bob) - bobBefore, 25e18);
        assertEq(IEdenStEVEFacet(address(diamond)).rewardReserveBalance(), 9_900e18);
    }

    function test_Integration_BorrowRepayLocksAndUnlocksCollateral() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);

        vm.prank(alice);
        uint256 loanId = IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 2 days);

        assertEq(loanId, 0);
        assertEq(basketToken.balanceOf(alice), UNIT);
        assertEq(basketToken.balanceOf(address(diamond)), UNIT);
        assertEq(IEdenViewFacet(address(diamond)).getLockedCollateral(1), UNIT);
        assertEq(IEdenViewFacet(address(diamond)).getOutstandingPrincipal(1, address(eve)), 100e18);
        assertEq(IEdenViewFacet(address(diamond)).getOutstandingPrincipal(1, address(alt)), 50e18);

        vm.prank(alice);
        IEdenLendingFacet(address(diamond)).repay(loanId);

        assertEq(basketToken.balanceOf(alice), 2 * UNIT);
        assertEq(basketToken.balanceOf(address(diamond)), 0);
        assertEq(IEdenViewFacet(address(diamond)).getLockedCollateral(1), 0);
        assertEq(IEdenViewFacet(address(diamond)).getOutstandingPrincipal(1, address(eve)), 0);
        assertEq(IEdenViewFacet(address(diamond)).getOutstandingPrincipal(1, address(alt)), 0);
        assertEq(IEdenViewFacet(address(diamond)).getLoan(loanId).borrower, alice);
    }

    function test_Integration_ExpireRecoverBurnsCollateral() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);

        vm.prank(alice);
        uint256 loanId = IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 1 days);

        uint256 totalSupplyBefore = basketToken.totalSupply();
        vm.warp(block.timestamp + 1 days + 1);
        IEdenLendingFacet(address(diamond)).recoverExpired(loanId);

        assertEq(basketToken.totalSupply(), totalSupplyBefore - UNIT);
        assertEq(IEdenViewFacet(address(diamond)).getLockedCollateral(1), 0);
        assertEq(IEdenViewFacet(address(diamond)).getOutstandingPrincipal(1, address(eve)), 0);
        assertEq(IEdenViewFacet(address(diamond)).getOutstandingPrincipal(1, address(alt)), 0);
        assertEq(IEdenViewFacet(address(diamond)).getLoan(loanId).borrower, alice);
    }

    function test_Integration_FlashLoanRepaysAndRoutesFees() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);

        uint256 treasuryEveBefore = eve.balanceOf(treasury);
        uint256 treasuryAltBefore = alt.balanceOf(treasury);
        uint256 basketEvePotBefore = IEdenViewFacet(address(diamond)).getFeePot(1, address(eve));
        uint256 basketAltPotBefore = IEdenViewFacet(address(diamond)).getFeePot(1, address(alt));
        uint256 steveEvePotBefore = IEdenViewFacet(address(diamond)).getFeePot(0, address(eve));
        uint256 steveAltPotBefore = IEdenViewFacet(address(diamond)).getFeePot(0, address(alt));

        IEdenFlashFacet(address(diamond)).flashLoan(1, UNIT, address(receiver), "");

        (
            uint256 basketId,
            uint256 units,
            address[] memory assets,
            uint256[] memory amounts,
            uint256[] memory fees
        ) = receiver.getLastLoan();

        assertEq(basketId, 1);
        assertEq(units, UNIT);
        assertEq(assets.length, 2);
        assertEq(amounts[0], 100e18);
        assertEq(amounts[1], 50e18);
        assertEq(fees[0], 5e18);
        assertEq(fees[1], 2.5e18);

        assertEq(eve.balanceOf(treasury) - treasuryEveBefore, 0.5e18);
        assertEq(alt.balanceOf(treasury) - treasuryAltBefore, 0.25e18);
        assertEq(IEdenViewFacet(address(diamond)).getFeePot(1, address(eve)) - basketEvePotBefore, 3.15e18);
        assertEq(IEdenViewFacet(address(diamond)).getFeePot(1, address(alt)) - basketAltPotBefore, 1.575e18);
        assertEq(IEdenViewFacet(address(diamond)).getFeePot(0, address(eve)) - steveEvePotBefore, 1.35e18);
        assertEq(IEdenViewFacet(address(diamond)).getFeePot(0, address(alt)) - steveAltPotBefore, 0.675e18);
    }

    function test_Integration_PauseAndFreezeFlows() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);

        vm.prank(alice);
        uint256 loanId = IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 1 days);

        vm.prank(owner);
        IEdenAdminFacet(address(diamond)).setPaused(1, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EdenCoreFacet.BasketPaused.selector, 1));
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EdenCoreFacet.BasketPaused.selector, 1));
        IEdenCoreFacet(address(diamond)).burn(1, UNIT, alice);

        vm.expectRevert(abi.encodeWithSelector(EdenCoreFacet.BasketPaused.selector, 1));
        IEdenFlashFacet(address(diamond)).flashLoan(1, UNIT, address(receiver), "");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EdenLendingFacet.BasketPaused.selector, 1));
        IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 1 days);

        vm.prank(alice);
        IEdenLendingFacet(address(diamond)).extend{ value: 0.2 ether }(loanId, 1 days);

        vm.prank(alice);
        IEdenLendingFacet(address(diamond)).repay(loanId);

        address viewFacetAddress = IDiamondLoupe(address(diamond)).facetAddress(IEdenViewFacet.nav.selector);
        vm.prank(owner);
        IEdenAdminFacet(address(diamond)).freezeFacet(viewFacetAddress);

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IEdenViewFacet.nav.selector;
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: selectors
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EdenDiamond.FacetIsFrozen.selector, viewFacetAddress));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    function test_Integration_StEveCircularSplitPrevention() public {
        vm.prank(owner);
        IEdenAdminFacet(address(diamond)).setIndexFees(0, _u16ArraySingle(1000), _u16ArraySingle(0), 0);

        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(0, UNIT, alice);

        assertEq(eve.balanceOf(treasury), 10e18);
        assertEq(IEdenViewFacet(address(diamond)).getFeePot(0, address(eve)), 90e18);
    }

    function test_Events_BasketCreatedEmitted() public {
        IEdenCoreFacet.CreateBasketParams memory params = IEdenCoreFacet.CreateBasketParams({
            name: "Third Basket",
            symbol: "TBK",
            assets: _addressArray(address(alt)),
            bundleAmounts: _uintArraySingle(25e18),
            mintFeeBps: _u16ArraySingle(0),
            burnFeeBps: _u16ArraySingle(0),
            flashFeeBps: 0
        });

        vm.recordLogs();
        vm.prank(owner);
        IEdenCoreFacet(address(diamond)).createBasket(params);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(entries[0].emitter, address(diamond));
        assertEq(entries[0].topics[0], keccak256("BasketCreated(uint256,address,address,address[],uint256[])"));
        assertEq(uint256(entries[0].topics[1]), 2);
        assertEq(address(uint160(uint256(entries[0].topics[2]))), owner);

        (address token, address[] memory assets, uint256[] memory bundleAmounts) =
            abi.decode(entries[0].data, (address, address[], uint256[]));
        assertTrue(token != address(0));
        assertEq(assets.length, 1);
        assertEq(assets[0], address(alt));
        assertEq(bundleAmounts.length, 1);
        assertEq(bundleAmounts[0], 25e18);
    }

    function test_Events_MintBurnAndFeeEventsEmitted() public {
        address[] memory assets = new address[](2);
        assets[0] = address(eve);
        assets[1] = address(alt);

        uint256[] memory deposited = new uint256[](2);
        deposited[0] = 110e18;
        deposited[1] = 55e18;

        uint256[] memory fees = new uint256[](2);
        fees[0] = 10e18;
        fees[1] = 5e18;

        vm.expectEmit(true, true, true, true, address(diamond));
        emit FeePotAccrued(1, address(eve), 5.4e18, MINT_FEE_SOURCE);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit FeePotAccrued(0, address(eve), 2.7e18, PROTOCOL_FEE_STEVE_SOURCE);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit FeePotAccrued(1, address(eve), 0.9e18, PROTOCOL_FEE_ORIGIN_SOURCE);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit ProtocolFeeRouted(1, address(eve), 2.7e18, 0.9e18);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit Minted(1, alice, UNIT, deposited, fees);

        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);

        uint256[] memory returned = new uint256[](2);
        returned[0] = 95.67e18;
        returned[1] = 47.835e18;

        uint256[] memory burnFees = new uint256[](2);
        burnFees[0] = 10.63e18;
        burnFees[1] = 5.315e18;

        vm.expectEmit(true, true, true, true, address(diamond));
        emit Burned(1, alice, UNIT, returned, burnFees);

        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).burn(1, UNIT, alice);
    }

    function test_Events_RewardEventsEmitted() public {
        vm.expectEmit(true, true, true, true, address(diamond));
        emit RewardsFunded(50e18, 10_050e18);
        vm.prank(owner);
        IEdenStEVEFacet(address(diamond)).fundRewards(50e18);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit RewardRateUpdated(0, 50e18);
        vm.prank(owner);
        IEdenStEVEFacet(address(diamond)).setRewardPerEpoch(50e18);

        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(0, UNIT, alice);
        vm.warp(block.timestamp + DAY + 1);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit RewardsClaimed(alice, 0, 0, 50e18);
        vm.prank(alice);
        IEdenStEVEFacet(address(diamond)).claimRewards();
    }

    function test_Events_LendingEventsEmitted() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);

        address[] memory assets = new address[](2);
        assets[0] = address(eve);
        assets[1] = address(alt);
        uint256[] memory principals = new uint256[](2);
        principals[0] = 100e18;
        principals[1] = 50e18;

        uint40 expectedMaturity = uint40(block.timestamp + 1 days);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit LoanCreated(0, 1, alice, UNIT, assets, principals, 10_000, expectedMaturity);
        vm.prank(alice);
        uint256 loanId = IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 1 days);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit LoanExtended(loanId, uint40(expectedMaturity + 1 days), 0.2 ether);
        vm.prank(alice);
        IEdenLendingFacet(address(diamond)).extend{ value: 0.2 ether }(loanId, 1 days);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit LoanRepaid(loanId);
        vm.prank(alice);
        IEdenLendingFacet(address(diamond)).repay(loanId);

        vm.prank(alice);
        uint256 recoveryLoanId = IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 1 days);
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit LoanRecovered(recoveryLoanId, UNIT, assets, principals);
        IEdenLendingFacet(address(diamond)).recoverExpired(recoveryLoanId);
    }

    function test_Events_FlashAndAdminEventsEmitted() public {
        vm.expectEmit(true, true, true, true, address(diamond));
        emit ProtocolFeeSplitUpdated(7500, 2500);
        vm.prank(owner);
        IEdenAdminFacet(address(diamond)).setProtocolFeeSplitBps(2500);

        address flashFacetAddress = IDiamondLoupe(address(diamond)).facetAddress(IEdenFlashFacet.flashLoan.selector);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit FacetFrozen(flashFacetAddress);
        vm.prank(owner);
        IEdenAdminFacet(address(diamond)).freezeFacet(flashFacetAddress);

        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 50e18;
        uint256[] memory fees = new uint256[](2);
        fees[0] = 5e18;
        fees[1] = 2.5e18;

        vm.expectEmit(true, true, true, true, address(diamond));
        emit FlashLoaned(1, address(receiver), UNIT, amounts, fees);
        IEdenFlashFacet(address(diamond)).flashLoan(1, UNIT, address(receiver), "");
    }

    function _stEveParams() internal view returns (IEdenCoreFacet.CreateBasketParams memory params) {
        params = IEdenCoreFacet.CreateBasketParams({
            name: "Staked EVE",
            symbol: "stEVE",
            assets: _addressArray(address(eve)),
            bundleAmounts: _uintArraySingle(1000e18),
            mintFeeBps: _u16ArraySingle(0),
            burnFeeBps: _u16ArraySingle(0),
            flashFeeBps: 0
        });
    }

    function _basketParams() internal view returns (IEdenCoreFacet.CreateBasketParams memory params) {
        address[] memory assets = new address[](2);
        assets[0] = address(eve);
        assets[1] = address(alt);

        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 100e18;
        bundleAmounts[1] = 50e18;

        uint16[] memory mintFeeBps = new uint16[](2);
        mintFeeBps[0] = 1000;
        mintFeeBps[1] = 1000;

        uint16[] memory burnFeeBps = new uint16[](2);
        burnFeeBps[0] = 1000;
        burnFeeBps[1] = 1000;

        params = IEdenCoreFacet.CreateBasketParams({
            name: "Eden Basket",
            symbol: "EDEN",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeBps: mintFeeBps,
            burnFeeBps: burnFeeBps,
            flashFeeBps: 500
        });
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](7);
        cuts[0] = _cut(address(coreFacet), _coreSelectors());
        cuts[1] = _cut(address(stEveFacet), _stEveSelectors());
        cuts[2] = _cut(address(lendingFacet), _lendingSelectors());
        cuts[3] = _cut(address(adminFacet), _adminSelectors());
        cuts[4] = _cut(address(viewFacet), _viewSelectors());
        cuts[5] = _cut(address(flashFacet), _flashSelectors());
        cuts[6] = _cut(address(loupeFacet), _loupeSelectors());
    }

    function _cut(address facet, bytes4[] memory selectors)
        internal
        pure
        returns (IDiamondCut.FacetCut memory)
    {
        return IDiamondCut.FacetCut({
            facetAddress: facet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
    }

    function _coreSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IEdenCoreFacet.createBasket.selector;
        selectors[1] = IEdenCoreFacet.mint.selector;
        selectors[2] = IEdenCoreFacet.burn.selector;
        selectors[3] = IEdenCoreFacet.onBasketTokenTransfer.selector;
    }

    function _stEveSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = IEdenStEVEFacet.claimRewards.selector;
        selectors[1] = IEdenStEVEFacet.configureRewards.selector;
        selectors[2] = IEdenStEVEFacet.fundRewards.selector;
        selectors[3] = IEdenStEVEFacet.setRewardPerEpoch.selector;
        selectors[4] = IEdenStEVEFacet.rewardForEpoch.selector;
        selectors[5] = IEdenStEVEFacet.currentEpoch.selector;
        selectors[6] = IEdenStEVEFacet.rewardReserveBalance.selector;
        selectors[7] = IEdenStEVEFacet.currentEmissionRate.selector;
        selectors[8] = IEdenStEVEFacet.getUserTwab.selector;
        selectors[9] = IEdenStEVEFacet.onStEVETransfer.selector;
    }

    function _lendingSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IEdenLendingFacet.borrow.selector;
        selectors[1] = IEdenLendingFacet.repay.selector;
        selectors[2] = IEdenLendingFacet.extend.selector;
        selectors[3] = IEdenLendingFacet.recoverExpired.selector;
        selectors[4] = IEdenLendingFacet.configureLending.selector;
        selectors[5] = IEdenLendingFacet.configureBorrowFeeTiers.selector;
    }

    function _adminSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](13);
        selectors[0] = IEdenAdminFacet.setBasketMetadata.selector;
        selectors[1] = IEdenAdminFacet.setProtocolURI.selector;
        selectors[2] = IEdenAdminFacet.setContractVersion.selector;
        selectors[3] = IEdenAdminFacet.setFacetVersion.selector;
        selectors[4] = IEdenAdminFacet.setIndexFees.selector;
        selectors[5] = IEdenAdminFacet.setTreasuryFeeBps.selector;
        selectors[6] = IEdenAdminFacet.setFeePotShareBps.selector;
        selectors[7] = IEdenAdminFacet.setProtocolFeeSplitBps.selector;
        selectors[8] = IEdenAdminFacet.setBasketCreationFee.selector;
        selectors[9] = IEdenAdminFacet.setPaused.selector;
        selectors[10] = IEdenAdminFacet.setTreasury.selector;
        selectors[11] = IEdenAdminFacet.setTimelock.selector;
        selectors[12] = IEdenAdminFacet.freezeFacet.selector;
    }

    function _viewSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](13);
        selectors[0] = IEdenViewFacet.nav.selector;
        selectors[1] = IEdenViewFacet.getBasket.selector;
        selectors[2] = IEdenViewFacet.totalBacking.selector;
        selectors[3] = IEdenViewFacet.getEconomicBalance.selector;
        selectors[4] = IEdenViewFacet.getVaultBalance.selector;
        selectors[5] = IEdenViewFacet.getFeePot.selector;
        selectors[6] = IEdenViewFacet.previewMint.selector;
        selectors[7] = IEdenViewFacet.previewBurn.selector;
        selectors[8] = IEdenViewFacet.getLoan.selector;
        selectors[9] = IEdenViewFacet.quoteBorrow.selector;
        selectors[10] = IEdenViewFacet.maxBorrowable.selector;
        selectors[11] = IEdenViewFacet.getLockedCollateral.selector;
        selectors[12] = IEdenViewFacet.getOutstandingPrincipal.selector;
    }

    function _flashSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IEdenFlashFacet.flashLoan.selector;
    }

    function _loupeSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
    }

    function _addressArray(address a) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = a;
    }

    function _uintArraySingle(uint256 a) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = a;
    }

    function _u16ArraySingle(uint16 a) internal pure returns (uint16[] memory values) {
        values = new uint16[](1);
        values[0] = a;
    }

    function _u256Array(uint256 a, uint256 b) internal pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = a;
        values[1] = b;
    }
}
