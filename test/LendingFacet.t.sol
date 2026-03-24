// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenLendingFacet } from "src/facets/EdenLendingFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { LibStEVEStorage } from "src/libraries/LibStEVEStorage.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";
import { StEVEToken } from "src/tokens/StEVEToken.sol";

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

contract LendingHarnessFacet is EdenLendingFacet {
    function setTreasury(
        address treasury
    ) external {
        LibEdenStorage.layout().treasury = treasury;
    }

    function setBasket(
        uint256 basketId,
        address token,
        address[] calldata assets,
        uint256[] calldata bundleAmounts,
        bool isSteve
    ) external {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        if (basketId >= store.basketCount) {
            store.basketCount = basketId + 1;
        }
        if (isSteve) {
            store.steveBasketId = basketId;
        }

        LibEdenStorage.Basket storage basket = store.baskets[basketId];
        delete basket.assets;
        delete basket.bundleAmounts;
        delete basket.mintFeeBps;
        delete basket.burnFeeBps;
        basket.token = token;
        basket.paused = false;

        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            basket.assets.push(assets[i]);
            basket.bundleAmounts.push(bundleAmounts[i]);
            basket.mintFeeBps.push(0);
            basket.burnFeeBps.push(0);
        }
    }

    function mintReceiptUnits(
        uint256 basketId,
        address to,
        uint256 amount
    ) external {
        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        basket.totalUnits += amount;
        BasketToken(basket.token).mintIndexUnits(to, amount);
    }

    function setVaultBalance(
        uint256 basketId,
        address asset,
        uint256 amount
    ) external {
        LibEdenStorage.layout().vaultBalances[basketId][asset] = amount;
    }

    function getLoan(
        uint256 loanId
    ) external view returns (LibLendingStorage.Loan memory) {
        return LibLendingStorage.layout().loans[loanId];
    }

    function getBorrowerLoanIds(
        address borrower
    ) external view returns (uint256[] memory) {
        return LibLendingStorage.layout().borrowerLoanIds[borrower];
    }

    function getLoanClosed(
        uint256 loanId
    ) external view returns (bool) {
        return LibLendingStorage.layout().loanClosed[loanId];
    }

    function getLoanClosedAt(
        uint256 loanId
    ) external view returns (uint256) {
        return LibLendingStorage.layout().loanClosedAt[loanId];
    }

    function getLoanCloseReason(
        uint256 loanId
    ) external view returns (uint8) {
        return LibLendingStorage.layout().loanCloseReason[loanId];
    }

    function getLoanCreatedAt(
        uint256 loanId
    ) external view returns (uint256) {
        return LibLendingStorage.layout().loanCreatedAt[loanId];
    }

    function getLockedCollateral(
        uint256 basketId
    ) external view returns (uint256) {
        return LibLendingStorage.layout().lockedCollateralUnits[basketId];
    }

    function getOutstandingPrincipal(
        uint256 basketId,
        address asset
    ) external view returns (uint256) {
        return LibLendingStorage.layout().outstandingPrincipal[basketId][asset];
    }

    function getBorrowFeeTier(
        uint256 basketId,
        uint256 index
    ) external view returns (uint256 minCollateralUnits, uint256 flatFeeNative) {
        LibLendingStorage.BorrowFeeTier storage tier =
            LibLendingStorage.layout().borrowFeeTiers[basketId][index];
        return (tier.minCollateralUnits, tier.flatFeeNative);
    }

    function getBorrowFeeTierCount(
        uint256 basketId
    ) external view returns (uint256) {
        return LibLendingStorage.layout().borrowFeeTiers[basketId].length;
    }

    function getLiquidBalance(
        address user
    ) external view returns (uint256) {
        return LibStEVEStorage.layout().liquidBalances[user];
    }

    function getLockedBalance(
        address user
    ) external view returns (uint256) {
        return LibStEVEStorage.layout().lockedBalances[user];
    }

    function getEffectiveBalance(
        address user
    ) external view returns (uint256) {
        return LibStEVEStorage.effectiveBalance(user);
    }

    function getBasketTotalUnits(
        uint256 basketId
    ) external view returns (uint256) {
        return LibEdenStorage.layout().baskets[basketId].totalUnits;
    }

    function getVaultBalance(
        uint256 basketId,
        address asset
    ) external view returns (uint256) {
        return LibEdenStorage.layout().vaultBalances[basketId][asset];
    }
}

