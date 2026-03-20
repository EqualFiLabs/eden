// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenViewFacet } from "src/facets/EdenViewFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenViewFacet } from "src/interfaces/IEdenViewFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";

contract ViewHarnessFacet is EdenViewFacet {
    function setBasket(
        uint256 basketId,
        address token,
        address[] calldata assets,
        uint256[] calldata bundleAmounts,
        uint16[] calldata mintFeeBps,
        uint16[] calldata burnFeeBps,
        uint16 flashFeeBps,
        uint256 totalUnits
    ) external {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        if (basketId >= store.basketCount) {
            store.basketCount = basketId + 1;
        }

        LibEdenStorage.Basket storage basket = store.baskets[basketId];
        delete basket.assets;
        delete basket.bundleAmounts;
        delete basket.mintFeeBps;
        delete basket.burnFeeBps;
        basket.token = token;
        basket.flashFeeBps = flashFeeBps;
        basket.totalUnits = totalUnits;
        basket.paused = false;

        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            basket.assets.push(assets[i]);
            basket.bundleAmounts.push(bundleAmounts[i]);
            basket.mintFeeBps.push(mintFeeBps[i]);
            basket.burnFeeBps.push(burnFeeBps[i]);
        }
    }

    function setVaultBalance(
        uint256 basketId,
        address asset,
        uint256 amount
    ) external {
        LibEdenStorage.layout().vaultBalances[basketId][asset] = amount;
    }

    function setFeePot(
        uint256 basketId,
        address asset,
        uint256 amount
    ) external {
        LibEdenStorage.layout().feePots[basketId][asset] = amount;
    }

    function setOutstandingPrincipal(
        uint256 basketId,
        address asset,
        uint256 amount
    ) external {
        LibLendingStorage.layout().outstandingPrincipal[basketId][asset] = amount;
    }

    function setLockedCollateral(
        uint256 basketId,
        uint256 amount
    ) external {
        LibLendingStorage.layout().lockedCollateralUnits[basketId] = amount;
    }

    function setLoan(
        uint256 loanId,
        address borrower,
        uint256 basketId,
        uint256 collateralUnits,
        uint16 ltvBps,
        uint40 maturity
    ) external {
        LibLendingStorage.layout().loans[loanId] = LibLendingStorage.Loan({
            borrower: borrower,
            basketId: basketId,
            collateralUnits: collateralUnits,
            ltvBps: ltvBps,
            maturity: maturity
        });
    }

    function setBorrowFeeTiers(
        uint256 basketId,
        uint256[] calldata minCollateralUnits,
        uint256[] calldata flatFeeNative
    ) external {
        LibLendingStorage.BorrowFeeTier[] storage tiers =
            LibLendingStorage.layout().borrowFeeTiers[basketId];
        while (tiers.length > 0) {
            tiers.pop();
        }

        uint256 len = minCollateralUnits.length;
        for (uint256 i = 0; i < len; i++) {
            tiers.push(
                LibLendingStorage.BorrowFeeTier({
                    minCollateralUnits: minCollateralUnits[i], flatFeeNative: flatFeeNative[i]
                })
            );
        }
    }
}

