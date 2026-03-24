// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";
import { EdenLendingFacet } from "src/facets/EdenLendingFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenCoreFacet } from "src/interfaces/IEdenCoreFacet.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";
import { StEVEToken } from "src/tokens/StEVEToken.sol";

contract BasketTrackingMockERC20 is ERC20 {
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

contract BasketTrackingViewHarnessFacet {
    function setTreasury(
        address treasury
    ) external {
        LibEdenStorage.layout().treasury = treasury;
    }

    function userBasketCount(
        address user
    ) external view returns (uint256) {
        return LibEdenStorage.layout().userBasketIds[user].length;
    }

    function getUserBasketIds(
        address user
    ) external view returns (uint256[] memory) {
        return LibEdenStorage.layout().userBasketIds[user];
    }

    function getUserBasketIdsPaginated(
        address user,
        uint256 start,
        uint256 limit
    ) external view returns (uint256[] memory basketIds) {
        uint256[] storage storedBasketIds = LibEdenStorage.layout().userBasketIds[user];
        uint256 len = storedBasketIds.length;
        if (start >= len || limit == 0) {
            return new uint256[](0);
        }

        uint256 remaining = len - start;
        uint256 resultLen = remaining < limit ? remaining : limit;
        basketIds = new uint256[](resultLen);
        for (uint256 i = 0; i < resultLen; i++) {
            basketIds[i] = storedBasketIds[start + i];
        }
    }

    function userHasBasket(
        address user,
        uint256 basketId
    ) external view returns (bool) {
        return LibEdenStorage.layout().userHasBasket[user][basketId];
    }
}

contract UserBasketTrackingTest is Test {
    uint256 internal constant UNIT = 1e18;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    EdenDiamond internal diamond;
    EdenCoreFacet internal coreFacet;
    EdenLendingFacet internal lendingFacet;
    BasketTrackingViewHarnessFacet internal viewFacet;
    BasketTrackingMockERC20 internal eve;
    BasketTrackingMockERC20 internal alt;
    BasketTrackingMockERC20 internal gamma;
    StEVEToken internal stEveToken;
    BasketToken internal basketOneToken;
    BasketToken internal basketTwoToken;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        coreFacet = new EdenCoreFacet();
        lendingFacet = new EdenLendingFacet();
        viewFacet = new BasketTrackingViewHarnessFacet();
        eve = new BasketTrackingMockERC20("EVE", "EVE");
        alt = new BasketTrackingMockERC20("ALT", "ALT");
        gamma = new BasketTrackingMockERC20("GAMMA", "GAMMA");

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");

        BasketTrackingViewHarnessFacet(address(diamond)).setTreasury(treasury);

        vm.startPrank(owner);
        (, address stEveTokenAddress) = IEdenCoreFacet(address(diamond)).createBasket(
            _basketParams("stEVE", "stEVE", address(eve), 100e18)
        );
        (, address basketOneTokenAddress) = IEdenCoreFacet(address(diamond)).createBasket(
            _basketParams("Basket One", "B1", address(alt), 50e18)
        );
        (, address basketTwoTokenAddress) = IEdenCoreFacet(address(diamond)).createBasket(
            _basketParams("Basket Two", "B2", address(gamma), 25e18)
        );
        IEdenLendingFacet(address(diamond)).configureLending(1, 1 days, 7 days);
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(
            1, _singleUintArray(UNIT), _singleUintArray(0.01 ether)
        );
        vm.stopPrank();

        stEveToken = StEVEToken(stEveTokenAddress);
        basketOneToken = BasketToken(basketOneTokenAddress);
        basketTwoToken = BasketToken(basketTwoTokenAddress);

        eve.mint(alice, 1_000e18);
        alt.mint(alice, 1_000e18);
        gamma.mint(alice, 1_000e18);
        vm.deal(alice, 10 ether);

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        alt.approve(address(diamond), type(uint256).max);
        gamma.approve(address(diamond), type(uint256).max);
        basketOneToken.approve(address(diamond), type(uint256).max);
        vm.stopPrank();
    }

    function test_UserBasketIds_UpdatedOnFirstMintWithoutDuplicates() public {
        vm.startPrank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);
        vm.stopPrank();

        uint256[] memory basketIds =
            BasketTrackingViewHarnessFacet(address(diamond)).getUserBasketIds(alice);
        assertEq(basketIds.length, 1);
        assertEq(basketIds[0], 1);
        assertEq(BasketTrackingViewHarnessFacet(address(diamond)).userBasketCount(alice), 1);
        assertTrue(BasketTrackingViewHarnessFacet(address(diamond)).userHasBasket(alice, 1));
    }

    function test_UserBasketIds_RemovedOnFullBurnWithoutLockedCollateral() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);

        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).burn(1, UNIT, alice);

        uint256[] memory basketIds =
            BasketTrackingViewHarnessFacet(address(diamond)).getUserBasketIds(alice);
        assertEq(basketIds.length, 0);
        assertEq(BasketTrackingViewHarnessFacet(address(diamond)).userBasketCount(alice), 0);
        assertFalse(BasketTrackingViewHarnessFacet(address(diamond)).userHasBasket(alice, 1));
        assertEq(basketOneToken.balanceOf(alice), 0);
    }

    function test_UserBasketIds_UpdatedOnTransferForSenderAndReceiver() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);

        vm.prank(alice);
        basketOneToken.transfer(bob, UNIT);

        uint256[] memory aliceBasketIds =
            BasketTrackingViewHarnessFacet(address(diamond)).getUserBasketIds(alice);
        uint256[] memory bobBasketIds =
            BasketTrackingViewHarnessFacet(address(diamond)).getUserBasketIds(bob);

        assertEq(aliceBasketIds.length, 0);
        assertFalse(BasketTrackingViewHarnessFacet(address(diamond)).userHasBasket(alice, 1));
        assertEq(bobBasketIds.length, 1);
        assertEq(bobBasketIds[0], 1);
        assertTrue(BasketTrackingViewHarnessFacet(address(diamond)).userHasBasket(bob, 1));
    }

    function test_GetUserBasketIds_AndPaginationReflectTrackedStorage() public {
        vm.startPrank(alice);
        IEdenCoreFacet(address(diamond)).mint(0, UNIT, alice);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);
        IEdenCoreFacet(address(diamond)).mint(2, UNIT, alice);
        vm.stopPrank();

        uint256[] memory basketIds =
            BasketTrackingViewHarnessFacet(address(diamond)).getUserBasketIds(alice);
        assertEq(basketIds.length, 3);
        assertEq(basketIds[0], 0);
        assertEq(basketIds[1], 1);
        assertEq(basketIds[2], 2);

        uint256[] memory firstPage =
            BasketTrackingViewHarnessFacet(address(diamond)).getUserBasketIdsPaginated(alice, 0, 2);
        assertEq(firstPage.length, 2);
        assertEq(firstPage[0], 0);
        assertEq(firstPage[1], 1);

        uint256[] memory secondPage =
            BasketTrackingViewHarnessFacet(address(diamond)).getUserBasketIdsPaginated(alice, 1, 2);
        assertEq(secondPage.length, 2);
        assertEq(secondPage[0], 1);
        assertEq(secondPage[1], 2);

        uint256[] memory tailPage =
            BasketTrackingViewHarnessFacet(address(diamond)).getUserBasketIdsPaginated(alice, 2, 2);
        assertEq(tailPage.length, 1);
        assertEq(tailPage[0], 2);

        uint256[] memory emptyPage =
            BasketTrackingViewHarnessFacet(address(diamond)).getUserBasketIdsPaginated(alice, 5, 1);
        assertEq(emptyPage.length, 0);
    }

    function test_UserBasketIds_RetainBasketWhileCollateralIsLocked() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);

        vm.prank(alice);
        IEdenLendingFacet(address(diamond)).borrow{ value: 0.01 ether }(1, 2 * UNIT, 2 days);

        uint256[] memory basketIds =
            BasketTrackingViewHarnessFacet(address(diamond)).getUserBasketIds(alice);
        assertEq(basketOneToken.balanceOf(alice), 0);
        assertEq(basketIds.length, 1);
        assertEq(basketIds[0], 1);
        assertTrue(BasketTrackingViewHarnessFacet(address(diamond)).userHasBasket(alice, 1));
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](3);

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

        bytes4[] memory lendingSelectors = new bytes4[](5);
        lendingSelectors[0] = IEdenLendingFacet.configureLending.selector;
        lendingSelectors[1] = IEdenLendingFacet.configureBorrowFeeTiers.selector;
        lendingSelectors[2] = IEdenLendingFacet.borrow.selector;
        lendingSelectors[3] = IEdenLendingFacet.repay.selector;
        lendingSelectors[4] = IEdenStEVEFacet.onStEVETransfer.selector;
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(lendingFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: lendingSelectors
        });

        bytes4[] memory viewSelectors = new bytes4[](5);
        viewSelectors[0] = BasketTrackingViewHarnessFacet.setTreasury.selector;
        viewSelectors[1] = BasketTrackingViewHarnessFacet.userBasketCount.selector;
        viewSelectors[2] = BasketTrackingViewHarnessFacet.getUserBasketIds.selector;
        viewSelectors[3] = BasketTrackingViewHarnessFacet.getUserBasketIdsPaginated.selector;
        viewSelectors[4] = BasketTrackingViewHarnessFacet.userHasBasket.selector;
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(viewFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: viewSelectors
        });
    }

    function _basketParams(
        string memory name_,
        string memory symbol_,
        address asset,
        uint256 bundleAmount
    ) internal pure returns (IEdenCoreFacet.CreateBasketParams memory params) {
        params = IEdenCoreFacet.CreateBasketParams({
            name: name_,
            symbol: symbol_,
            assets: _singleAddressArray(asset),
            bundleAmounts: _singleUintArray(bundleAmount),
            mintFeeBps: _singleUint16Array(0),
            burnFeeBps: _singleUint16Array(0),
            flashFeeBps: 0
        });
    }

    function _singleAddressArray(
        address value
    ) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleUintArray(
        uint256 value
    ) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _singleUint16Array(
        uint16 value
    ) internal pure returns (uint16[] memory values) {
        values = new uint16[](1);
        values[0] = value;
    }
}
