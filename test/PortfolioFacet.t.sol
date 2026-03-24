// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";
import { EdenLendingFacet } from "src/facets/EdenLendingFacet.sol";
import { EdenPortfolioFacet } from "src/facets/EdenPortfolioFacet.sol";
import { EdenViewFacet } from "src/facets/EdenViewFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenCoreFacet } from "src/interfaces/IEdenCoreFacet.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { IEdenPortfolioFacet } from "src/interfaces/IEdenPortfolioFacet.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { IEdenViewFacet } from "src/interfaces/IEdenViewFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";
import { StEVEToken } from "src/tokens/StEVEToken.sol";

contract PortfolioMockERC20 is ERC20 {
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

contract PortfolioHarnessFacet is EdenPortfolioFacet {
    function setTreasury(
        address treasury
    ) external {
        LibEdenStorage.layout().treasury = treasury;
    }
}

contract PortfolioFacetTest is Test {
    uint256 internal constant UNIT = 1e18;
    uint256 internal constant BASE_REWARD = 50e18;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    EdenDiamond internal diamond;
    EdenCoreFacet internal coreFacet;
    EdenLendingFacet internal lendingFacet;
    EdenViewFacet internal viewFacet;
    PortfolioHarnessFacet internal portfolioFacet;
    PortfolioMockERC20 internal eve;
    PortfolioMockERC20 internal alt;
    StEVEToken internal stEveToken;
    BasketToken internal basketToken;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        coreFacet = new EdenCoreFacet();
        lendingFacet = new EdenLendingFacet();
        viewFacet = new EdenViewFacet();
        portfolioFacet = new PortfolioHarnessFacet();
        eve = new PortfolioMockERC20("EVE", "EVE");
        alt = new PortfolioMockERC20("ALT", "ALT");

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");
        PortfolioHarnessFacet(address(diamond)).setTreasury(treasury);

        eve.mint(owner, 20_000e18);
        eve.mint(alice, 20_000e18);
        alt.mint(alice, 20_000e18);
        vm.deal(alice, 10 ether);

        vm.startPrank(owner);
        (, address stEveTokenAddress) = IEdenCoreFacet(address(diamond)).createBasket(
            _basketParams("stEVE", "stEVE", _singleAddressArray(address(eve)), _singleUintArray(1_000e18))
        );
        (, address basketTokenAddress) = IEdenCoreFacet(address(diamond)).createBasket(
            _basketParams(
                "Index Basket",
                "BASK",
                _doubleAddressArray(address(eve), address(alt)),
                _doubleUintArray(100e18, 50e18)
            )
        );
        IEdenLendingFacet(address(diamond)).configureLending(0, 1 days, 7 days);
        IEdenLendingFacet(address(diamond)).configureLending(1, 1 days, 7 days);
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(
            0, _singleUintArray(UNIT), _singleUintArray(0.01 ether)
        );
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(
            1, _singleUintArray(UNIT), _singleUintArray(0.01 ether)
        );
        IEdenStEVEFacet(address(diamond)).configureRewards(
            block.timestamp, 1 days, 30, 2, BASE_REWARD, 10, BASE_REWARD
        );
        eve.approve(address(diamond), type(uint256).max);
        IEdenStEVEFacet(address(diamond)).fundRewards(500e18);
        vm.stopPrank();

        stEveToken = StEVEToken(stEveTokenAddress);
        basketToken = BasketToken(basketTokenAddress);

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        alt.approve(address(diamond), type(uint256).max);
        IEdenCoreFacet(address(diamond)).mint(0, 3 * UNIT, alice);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);
        stEveToken.approve(address(diamond), type(uint256).max);
        basketToken.approve(address(diamond), type(uint256).max);
        IEdenLendingFacet(address(diamond)).borrow{ value: 0.01 ether }(0, UNIT, 2 days);
        IEdenLendingFacet(address(diamond)).borrow{ value: 0.01 ether }(1, UNIT, 2 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days + 1);
    }

    function test_UserBasketIdViews_ReturnTrackedIdsAndPagination() public {
        assertEq(IEdenPortfolioFacet(address(diamond)).userBasketCount(alice), 2);

        uint256[] memory basketIds = IEdenPortfolioFacet(address(diamond)).getUserBasketIds(alice);
        assertEq(basketIds.length, 2);
        assertEq(basketIds[0], 0);
        assertEq(basketIds[1], 1);

        uint256[] memory firstPage =
            IEdenPortfolioFacet(address(diamond)).getUserBasketIdsPaginated(alice, 0, 1);
        assertEq(firstPage.length, 1);
        assertEq(firstPage[0], 0);

        uint256[] memory secondPage =
            IEdenPortfolioFacet(address(diamond)).getUserBasketIdsPaginated(alice, 1, 2);
        assertEq(secondPage.length, 1);
        assertEq(secondPage[0], 1);

        uint256[] memory emptyPage =
            IEdenPortfolioFacet(address(diamond)).getUserBasketIdsPaginated(alice, 3, 1);
        assertEq(emptyPage.length, 0);
    }

    function test_UserBasketPosition_ComputesUnitsNavAndRedeemableUnderlying() public {
        IEdenPortfolioFacet.UserBasketPosition memory stEvePosition =
            IEdenPortfolioFacet(address(diamond)).getUserBasketPosition(alice, 0);
        assertEq(stEvePosition.walletUnits, stEveToken.balanceOf(alice));
        assertEq(stEvePosition.lockedUnits, UNIT);
        assertEq(stEvePosition.totalUnits, stEvePosition.walletUnits + stEvePosition.lockedUnits);
        assertEq(
            stEvePosition.nav,
            IEdenViewFacet(address(diamond)).nav(0) * stEvePosition.totalUnits / UNIT
        );

        IEdenPortfolioFacet.UserBasketPosition memory basketPosition =
            IEdenPortfolioFacet(address(diamond)).getUserBasketPosition(alice, 1);
        assertEq(basketPosition.basketId, 1);
        assertEq(basketPosition.token, address(basketToken));
        assertEq(basketPosition.walletUnits, basketToken.balanceOf(alice));
        assertEq(basketPosition.walletUnits, UNIT);
        assertEq(basketPosition.lockedUnits, UNIT);
        assertEq(basketPosition.totalUnits, 2 * UNIT);
        assertEq(basketPosition.assets.length, 2);
        assertEq(basketPosition.assets[0], address(eve));
        assertEq(basketPosition.assets[1], address(alt));
        assertEq(basketPosition.bundleAmounts[0], 100e18);
        assertEq(basketPosition.bundleAmounts[1], 50e18);
        assertEq(basketPosition.feePotShare[0], 0);
        assertEq(basketPosition.feePotShare[1], 0);

        (, uint256[] memory previewReturned,) = IEdenViewFacet(address(diamond)).previewBurn(1, UNIT);
        assertEq(basketPosition.redeemableUnderlying.length, 2);
        assertEq(basketPosition.redeemableUnderlying[0], previewReturned[0]);
        assertEq(basketPosition.redeemableUnderlying[1], previewReturned[1]);
    }

    function test_GetUserBasketPositions_MatchesPerBasketQueries() public {
        uint256[] memory basketIds = IEdenPortfolioFacet(address(diamond)).getUserBasketIds(alice);
        IEdenPortfolioFacet.UserBasketPosition[] memory positions =
            IEdenPortfolioFacet(address(diamond)).getUserBasketPositions(alice, basketIds);

        assertEq(positions.length, basketIds.length);
        for (uint256 i = 0; i < basketIds.length; i++) {
            IEdenPortfolioFacet.UserBasketPosition memory single =
                IEdenPortfolioFacet(address(diamond)).getUserBasketPosition(alice, basketIds[i]);
            assertEq(positions[i].basketId, single.basketId);
            assertEq(positions[i].token, single.token);
            assertEq(positions[i].walletUnits, single.walletUnits);
            assertEq(positions[i].lockedUnits, single.lockedUnits);
            assertEq(positions[i].totalUnits, single.totalUnits);
            assertEq(positions[i].nav, single.nav);
            assertEq(positions[i].redeemableUnderlying.length, single.redeemableUnderlying.length);

            for (uint256 j = 0; j < single.redeemableUnderlying.length; j++) {
                assertEq(positions[i].redeemableUnderlying[j], single.redeemableUnderlying[j]);
                assertEq(positions[i].feePotShare[j], single.feePotShare[j]);
            }
        }
    }

    function test_GetUserPortfolio_AggregatesRewardsBasketsAndLoans() public {
        IEdenPortfolioFacet.UserPortfolio memory portfolio =
            IEdenPortfolioFacet(address(diamond)).getUserPortfolio(alice);

        uint256[] memory basketIds = IEdenPortfolioFacet(address(diamond)).getUserBasketIds(alice);
        uint256[] memory loanIds = IEdenLendingFacet(address(diamond)).getLoanIdsByBorrower(alice);

        assertEq(portfolio.user, alice);
        assertEq(portfolio.eveBalance, eve.balanceOf(alice));
        assertEq(portfolio.claimableRewards, IEdenStEVEFacet(address(diamond)).claimableRewards(alice));
        assertEq(portfolio.stEveBalance, stEveToken.balanceOf(alice));
        assertEq(portfolio.stEveLocked, UNIT);
        assertEq(portfolio.basketCount, basketIds.length);
        assertEq(portfolio.loanCount, loanIds.length);
        assertEq(portfolio.baskets.length, basketIds.length);
        assertEq(portfolio.loans.length, loanIds.length);

        for (uint256 i = 0; i < basketIds.length; i++) {
            IEdenPortfolioFacet.UserBasketPosition memory single =
                IEdenPortfolioFacet(address(diamond)).getUserBasketPosition(alice, basketIds[i]);
            assertEq(portfolio.baskets[i].basketId, single.basketId);
            assertEq(portfolio.baskets[i].walletUnits, single.walletUnits);
            assertEq(portfolio.baskets[i].lockedUnits, single.lockedUnits);
            assertEq(portfolio.baskets[i].totalUnits, single.totalUnits);
        }

        for (uint256 i = 0; i < loanIds.length; i++) {
            IEdenLendingFacet.LoanView memory singleLoan =
                IEdenLendingFacet(address(diamond)).getLoanView(loanIds[i]);
            assertEq(portfolio.loans[i].loanId, singleLoan.loanId);
            assertEq(portfolio.loans[i].basketId, singleLoan.basketId);
            assertEq(portfolio.loans[i].collateralUnits, singleLoan.collateralUnits);
        }
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](4);

        bytes4[] memory coreSelectors = new bytes4[](4);
        coreSelectors[0] = IEdenCoreFacet.createBasket.selector;
        coreSelectors[1] = IEdenCoreFacet.mint.selector;
        coreSelectors[2] = IEdenCoreFacet.burn.selector;
        coreSelectors[3] = IEdenCoreFacet.onBasketTokenTransfer.selector;
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(coreFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: coreSelectors
        });

        bytes4[] memory lendingSelectors = new bytes4[](10);
        lendingSelectors[0] = IEdenLendingFacet.configureLending.selector;
        lendingSelectors[1] = IEdenLendingFacet.configureBorrowFeeTiers.selector;
        lendingSelectors[2] = IEdenLendingFacet.borrow.selector;
        lendingSelectors[3] = IEdenLendingFacet.repay.selector;
        lendingSelectors[4] = IEdenLendingFacet.getLoanView.selector;
        lendingSelectors[5] = IEdenLendingFacet.getLoanIdsByBorrower.selector;
        lendingSelectors[6] = IEdenStEVEFacet.onStEVETransfer.selector;
        lendingSelectors[7] = IEdenStEVEFacet.configureRewards.selector;
        lendingSelectors[8] = IEdenStEVEFacet.fundRewards.selector;
        lendingSelectors[9] = IEdenStEVEFacet.claimableRewards.selector;
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(lendingFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: lendingSelectors
        });

        bytes4[] memory viewSelectors = new bytes4[](2);
        viewSelectors[0] = IEdenViewFacet.nav.selector;
        viewSelectors[1] = IEdenViewFacet.previewBurn.selector;
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(viewFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: viewSelectors
        });

        bytes4[] memory portfolioSelectors = new bytes4[](7);
        portfolioSelectors[0] = PortfolioHarnessFacet.setTreasury.selector;
        portfolioSelectors[1] = IEdenPortfolioFacet.userBasketCount.selector;
        portfolioSelectors[2] = IEdenPortfolioFacet.getUserBasketIds.selector;
        portfolioSelectors[3] = IEdenPortfolioFacet.getUserBasketIdsPaginated.selector;
        portfolioSelectors[4] = IEdenPortfolioFacet.getUserBasketPosition.selector;
        portfolioSelectors[5] = IEdenPortfolioFacet.getUserBasketPositions.selector;
        portfolioSelectors[6] = IEdenPortfolioFacet.getUserPortfolio.selector;
        cuts[3] = IDiamondCut.FacetCut({
            facetAddress: address(portfolioFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: portfolioSelectors
        });
    }

    function _basketParams(
        string memory name_,
        string memory symbol_,
        address[] memory assets,
        uint256[] memory bundleAmounts
    ) internal pure returns (IEdenCoreFacet.CreateBasketParams memory params) {
        params = IEdenCoreFacet.CreateBasketParams({
            name: name_,
            symbol: symbol_,
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeBps: _zeroUint16Array(assets.length),
            burnFeeBps: _zeroUint16Array(assets.length),
            flashFeeBps: 0
        });
    }

    function _singleAddressArray(
        address value
    ) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _doubleAddressArray(
        address a0,
        address a1
    ) internal pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = a0;
        values[1] = a1;
    }

    function _singleUintArray(
        uint256 value
    ) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _doubleUintArray(
        uint256 v0,
        uint256 v1
    ) internal pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = v0;
        values[1] = v1;
    }

    function _zeroUint16Array(
        uint256 len
    ) internal pure returns (uint16[] memory values) {
        values = new uint16[](len);
    }
}
