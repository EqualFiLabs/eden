// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IEdenViewFacet } from "src/interfaces/IEdenViewFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";

contract EdenViewFacet is EdenCoreFacet, IEdenViewFacet {
    error NotSingleAssetBasket(uint256 basketId);
    error BelowMinimumTier(uint256 basketId, uint256 collateralUnits);

    function nav(
        uint256 basketId
    ) external view basketExists(basketId) returns (uint256) {
        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        if (basket.assets.length != 1) revert NotSingleAssetBasket(basketId);
        if (basket.totalUnits == 0) return basket.bundleAmounts[0];

        address asset = basket.assets[0];
        uint256 backing =
            _economicBalance(basketId, asset) + LibEdenStorage.layout().feePots[basketId][asset];
        return Math.mulDiv(backing, UNIT_SCALE, basket.totalUnits);
    }

    function getBasket(
        uint256 basketId
    ) external view basketExists(basketId) returns (LibEdenStorage.Basket memory basket) {
        basket = LibEdenStorage.layout().baskets[basketId];
    }

    function totalBacking(
        uint256 basketId,
        address asset
    ) external view basketExists(basketId) returns (uint256) {
        return _economicBalance(basketId, asset) + LibEdenStorage.layout().feePots[basketId][asset];
    }

    function getEconomicBalance(
        uint256 basketId,
        address asset
    ) external view basketExists(basketId) returns (uint256) {
        return _economicBalance(basketId, asset);
    }

    function getVaultBalance(
        uint256 basketId,
        address asset
    ) external view basketExists(basketId) returns (uint256) {
        return LibEdenStorage.layout().vaultBalances[basketId][asset];
    }

    function getFeePot(
        uint256 basketId,
        address asset
    ) external view basketExists(basketId) returns (uint256) {
        return LibEdenStorage.layout().feePots[basketId][asset];
    }

    function getLoan(
        uint256 loanId
    ) external view returns (LibLendingStorage.Loan memory loan) {
        loan = LibLendingStorage.layout().loans[loanId];
    }

    function previewMint(
        uint256 basketId,
        uint256 units
    )
        public
        view
        override(EdenCoreFacet, IEdenViewFacet)
        basketExists(basketId)
        returns (address[] memory assets, uint256[] memory required, uint256[] memory feeAmounts)
    {
        MintQuote memory quote = _previewMintQuote(basketId, units);
        return (quote.assets, quote.totalRequired, quote.feeAmounts);
    }

    function previewBurn(
        uint256 basketId,
        uint256 units
    )
        public
        view
        override(EdenCoreFacet, IEdenViewFacet)
        basketExists(basketId)
        returns (address[] memory assets, uint256[] memory returned, uint256[] memory feeAmounts)
    {
        BurnQuote memory quote = _previewBurnQuote(basketId, units);
        return (quote.assets, quote.payoutAmounts, quote.feeAmounts);
    }

    function quoteBorrow(
        uint256 basketId,
        uint256 collateralUnits
    )
        external
        view
        basketExists(basketId)
        returns (address[] memory assets, uint256[] memory principals, uint256 feeNative)
    {
        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        (assets, principals) =
            _deriveLoanPrincipals(basket, collateralUnits, LibLendingStorage.DEFAULT_LTV_BPS);
        feeNative =
        _selectBorrowFeeTier(
            LibLendingStorage.layout().borrowFeeTiers[basketId], basketId, collateralUnits
        )
        .flatFeeNative;
    }

    function maxBorrowable(
        uint256 basketId,
        address asset,
        uint256 collateralUnits
    ) external view basketExists(basketId) returns (uint256) {
        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        uint256 len = basket.assets.length;
        for (uint256 i = 0; i < len; i++) {
            if (basket.assets[i] == asset) {
                return Math.mulDiv(
                    collateralUnits,
                    basket.bundleAmounts[i] * LibLendingStorage.DEFAULT_LTV_BPS,
                    UNIT_SCALE * BASIS_POINTS
                );
            }
        }

        return 0;
    }

    function getLockedCollateral(
        uint256 basketId
    ) external view basketExists(basketId) returns (uint256) {
        return LibLendingStorage.layout().lockedCollateralUnits[basketId];
    }

    function getOutstandingPrincipal(
        uint256 basketId,
        address asset
    ) external view basketExists(basketId) returns (uint256) {
        return LibLendingStorage.layout().outstandingPrincipal[basketId][asset];
    }

    function _deriveLoanPrincipals(
        LibEdenStorage.Basket storage basket,
        uint256 collateralUnits,
        uint16 ltvBps
    ) internal view returns (address[] memory assets, uint256[] memory principals) {
        uint256 len = basket.assets.length;
        assets = new address[](len);
        principals = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            assets[i] = basket.assets[i];
            principals[i] = Math.mulDiv(
                collateralUnits, basket.bundleAmounts[i] * ltvBps, UNIT_SCALE * BASIS_POINTS
            );
        }
    }

    function _selectBorrowFeeTier(
        LibLendingStorage.BorrowFeeTier[] storage tiers,
        uint256 basketId,
        uint256 collateralUnits
    ) internal view returns (LibLendingStorage.BorrowFeeTier memory tier) {
        uint256 len = tiers.length;
        if (len == 0) revert BelowMinimumTier(basketId, collateralUnits);

        bool found;
        for (uint256 i = 0; i < len; i++) {
            if (collateralUnits >= tiers[i].minCollateralUnits) {
                tier = tiers[i];
                found = true;
            } else {
                break;
            }
        }

        if (!found) revert BelowMinimumTier(basketId, collateralUnits);
    }
}