contract ViewFacetTest is Test {
    uint256 internal constant UNIT = 1e18;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal alice = makeAddr("alice");

    EdenDiamond internal diamond;
    ViewHarnessFacet internal viewFacet;
    BasketToken internal singleToken;
    BasketToken internal multiToken;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        viewFacet = new ViewHarnessFacet();
        singleToken = new BasketToken("Single", "SGL", address(diamond));
        multiToken = new BasketToken("Multi", "MLT", address(diamond));

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");

        _configureSingleAssetBasket();
        _configureMultiAssetBasket();
    }

    function test_View_NavAndBackingFormulas() public {
        assertEq(IEdenViewFacet(address(diamond)).nav(0), 1000e18);

        ViewHarnessFacet(address(diamond)).setVaultBalance(0, address(singleToken), 1_500e18);
        ViewHarnessFacet(address(diamond)).setOutstandingPrincipal(0, address(singleToken), 500e18);
        ViewHarnessFacet(address(diamond)).setFeePot(0, address(singleToken), 100e18);
        ViewHarnessFacet(address(diamond))
            .setBasket(
                0,
                address(singleToken),
                _addressArray(address(singleToken)),
                _u256Array(1000e18),
                _u16Array(100),
                _u16Array(200),
                300,
                2 * UNIT
            );

        assertEq(
            IEdenViewFacet(address(diamond)).getEconomicBalance(0, address(singleToken)), 2_000e18
        );
        assertEq(IEdenViewFacet(address(diamond)).totalBacking(0, address(singleToken)), 2_100e18);
        assertEq(
            IEdenViewFacet(address(diamond)).getVaultBalance(0, address(singleToken)), 1_500e18
        );
        assertEq(IEdenViewFacet(address(diamond)).getFeePot(0, address(singleToken)), 100e18);
        assertEq(IEdenViewFacet(address(diamond)).nav(0), 1_050e18);
    }

    function test_View_LendingQueriesAndQuoteAccuracy() public {
        ViewHarnessFacet(address(diamond)).setLoan(7, alice, 1, 2 * UNIT, 10_000, 123456);
        ViewHarnessFacet(address(diamond)).setLockedCollateral(1, 2 * UNIT);
        ViewHarnessFacet(address(diamond)).setOutstandingPrincipal(1, address(singleToken), 200e18);
        ViewHarnessFacet(address(diamond)).setOutstandingPrincipal(1, address(multiToken), 100e18);

        (address[] memory assets, uint256[] memory principals, uint256 feeNative) =
            IEdenViewFacet(address(diamond)).quoteBorrow(1, 2 * UNIT);

        assertEq(assets.length, 2);
        assertEq(assets[0], address(singleToken));
        assertEq(assets[1], address(multiToken));
        assertEq(principals[0], 200e18);
        assertEq(principals[1], 100e18);
        assertEq(feeNative, 0.02 ether);

        LibLendingStorage.Loan memory loan = IEdenViewFacet(address(diamond)).getLoan(7);
        assertEq(loan.borrower, alice);
        assertEq(loan.basketId, 1);
        assertEq(loan.collateralUnits, 2 * UNIT);
        assertEq(loan.ltvBps, 10_000);
        assertEq(loan.maturity, 123456);

        assertEq(
            IEdenViewFacet(address(diamond)).maxBorrowable(1, address(singleToken), 2 * UNIT),
            200e18
        );
        assertEq(
            IEdenViewFacet(address(diamond)).maxBorrowable(1, address(multiToken), 2 * UNIT), 100e18
        );
        assertEq(IEdenViewFacet(address(diamond)).getLockedCollateral(1), 2 * UNIT);
        assertEq(
            IEdenViewFacet(address(diamond)).getOutstandingPrincipal(1, address(singleToken)),
            200e18
        );
        assertEq(
            IEdenViewFacet(address(diamond)).getOutstandingPrincipal(1, address(multiToken)), 100e18
        );
    }

    function test_View_PreviewMintAndBurnUseCoreAccounting() public {
        ViewHarnessFacet(address(diamond)).setVaultBalance(1, address(singleToken), 400e18);
        ViewHarnessFacet(address(diamond)).setVaultBalance(1, address(multiToken), 200e18);
        ViewHarnessFacet(address(diamond)).setOutstandingPrincipal(1, address(singleToken), 100e18);
        ViewHarnessFacet(address(diamond)).setFeePot(1, address(singleToken), 20e18);
        ViewHarnessFacet(address(diamond)).setFeePot(1, address(multiToken), 10e18);

        (address[] memory mintAssets, uint256[] memory mintRequired, uint256[] memory mintFees) =
            IEdenViewFacet(address(diamond)).previewMint(1, UNIT);
        assertEq(mintAssets.length, 2);
        assertEq(mintRequired[0], 143e18);
        assertEq(mintRequired[1], 57.75e18);
        assertEq(mintFees[0], 13e18);
        assertEq(mintFees[1], 5.25e18);

        (address[] memory burnAssets, uint256[] memory burnReturned, uint256[] memory burnFees) =
            IEdenViewFacet(address(diamond)).previewBurn(1, UNIT);
        assertEq(burnAssets.length, 2);
        assertEq(burnReturned[0], 94.5e18);
        assertEq(burnReturned[1], 47.25e18);
        assertEq(burnFees[0], 10.5e18);
        assertEq(burnFees[1], 5.25e18);
    }

    function _configureSingleAssetBasket() internal {
        ViewHarnessFacet(address(diamond))
            .setBasket(
                0,
                address(singleToken),
                _addressArray(address(singleToken)),
                _u256Array(1000e18),
                _u16Array(100),
                _u16Array(200),
                300,
                0
            );
    }

    function _configureMultiAssetBasket() internal {
        address[] memory assets = new address[](2);
        assets[0] = address(singleToken);
        assets[1] = address(multiToken);

        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 100e18;
        bundleAmounts[1] = 50e18;

        uint16[] memory mintFeeBps = new uint16[](2);
        mintFeeBps[0] = 1000;
        mintFeeBps[1] = 1000;

        uint16[] memory burnFeeBps = new uint16[](2);
        burnFeeBps[0] = 1000;
        burnFeeBps[1] = 1000;

        uint256[] memory minCollateralUnits = new uint256[](2);
        minCollateralUnits[0] = UNIT;
        minCollateralUnits[1] = 2 * UNIT;

        uint256[] memory flatFeeNative = new uint256[](2);
        flatFeeNative[0] = 0.2 ether;
        flatFeeNative[1] = 0.02 ether;

        ViewHarnessFacet(address(diamond))
            .setBasket(
                1, address(multiToken), assets, bundleAmounts, mintFeeBps, burnFeeBps, 500, 4 * UNIT
            );
        ViewHarnessFacet(address(diamond)).setBorrowFeeTiers(1, minCollateralUnits, flatFeeNative);
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        bytes4[] memory selectors = new bytes4[](14);
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
        selectors[13] = ViewHarnessFacet.setBasket.selector;

        bytes4[] memory extras = new bytes4[](5);
        extras[0] = ViewHarnessFacet.setVaultBalance.selector;
        extras[1] = ViewHarnessFacet.setFeePot.selector;
        extras[2] = ViewHarnessFacet.setOutstandingPrincipal.selector;
        extras[3] = ViewHarnessFacet.setLockedCollateral.selector;
        extras[4] = ViewHarnessFacet.setLoan.selector;

        bytes4[] memory more = new bytes4[](1);
        more[0] = ViewHarnessFacet.setBorrowFeeTiers.selector;

        bytes4[] memory allSelectors = new bytes4[](selectors.length + extras.length + more.length);
        for (uint256 i = 0; i < selectors.length; i++) {
            allSelectors[i] = selectors[i];
        }
        for (uint256 i = 0; i < extras.length; i++) {
            allSelectors[selectors.length + i] = extras[i];
        }
        allSelectors[selectors.length + extras.length] = more[0];

        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(viewFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: allSelectors
        });
    }

    function _u16Array(
        uint16 a
    ) internal pure returns (uint16[] memory arr) {
        arr = new uint16[](1);
        arr[0] = a;
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
