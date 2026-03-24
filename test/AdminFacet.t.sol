// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenAdminFacet } from "src/facets/EdenAdminFacet.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";
import { EdenFlashFacet } from "src/facets/EdenFlashFacet.sol";
import { EdenLendingFacet } from "src/facets/EdenLendingFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenAdminFacet } from "src/interfaces/IEdenAdminFacet.sol";
import { IEdenCoreFacet } from "src/interfaces/IEdenCoreFacet.sol";
import { IEdenFlashFacet } from "src/interfaces/IEdenFlashFacet.sol";
import { IEdenFlashReceiver } from "src/interfaces/IEdenFlashReceiver.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";

contract MockERC20 is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) { }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

contract FlashOpsHarnessFacet is EdenFlashFacet {
    function onBasketTokenTransfer(
        address,
        address,
        uint256
    ) external pure override { }

    function getBasketConfig(
        uint256 basketId
    )
        external
        view
        returns (
            uint16[] memory mintFeeBps,
            uint16[] memory burnFeeBps,
            uint16 flashFeeBps,
            bool paused
        )
    {
        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        return (basket.mintFeeBps, basket.burnFeeBps, basket.flashFeeBps, basket.paused);
    }

    function getProtocolConfig()
        external
        view
        returns (
            address treasury,
            address timelock,
            uint16 treasuryFeeBps,
            uint16 feePotShareBps,
            uint16 protocolFeeSplitBps,
            uint256 basketCreationFee
        )
    {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        return (
            store.treasury,
            store.timelock,
            store.treasuryFeeBps,
            store.feePotShareBps,
            store.protocolFeeSplitBps,
            store.basketCreationFee
        );
    }

    function getLoan(
        uint256 loanId
    ) external view returns (LibLendingStorage.Loan memory) {
        return LibLendingStorage.layout().loans[loanId];
    }
}