contract LendingFacetTest is Test {
    uint256 internal constant UNIT = 1e18;
    uint256 internal constant STEVE_BUNDLE = 1000e18;
    uint256 internal constant INDEX_EVE_BUNDLE = 100e18;
    uint256 internal constant INDEX_ALT_BUNDLE = 50e18;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    EdenDiamond internal diamond;
    LendingHarnessFacet internal lendingFacet;
    MockERC20 internal eve;
    MockERC20 internal alt;
    StEVEToken internal stEveToken;
    BasketToken internal indexToken;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        lendingFacet = new LendingHarnessFacet();
        eve = new MockERC20("EVE", "EVE");
        alt = new MockERC20("ALT", "ALT");
        stEveToken = new StEVEToken("stEVE", "stEVE", address(diamond));
        indexToken = new BasketToken("Basket Index", "BASK", address(diamond));

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");

        vm.prank(owner);
        LendingHarnessFacet(address(diamond)).setTreasury(treasury);

        address[] memory steveAssets = new address[](1);
        steveAssets[0] = address(eve);
        uint256[] memory steveBundle = new uint256[](1);
        steveBundle[0] = STEVE_BUNDLE;

        address[] memory basketAssets = new address[](2);
        basketAssets[0] = address(eve);
        basketAssets[1] = address(alt);
        uint256[] memory basketBundle = new uint256[](2);
        basketBundle[0] = INDEX_EVE_BUNDLE;
        basketBundle[1] = INDEX_ALT_BUNDLE;

        LendingHarnessFacet(address(diamond))
            .setBasket(0, address(stEveToken), steveAssets, steveBundle, true);
        LendingHarnessFacet(address(diamond))
            .setBasket(1, address(indexToken), basketAssets, basketBundle, false);

        vm.startPrank(owner);
        IEdenLendingFacet(address(diamond)).configureLending(0, 1 days, 10 days);
        IEdenLendingFacet(address(diamond)).configureLending(1, 1 days, 10 days);

        uint256[] memory mins = new uint256[](2);
        mins[0] = UNIT;
        mins[1] = 2 * UNIT;

        uint256[] memory steveFees = new uint256[](2);
        steveFees[0] = 0.1 ether;
        steveFees[1] = 0.01 ether;
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(0, mins, steveFees);

        uint256[] memory basketFees = new uint256[](2);
        basketFees[0] = 0.2 ether;
        basketFees[1] = 0.02 ether;
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(1, mins, basketFees);
        vm.stopPrank();

        eve.mint(address(diamond), 3_400e18);
        alt.mint(address(diamond), 200e18);
        LendingHarnessFacet(address(diamond)).setVaultBalance(0, address(eve), 3_000e18);
        LendingHarnessFacet(address(diamond)).setVaultBalance(1, address(eve), 400e18);
        LendingHarnessFacet(address(diamond)).setVaultBalance(1, address(alt), 200e18);

        LendingHarnessFacet(address(diamond)).mintReceiptUnits(0, alice, 2 * UNIT);
        LendingHarnessFacet(address(diamond)).mintReceiptUnits(0, bob, UNIT);
        LendingHarnessFacet(address(diamond)).mintReceiptUnits(1, alice, 2 * UNIT);
        LendingHarnessFacet(address(diamond)).mintReceiptUnits(1, bob, 2 * UNIT);

        vm.startPrank(alice);
        stEveToken.approve(address(diamond), type(uint256).max);
        indexToken.approve(address(diamond), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        stEveToken.approve(address(diamond), type(uint256).max);
        indexToken.approve(address(diamond), type(uint256).max);
        vm.stopPrank();

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_ConfigureBorrowFeeTiers_AscendingOrderRequired() public {
        uint256[] memory mins = new uint256[](2);
        mins[0] = 2 * UNIT;
        mins[1] = UNIT;
        uint256[] memory fees = new uint256[](2);
        fees[0] = 1;
        fees[1] = 2;

        vm.prank(owner);
        vm.expectRevert(EdenLendingFacet.InvalidTierConfiguration.selector);
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(1, mins, fees);
    }

    function test_Borrow_MultiAssetPrincipalTierSelectionAndInvariant() public {
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        uint256 loanId =
            IEdenLendingFacet(address(diamond)).borrow{ value: 0.02 ether }(1, 2 * UNIT, 3 days);

        LibLendingStorage.Loan memory loan = LendingHarnessFacet(address(diamond)).getLoan(loanId);
        assertEq(loanId, 0);
        assertEq(loan.borrower, alice);
        assertEq(loan.basketId, 1);
        assertEq(loan.collateralUnits, 2 * UNIT);
        assertEq(loan.ltvBps, 10_000);

        assertEq(indexToken.balanceOf(alice), 0);
        assertEq(indexToken.balanceOf(address(diamond)), 2 * UNIT);
        assertEq(LendingHarnessFacet(address(diamond)).getLockedCollateral(1), 2 * UNIT);
        assertEq(
            LendingHarnessFacet(address(diamond)).getOutstandingPrincipal(1, address(eve)), 200e18
        );
        assertEq(
            LendingHarnessFacet(address(diamond)).getOutstandingPrincipal(1, address(alt)), 100e18
        );
        assertEq(LendingHarnessFacet(address(diamond)).getVaultBalance(1, address(eve)), 200e18);
        assertEq(LendingHarnessFacet(address(diamond)).getVaultBalance(1, address(alt)), 100e18);
        assertEq(eve.balanceOf(alice), 200e18);
        assertEq(alt.balanceOf(alice), 100e18);
        assertEq(treasury.balance - treasuryBefore, 0.02 ether);
        uint256[] memory borrowerLoanIds =
            LendingHarnessFacet(address(diamond)).getBorrowerLoanIds(alice);
        assertEq(borrowerLoanIds.length, 1);
        assertEq(borrowerLoanIds[0], loanId);
        assertEq(LendingHarnessFacet(address(diamond)).getLoanCreatedAt(loanId), block.timestamp);
        assertFalse(LendingHarnessFacet(address(diamond)).getLoanClosed(loanId));

        uint256 redeemableSupply = LendingHarnessFacet(address(diamond)).getBasketTotalUnits(1)
            - LendingHarnessFacet(address(diamond)).getLockedCollateral(1);
        assertEq(
            LendingHarnessFacet(address(diamond)).getVaultBalance(1, address(eve)),
            redeemableSupply * INDEX_EVE_BUNDLE / UNIT
        );
        assertEq(
            LendingHarnessFacet(address(diamond)).getVaultBalance(1, address(alt)),
            redeemableSupply * INDEX_ALT_BUNDLE / UNIT
        );
    }

    function test_Borrow_StEVELocksRewardsWithoutLosingEffectiveBalance() public {
        vm.prank(alice);
        uint256 loanId =
            IEdenLendingFacet(address(diamond)).borrow{ value: 0.1 ether }(0, UNIT, 2 days);

        assertEq(loanId, 0);
        assertEq(stEveToken.balanceOf(alice), UNIT);
        assertEq(stEveToken.balanceOf(address(diamond)), UNIT);
        assertEq(LendingHarnessFacet(address(diamond)).getLiquidBalance(alice), UNIT);
        assertEq(LendingHarnessFacet(address(diamond)).getLockedBalance(alice), UNIT);
        assertEq(LendingHarnessFacet(address(diamond)).getEffectiveBalance(alice), 2 * UNIT);
        assertEq(LendingHarnessFacet(address(diamond)).getLiquidBalance(address(diamond)), 0);
        assertEq(
            LendingHarnessFacet(address(diamond)).getOutstandingPrincipal(0, address(eve)), 1_000e18
        );
    }

    function test_LendingViewsAndPagination_ExposeBorrowerHistoryAndActiveSubset() public {
        vm.startPrank(alice);
        uint256 firstLoan =
            IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 2 days);
        uint256 secondLoan =
            IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 3 days);
        eve.approve(address(diamond), type(uint256).max);
        alt.approve(address(diamond), type(uint256).max);
        IEdenLendingFacet(address(diamond)).repay(firstLoan);
        vm.stopPrank();

        assertEq(IEdenLendingFacet(address(diamond)).loanCount(), 2);
        assertEq(IEdenLendingFacet(address(diamond)).borrowerLoanCount(alice), 2);

        uint256[] memory allLoanIds = IEdenLendingFacet(address(diamond)).getLoanIdsByBorrower(alice);
        assertEq(allLoanIds.length, 2);
        assertEq(allLoanIds[0], firstLoan);
        assertEq(allLoanIds[1], secondLoan);

        uint256[] memory paginatedLoanIds =
            IEdenLendingFacet(address(diamond)).getLoanIdsByBorrowerPaginated(alice, 1, 1);
        assertEq(paginatedLoanIds.length, 1);
        assertEq(paginatedLoanIds[0], secondLoan);

        uint256[] memory activeLoanIds =
            IEdenLendingFacet(address(diamond)).getActiveLoanIdsByBorrower(alice);
        assertEq(activeLoanIds.length, 1);
        assertEq(activeLoanIds[0], secondLoan);

        uint256[] memory activeLoanIdsPage =
            IEdenLendingFacet(address(diamond)).getActiveLoanIdsByBorrowerPaginated(alice, 0, 1);
        assertEq(activeLoanIdsPage.length, 1);
        assertEq(activeLoanIdsPage[0], secondLoan);

        IEdenLendingFacet.LoanView memory closedLoan =
            IEdenLendingFacet(address(diamond)).getLoanView(firstLoan);
        assertEq(closedLoan.loanId, firstLoan);
        assertEq(closedLoan.borrower, alice);
        assertEq(closedLoan.createdAt, LendingHarnessFacet(address(diamond)).getLoanCreatedAt(firstLoan));
        assertEq(closedLoan.closedAt, LendingHarnessFacet(address(diamond)).getLoanClosedAt(firstLoan));
        assertEq(closedLoan.closeReason, 1);
        assertFalse(closedLoan.active);
        assertFalse(closedLoan.expired);
        assertEq(closedLoan.principals[0], 100e18);
        assertEq(closedLoan.principals[1], 50e18);

        IEdenLendingFacet.LoanView[] memory loans =
            IEdenLendingFacet(address(diamond)).getLoansByBorrower(alice);
        assertEq(loans.length, 2);
        assertEq(loans[1].loanId, secondLoan);
        assertTrue(loans[1].active);

        IEdenLendingFacet.LoanView[] memory activeLoans =
            IEdenLendingFacet(address(diamond)).getActiveLoansByBorrower(alice);
        assertEq(activeLoans.length, 1);
        assertEq(activeLoans[0].loanId, secondLoan);
    }

    function test_LoanView_ExpiredStateAndPaginationOutOfBoundsBehaveCorrectly() public {
        vm.prank(alice);
        uint256 loanId =
            IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 2 days);

        vm.warp(block.timestamp + 2 days + 1);

        IEdenLendingFacet.LoanView memory loanView =
            IEdenLendingFacet(address(diamond)).getLoanView(loanId);
        assertEq(loanView.loanId, loanId);
        assertFalse(loanView.active);
        assertTrue(loanView.expired);
        assertEq(loanView.closedAt, 0);
        assertEq(loanView.closeReason, 0);
        assertEq(loanView.extensionFeeNative, 0.2 ether);
        assertEq(loanView.principals[0], 100e18);
        assertEq(loanView.principals[1], 50e18);

        uint256[] memory activeLoanIds =
            IEdenLendingFacet(address(diamond)).getActiveLoanIdsByBorrower(alice);
        assertEq(activeLoanIds.length, 0);

        uint256[] memory paginated =
            IEdenLendingFacet(address(diamond)).getLoanIdsByBorrowerPaginated(alice, 1, 1);
        assertEq(paginated.length, 0);

        uint256[] memory activePaginated =
            IEdenLendingFacet(address(diamond)).getActiveLoanIdsByBorrowerPaginated(alice, 0, 1);
        assertEq(activePaginated.length, 0);
    }

    function test_Borrow_RevertsOnDurationTierAndInvariantFailure() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                EdenLendingFacet.InvalidDuration.selector,
                uint256(12 hours),
                uint256(1 days),
                uint256(10 days)
            )
        );
        IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 12 hours);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                EdenLendingFacet.BelowMinimumTier.selector, uint256(1), uint256(0.5e18)
            )
        );
        IEdenLendingFacet(address(diamond)).borrow{ value: 0 }(1, 0.5e18, 2 days);

        LendingHarnessFacet(address(diamond)).setVaultBalance(1, address(eve), 350e18);
        LendingHarnessFacet(address(diamond)).setVaultBalance(1, address(alt), 175e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                EdenLendingFacet.RedeemabilityInvariantBroken.selector,
                address(eve),
                uint256(300e18),
                uint256(250e18)
            )
        );
        IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 2 days);
    }

    function test_LendingPreviews_ReturnExpectedBorrowRepayAndExtendShapes() public {
        IEdenLendingFacet.BorrowPreview memory borrowPreview =
            IEdenLendingFacet(address(diamond)).previewBorrow(1, 2 * UNIT, 3 days);
        assertEq(borrowPreview.basketId, 1);
        assertEq(borrowPreview.collateralUnits, 2 * UNIT);
        assertEq(borrowPreview.duration, 3 days);
        assertEq(borrowPreview.assets.length, 2);
        assertEq(borrowPreview.assets[0], address(eve));
        assertEq(borrowPreview.assets[1], address(alt));
        assertEq(borrowPreview.principals[0], 200e18);
        assertEq(borrowPreview.principals[1], 100e18);
        assertEq(borrowPreview.feeNative, 0.02 ether);
        assertEq(borrowPreview.maturity, uint40(block.timestamp + 3 days));
        assertEq(borrowPreview.resultingLockedCollateral, 2 * UNIT);
        assertTrue(borrowPreview.invariantSatisfied);

        vm.prank(alice);
        uint256 loanId =
            IEdenLendingFacet(address(diamond)).borrow{ value: 0.02 ether }(1, 2 * UNIT, 3 days);

        IEdenLendingFacet.RepayPreview memory repayPreview =
            IEdenLendingFacet(address(diamond)).previewRepay(loanId);
        assertEq(repayPreview.loanId, loanId);
        assertEq(repayPreview.assets.length, 2);
        assertEq(repayPreview.principals[0], 200e18);
        assertEq(repayPreview.principals[1], 100e18);
        assertEq(repayPreview.unlockedCollateralUnits, 2 * UNIT);

        IEdenLendingFacet.ExtendPreview memory extendPreview =
            IEdenLendingFacet(address(diamond)).previewExtend(loanId, 3 days);
        assertEq(extendPreview.loanId, loanId);
        assertEq(extendPreview.addedDuration, 3 days);
        assertEq(
            extendPreview.newMaturity,
            LendingHarnessFacet(address(diamond)).getLoan(loanId).maturity + 3 days
        );
        assertEq(extendPreview.feeNative, 0.02 ether);
    }

    function test_Repay_UnlocksCollateralAndPreservesLoanHistory() public {
        vm.prank(alice);
        uint256 loanId =
            IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 2 days);

        vm.warp(block.timestamp + 1);

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        alt.approve(address(diamond), type(uint256).max);
        IEdenLendingFacet(address(diamond)).repay(loanId);
        vm.stopPrank();

        LibLendingStorage.Loan memory loan = LendingHarnessFacet(address(diamond)).getLoan(loanId);
        assertEq(loan.borrower, alice);
        assertEq(loan.basketId, 1);
        assertEq(loan.collateralUnits, UNIT);
        assertEq(indexToken.balanceOf(alice), 2 * UNIT);
        assertEq(indexToken.balanceOf(address(diamond)), 0);
        assertEq(LendingHarnessFacet(address(diamond)).getLockedCollateral(1), 0);
        assertEq(LendingHarnessFacet(address(diamond)).getOutstandingPrincipal(1, address(eve)), 0);
        assertEq(LendingHarnessFacet(address(diamond)).getOutstandingPrincipal(1, address(alt)), 0);
        assertEq(LendingHarnessFacet(address(diamond)).getVaultBalance(1, address(eve)), 400e18);
        assertEq(LendingHarnessFacet(address(diamond)).getVaultBalance(1, address(alt)), 200e18);
        assertTrue(LendingHarnessFacet(address(diamond)).getLoanClosed(loanId));
        assertEq(LendingHarnessFacet(address(diamond)).getLoanClosedAt(loanId), block.timestamp);
        assertEq(LendingHarnessFacet(address(diamond)).getLoanCloseReason(loanId), 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EdenLendingFacet.LoanNotFound.selector, loanId));
        IEdenLendingFacet(address(diamond)).repay(loanId);
    }

    function test_Repay_StEVEUnlocksRewardLedgerAndBorrowerOnly() public {
        vm.prank(alice);
        uint256 loanId =
            IEdenLendingFacet(address(diamond)).borrow{ value: 0.1 ether }(0, UNIT, 2 days);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EdenLendingFacet.NotBorrower.selector, bob, alice));
        IEdenLendingFacet(address(diamond)).repay(loanId);

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        IEdenLendingFacet(address(diamond)).repay(loanId);
        vm.stopPrank();

        assertEq(stEveToken.balanceOf(alice), 2 * UNIT);
        assertEq(LendingHarnessFacet(address(diamond)).getLiquidBalance(alice), 2 * UNIT);
        assertEq(LendingHarnessFacet(address(diamond)).getLockedBalance(alice), 0);
        assertEq(LendingHarnessFacet(address(diamond)).getEffectiveBalance(alice), 2 * UNIT);
        assertEq(LendingHarnessFacet(address(diamond)).getLiquidBalance(address(diamond)), 0);
    }

    function test_Extend_UpdatesMaturityChargesFeeAndRejectsInvalidCases() public {
        vm.prank(alice);
        uint256 loanId =
            IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 2 days);

        LibLendingStorage.Loan memory beforeLoan =
            LendingHarnessFacet(address(diamond)).getLoan(loanId);
        uint256 treasuryBefore = treasury.balance;

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        IEdenLendingFacet(address(diamond)).extend{ value: 0.2 ether }(loanId, 3 days);

        LibLendingStorage.Loan memory afterLoan =
            LendingHarnessFacet(address(diamond)).getLoan(loanId);
        assertEq(afterLoan.maturity, beforeLoan.maturity + 3 days);
        assertEq(treasury.balance - treasuryBefore, 0.2 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                EdenLendingFacet.InvalidDuration.selector,
                uint256(10 days),
                uint256(1 days),
                uint256(10 days)
            )
        );
        IEdenLendingFacet(address(diamond)).extend{ value: 0.2 ether }(loanId, 10 days);

        vm.warp(uint256(afterLoan.maturity) + 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                EdenLendingFacet.LoanExpired.selector, loanId, afterLoan.maturity
            )
        );
        IEdenLendingFacet(address(diamond)).extend{ value: 0.2 ether }(loanId, 1 days);
    }

    function test_RecoverExpired_BurnsCollateralWritesOffAndStopsStEVERewards() public {
        vm.prank(alice);
        uint256 loanId =
            IEdenLendingFacet(address(diamond)).borrow{ value: 0.1 ether }(0, UNIT, 2 days);

        LibLendingStorage.Loan memory loan = LendingHarnessFacet(address(diamond)).getLoan(loanId);

        vm.expectRevert(
            abi.encodeWithSelector(EdenLendingFacet.LoanNotExpired.selector, loanId, loan.maturity)
        );
        IEdenLendingFacet(address(diamond)).recoverExpired(loanId);

        vm.warp(uint256(loan.maturity) + 1);
        IEdenLendingFacet(address(diamond)).recoverExpired(loanId);

        LibLendingStorage.Loan memory closedLoan =
            LendingHarnessFacet(address(diamond)).getLoan(loanId);
        assertEq(closedLoan.borrower, alice);
        assertEq(closedLoan.basketId, 0);
        assertEq(closedLoan.collateralUnits, UNIT);
        assertEq(stEveToken.totalSupply(), 2 * UNIT);
        assertEq(stEveToken.balanceOf(address(diamond)), 0);
        assertEq(LendingHarnessFacet(address(diamond)).getBasketTotalUnits(0), 2 * UNIT);
        assertEq(LendingHarnessFacet(address(diamond)).getLockedCollateral(0), 0);
        assertEq(LendingHarnessFacet(address(diamond)).getOutstandingPrincipal(0, address(eve)), 0);
        assertEq(LendingHarnessFacet(address(diamond)).getVaultBalance(0, address(eve)), 2_000e18);
        assertEq(LendingHarnessFacet(address(diamond)).getLockedBalance(alice), 0);
        assertEq(LendingHarnessFacet(address(diamond)).getEffectiveBalance(alice), UNIT);
        assertTrue(LendingHarnessFacet(address(diamond)).getLoanClosed(loanId));
        assertEq(LendingHarnessFacet(address(diamond)).getLoanClosedAt(loanId), block.timestamp);
        assertEq(LendingHarnessFacet(address(diamond)).getLoanCloseReason(loanId), 2);

        uint256 redeemableSupply = LendingHarnessFacet(address(diamond)).getBasketTotalUnits(0);
        assertEq(
            LendingHarnessFacet(address(diamond)).getVaultBalance(0, address(eve)),
            redeemableSupply * STEVE_BUNDLE / UNIT
        );

        vm.expectRevert(abi.encodeWithSelector(EdenLendingFacet.LoanNotFound.selector, loanId));
        IEdenLendingFacet(address(diamond)).recoverExpired(loanId);
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        bytes4[] memory selectors = new bytes4[](35);
        selectors[0] = IEdenLendingFacet.borrow.selector;
        selectors[1] = IEdenLendingFacet.repay.selector;
        selectors[2] = IEdenLendingFacet.extend.selector;
        selectors[3] = IEdenLendingFacet.recoverExpired.selector;
        selectors[4] = IEdenLendingFacet.configureLending.selector;
        selectors[5] = IEdenLendingFacet.configureBorrowFeeTiers.selector;
        selectors[6] = IEdenLendingFacet.loanCount.selector;
        selectors[7] = IEdenLendingFacet.borrowerLoanCount.selector;
        selectors[8] = IEdenLendingFacet.getLoanView.selector;
        selectors[9] = IEdenLendingFacet.getLoanIdsByBorrower.selector;
        selectors[10] = IEdenLendingFacet.getActiveLoanIdsByBorrower.selector;
        selectors[11] = IEdenLendingFacet.getLoansByBorrower.selector;
        selectors[12] = IEdenLendingFacet.getActiveLoansByBorrower.selector;
        selectors[13] = IEdenLendingFacet.getLoanIdsByBorrowerPaginated.selector;
        selectors[14] = IEdenLendingFacet.getActiveLoanIdsByBorrowerPaginated.selector;
        selectors[15] = IEdenLendingFacet.previewBorrow.selector;
        selectors[16] = IEdenLendingFacet.previewRepay.selector;
        selectors[17] = IEdenLendingFacet.previewExtend.selector;
        selectors[18] = IEdenStEVEFacet.onStEVETransfer.selector;
        selectors[19] = LendingHarnessFacet.setTreasury.selector;
        selectors[20] = LendingHarnessFacet.setBasket.selector;
        selectors[21] = LendingHarnessFacet.mintReceiptUnits.selector;
        selectors[22] = LendingHarnessFacet.setVaultBalance.selector;
        selectors[23] = LendingHarnessFacet.getLoan.selector;
        selectors[24] = LendingHarnessFacet.getLockedCollateral.selector;
        selectors[25] = LendingHarnessFacet.getOutstandingPrincipal.selector;
        selectors[26] = LendingHarnessFacet.getBorrowFeeTier.selector;
        selectors[27] = LendingHarnessFacet.getBorrowFeeTierCount.selector;
        selectors[28] = LendingHarnessFacet.getLiquidBalance.selector;
        selectors[29] = LendingHarnessFacet.getLockedBalance.selector;
        selectors[30] = LendingHarnessFacet.getBorrowerLoanIds.selector;
        selectors[31] = LendingHarnessFacet.getLoanClosed.selector;
        selectors[32] = LendingHarnessFacet.getLoanClosedAt.selector;
        selectors[33] = LendingHarnessFacet.getLoanCloseReason.selector;
        selectors[34] = LendingHarnessFacet.getLoanCreatedAt.selector;

        bytes4[] memory extras = new bytes4[](3);
        extras[0] = LendingHarnessFacet.getEffectiveBalance.selector;
        extras[1] = LendingHarnessFacet.getBasketTotalUnits.selector;
        extras[2] = LendingHarnessFacet.getVaultBalance.selector;

        bytes4[] memory allSelectors = new bytes4[](selectors.length + extras.length);
        for (uint256 i = 0; i < selectors.length; i++) {
            allSelectors[i] = selectors[i];
        }
        for (uint256 i = 0; i < extras.length; i++) {
            allSelectors[selectors.length + i] = extras[i];
        }

        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(lendingFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: allSelectors
        });
    }
}