contract MockFlashReceiver is IEdenFlashReceiver {
    function onEdenFlashLoan(
        uint256,
        uint256,
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure { }
}

contract AdminFacetTest is Test {
    event ProtocolFeeSplitUpdated(uint16 oldBps, uint16 newBps);

    uint256 internal constant UNIT = 1e18;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");
    address internal treasury2 = makeAddr("treasury2");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    EdenDiamond internal diamond;
    EdenAdminFacet internal adminFacet;
    FlashOpsHarnessFacet internal flashOpsFacet;
    EdenLendingFacet internal lendingFacet;
    MockERC20 internal eve;
    MockERC20 internal alt;
    MockFlashReceiver internal flashReceiver;
    BasketToken internal basketOneToken;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        adminFacet = new EdenAdminFacet();
        flashOpsFacet = new FlashOpsHarnessFacet();
        lendingFacet = new EdenLendingFacet();
        eve = new MockERC20("EVE", "EVE");
        alt = new MockERC20("ALT", "ALT");
        flashReceiver = new MockFlashReceiver();

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");

        vm.startPrank(owner);
        IEdenAdminFacet(address(diamond)).setTreasury(treasury);
        IEdenAdminFacet(address(diamond)).setTreasuryFeeBps(1000);
        IEdenAdminFacet(address(diamond)).setFeePotShareBps(6000);
        IEdenAdminFacet(address(diamond)).setProtocolFeeSplitBps(7500);
        vm.stopPrank();

        _createBasketZero();
        _createBasketOne();
        _seedAndApprove();
    }

    function test_Admin_SettersStoreValuesRespectCapsAndEmit() public {
        vm.prank(owner);
        IEdenAdminFacet(address(diamond))
            .setIndexFees(1, _u16Array(100, 200), _u16Array(300, 400), 500);

        (uint16[] memory mintFeeBps, uint16[] memory burnFeeBps, uint16 flashFeeBps, bool paused) =
            FlashOpsHarnessFacet(address(diamond)).getBasketConfig(1);
        assertEq(mintFeeBps.length, 2);
        assertEq(burnFeeBps.length, 2);
        assertEq(mintFeeBps[0], 100);
        assertEq(mintFeeBps[1], 200);
        assertEq(burnFeeBps[0], 300);
        assertEq(burnFeeBps[1], 400);
        assertEq(flashFeeBps, 500);
        assertFalse(paused);

        vm.prank(owner);
        vm.expectRevert(EdenAdminFacet.FeeCapExceeded.selector);
        IEdenAdminFacet(address(diamond)).setIndexFees(1, _u16Array(1001, 0), _u16Array(0, 0), 0);

        vm.prank(owner);
        vm.expectRevert(EdenAdminFacet.FeeCapExceeded.selector);
        IEdenAdminFacet(address(diamond)).setIndexFees(1, _u16Array(0, 0), _u16Array(1001, 0), 0);

        vm.prank(owner);
        vm.expectRevert(EdenAdminFacet.FeeCapExceeded.selector);
        IEdenAdminFacet(address(diamond)).setIndexFees(1, _u16Array(0, 0), _u16Array(0, 0), 1001);

        vm.prank(owner);
        vm.expectRevert(EdenAdminFacet.FeeCapExceeded.selector);
        IEdenAdminFacet(address(diamond)).setTreasuryFeeBps(5001);

        vm.prank(owner);
        vm.expectRevert(EdenAdminFacet.FeeCapExceeded.selector);
        IEdenAdminFacet(address(diamond)).setFeePotShareBps(10_001);

        vm.prank(owner);
        vm.expectRevert(EdenAdminFacet.FeeCapExceeded.selector);
        IEdenAdminFacet(address(diamond)).setProtocolFeeSplitBps(10_001);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit ProtocolFeeSplitUpdated(7500, 2500);
        vm.prank(owner);
        IEdenAdminFacet(address(diamond)).setProtocolFeeSplitBps(2500);

        vm.prank(timelock);
        IEdenAdminFacet(address(diamond)).setBasketCreationFee(1 ether);
        vm.prank(timelock);
        IEdenAdminFacet(address(diamond)).setTreasury(treasury2);
        vm.prank(timelock);
        IEdenAdminFacet(address(diamond)).setTimelock(makeAddr("newTimelock"));

        (
            address treasuryAddress,
            address timelockAddress,
            uint16 treasuryFeeBps,
            uint16 feePotShareBps,
            uint16 protocolFeeSplitBps,
            uint256 basketCreationFee
        ) = FlashOpsHarnessFacet(address(diamond)).getProtocolConfig();

        assertEq(treasuryAddress, treasury2);
        assertEq(treasuryFeeBps, 1000);
        assertEq(feePotShareBps, 6000);
        assertEq(protocolFeeSplitBps, 2500);
        assertEq(basketCreationFee, 1 ether);
        assertTrue(timelockAddress != timelock);
    }

    function test_Admin_UnauthorizedCallsRevert() public {
        vm.startPrank(alice);

        vm.expectRevert(EdenAdminFacet.Unauthorized.selector);
        IEdenAdminFacet(address(diamond)).setIndexFees(1, _u16Array(1, 1), _u16Array(1, 1), 1);

        vm.expectRevert(EdenAdminFacet.Unauthorized.selector);
        IEdenAdminFacet(address(diamond)).setTreasuryFeeBps(1);

        vm.expectRevert(EdenAdminFacet.Unauthorized.selector);
        IEdenAdminFacet(address(diamond)).setFeePotShareBps(1);

        vm.expectRevert(EdenAdminFacet.Unauthorized.selector);
        IEdenAdminFacet(address(diamond)).setProtocolFeeSplitBps(1);

        vm.expectRevert(EdenAdminFacet.Unauthorized.selector);
        IEdenAdminFacet(address(diamond)).setBasketCreationFee(1);

        vm.expectRevert(EdenAdminFacet.Unauthorized.selector);
        IEdenAdminFacet(address(diamond)).setPaused(1, true);

        vm.expectRevert(EdenAdminFacet.Unauthorized.selector);
        IEdenAdminFacet(address(diamond)).setTreasury(alice);

        vm.expectRevert(EdenAdminFacet.Unauthorized.selector);
        IEdenAdminFacet(address(diamond)).setTimelock(alice);

        vm.stopPrank();
    }

    function test_Admin_PauseBlocksMintBurnFlashAndBorrow() public {
        vm.startPrank(owner);
        IEdenAdminFacet(address(diamond)).setIndexFees(1, _u16Array(0, 0), _u16Array(0, 0), 500);
        IEdenLendingFacet(address(diamond)).configureLending(1, 1 days, 10 days);
        IEdenLendingFacet(address(diamond))
            .configureBorrowFeeTiers(1, _u256Array(UNIT), _u256Array(0.2 ether));
        vm.stopPrank();

        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);

        vm.prank(owner);
        IEdenAdminFacet(address(diamond)).setPaused(1, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EdenCoreFacet.BasketPaused.selector, uint256(1)));
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EdenCoreFacet.BasketPaused.selector, uint256(1)));
        IEdenCoreFacet(address(diamond)).burn(1, UNIT, alice);

        vm.expectRevert(abi.encodeWithSelector(EdenCoreFacet.BasketPaused.selector, uint256(1)));
        IEdenFlashFacet(address(diamond)).flashLoan(1, UNIT, address(flashReceiver), "");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EdenLendingFacet.BasketPaused.selector, uint256(1)));
        IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 2 days);
    }

    function test_Admin_PauseStillAllowsExtendRepayAndRecover() public {
        vm.startPrank(owner);
        IEdenAdminFacet(address(diamond)).setIndexFees(1, _u16Array(0, 0), _u16Array(0, 0), 500);
        IEdenLendingFacet(address(diamond)).configureLending(1, 1 days, 10 days);
        IEdenLendingFacet(address(diamond))
            .configureBorrowFeeTiers(1, _u256Array(UNIT), _u256Array(0.2 ether));
        vm.stopPrank();

        vm.startPrank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);
        IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 2 days);
        vm.stopPrank();

        vm.startPrank(bob);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, bob);
        uint256 bobLoanId =
            IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 1 days);
        vm.stopPrank();

        vm.prank(owner);
        IEdenAdminFacet(address(diamond)).setPaused(1, true);

        LibLendingStorage.Loan memory aliceLoan = FlashOpsHarnessFacet(address(diamond)).getLoan(0);
        uint256 treasuryBefore = treasury.balance;

        vm.warp(block.timestamp + 12 hours);
        vm.prank(alice);
        IEdenLendingFacet(address(diamond)).extend{ value: 0.2 ether }(0, 1 days);

        LibLendingStorage.Loan memory extendedLoan =
            FlashOpsHarnessFacet(address(diamond)).getLoan(0);
        assertEq(extendedLoan.maturity, aliceLoan.maturity + 1 days);
        assertEq(treasury.balance - treasuryBefore, 0.2 ether);

        vm.startPrank(alice);
        IEdenLendingFacet(address(diamond)).repay(0);
        vm.stopPrank();

        LibLendingStorage.Loan memory repaidLoan = FlashOpsHarnessFacet(address(diamond)).getLoan(0);
        assertEq(repaidLoan.borrower, alice);
        assertEq(repaidLoan.basketId, 1);
        assertEq(repaidLoan.collateralUnits, UNIT);

        vm.warp(block.timestamp + 2 days);
        IEdenLendingFacet(address(diamond)).recoverExpired(bobLoanId);

        LibLendingStorage.Loan memory recoveredLoan =
            FlashOpsHarnessFacet(address(diamond)).getLoan(bobLoanId);
        assertEq(recoveredLoan.borrower, bob);
        assertEq(recoveredLoan.basketId, 1);
        assertEq(recoveredLoan.collateralUnits, UNIT);
    }

    function _createBasketZero() internal {
        IEdenCoreFacet.CreateBasketParams memory params = IEdenCoreFacet.CreateBasketParams({
            name: "stEVE",
            symbol: "stEVE",
            assets: _addressArray(address(eve)),
            bundleAmounts: _u256Array(1000e18),
            mintFeeBps: _u16Array(0),
            burnFeeBps: _u16Array(0),
            flashFeeBps: 0
        });

        vm.prank(owner);
        IEdenCoreFacet(address(diamond)).createBasket(params);
    }

    function _createBasketOne() internal {
        address[] memory assets = new address[](2);
        assets[0] = address(eve);
        assets[1] = address(alt);

        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 100e18;
        bundleAmounts[1] = 50e18;

        uint16[] memory zeroFees = new uint16[](2);

        IEdenCoreFacet.CreateBasketParams memory params = IEdenCoreFacet.CreateBasketParams({
            name: "Basket",
            symbol: "BASK",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeBps: zeroFees,
            burnFeeBps: zeroFees,
            flashFeeBps: 0
        });

        vm.prank(owner);
        (, address token) = IEdenCoreFacet(address(diamond)).createBasket(params);
        basketOneToken = BasketToken(token);
    }

    function _seedAndApprove() internal {
        eve.mint(alice, 1_000_000e18);
        alt.mint(alice, 1_000_000e18);
        eve.mint(bob, 1_000_000e18);
        alt.mint(bob, 1_000_000e18);

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        alt.approve(address(diamond), type(uint256).max);
        basketOneToken.approve(address(diamond), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        eve.approve(address(diamond), type(uint256).max);
        alt.approve(address(diamond), type(uint256).max);
        basketOneToken.approve(address(diamond), type(uint256).max);
        vm.stopPrank();

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](3);

        bytes4[] memory adminSelectors = new bytes4[](8);
        adminSelectors[0] = IEdenAdminFacet.setIndexFees.selector;
        adminSelectors[1] = IEdenAdminFacet.setTreasuryFeeBps.selector;
        adminSelectors[2] = IEdenAdminFacet.setFeePotShareBps.selector;
        adminSelectors[3] = IEdenAdminFacet.setProtocolFeeSplitBps.selector;
        adminSelectors[4] = IEdenAdminFacet.setBasketCreationFee.selector;
        adminSelectors[5] = IEdenAdminFacet.setPaused.selector;
        adminSelectors[6] = IEdenAdminFacet.setTreasury.selector;
        adminSelectors[7] = IEdenAdminFacet.setTimelock.selector;

        bytes4[] memory flashSelectors = new bytes4[](8);
        flashSelectors[0] = IEdenCoreFacet.createBasket.selector;
        flashSelectors[1] = IEdenCoreFacet.mint.selector;
        flashSelectors[2] = IEdenCoreFacet.burn.selector;
        flashSelectors[3] = IEdenCoreFacet.onBasketTokenTransfer.selector;
        flashSelectors[4] = IEdenFlashFacet.flashLoan.selector;
        flashSelectors[5] = FlashOpsHarnessFacet.getBasketConfig.selector;
        flashSelectors[6] = FlashOpsHarnessFacet.getProtocolConfig.selector;
        flashSelectors[7] = FlashOpsHarnessFacet.getLoan.selector;

        bytes4[] memory lendingSelectors = new bytes4[](6);
        lendingSelectors[0] = IEdenLendingFacet.borrow.selector;
        lendingSelectors[1] = IEdenLendingFacet.repay.selector;
        lendingSelectors[2] = IEdenLendingFacet.extend.selector;
        lendingSelectors[3] = IEdenLendingFacet.recoverExpired.selector;
        lendingSelectors[4] = IEdenLendingFacet.configureLending.selector;
        lendingSelectors[5] = IEdenLendingFacet.configureBorrowFeeTiers.selector;

        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(adminFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: adminSelectors
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(flashOpsFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: flashSelectors
        });
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(lendingFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: lendingSelectors
        });
    }

    function _u16Array(
        uint16 a
    ) internal pure returns (uint16[] memory arr) {
        arr = new uint16[](1);
        arr[0] = a;
    }

    function _u16Array(
        uint16 a,
        uint16 b
    ) internal pure returns (uint16[] memory arr) {
        arr = new uint16[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _u256Array(
        uint256 a
    ) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _addressArray(
        address a
    ) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}
