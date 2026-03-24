// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IEdenPortfolioFacet } from "src/interfaces/IEdenPortfolioFacet.sol";
import { EdenLendingFacet } from "src/facets/EdenLendingFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { LibStEVEStorage } from "src/libraries/LibStEVEStorage.sol";

contract EdenPortfolioFacet is EdenLendingFacet, IEdenPortfolioFacet {
    function userBasketCount(
        address user
    ) external view returns (uint256) {
        return LibEdenStorage.layout().userBasketIds[user].length;
    }

    function getUserBasketIds(
        address user
    ) public view returns (uint256[] memory) {
        return LibEdenStorage.layout().userBasketIds[user];
    }

    function getUserBasketIdsPaginated(
        address user,
        uint256 start,
        uint256 limit
    ) external view returns (uint256[] memory basketIds) {
        return _sliceUserBasketIds(LibEdenStorage.layout().userBasketIds[user], start, limit);
    }

    function getUserBasketPosition(
        address user,
        uint256 basketId
    ) public view returns (UserBasketPosition memory position) {
        _requireBasketExists(basketId);

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibEdenStorage.Basket storage basket = store.baskets[basketId];
        uint256 walletUnits = IERC20(basket.token).balanceOf(user);
        uint256 lockedUnits = _lockedUnits(user, basketId);
        uint256 totalUnits = walletUnits + lockedUnits;

        position.basketId = basketId;
        position.token = basket.token;
        position.walletUnits = walletUnits;
        position.lockedUnits = lockedUnits;
        position.totalUnits = totalUnits;
        position.assets = basket.assets;
        position.bundleAmounts = basket.bundleAmounts;
        position.feePotShare = _feePotShare(basketId, walletUnits, basket.assets);
        position.redeemableUnderlying = _redeemableUnderlying(basket, walletUnits, position.feePotShare);
        position.nav = _positionNav(basketId, totalUnits, basket);
    }

    function getUserBasketPositions(
        address user,
        uint256[] calldata basketIds
    ) external view returns (UserBasketPosition[] memory positions) {
        uint256 len = basketIds.length;
        positions = new UserBasketPosition[](len);
        for (uint256 i = 0; i < len; i++) {
            positions[i] = getUserBasketPosition(user, basketIds[i]);
        }
    }

    function getUserPortfolio(
        address user
    ) external view returns (UserPortfolio memory portfolio) {
        uint256[] memory basketIds = getUserBasketIds(user);
        uint256 basketLen = basketIds.length;
        uint256[] memory loanIds = getLoanIdsByBorrower(user);
        uint256 loanLen = loanIds.length;

        portfolio.user = user;
        portfolio.eveBalance = IERC20(_rewardToken()).balanceOf(user);
        portfolio.claimableRewards = claimableRewards(user);
        portfolio.stEveBalance = IERC20(_stEveToken()).balanceOf(user);
        portfolio.stEveLocked = LibStEVEStorage.layout().lockedBalances[user];
        portfolio.basketCount = basketLen;
        portfolio.loanCount = loanLen;
        portfolio.baskets = new UserBasketPosition[](basketLen);
        portfolio.loans = new LoanView[](loanLen);

        for (uint256 i = 0; i < basketLen; i++) {
            portfolio.baskets[i] = getUserBasketPosition(user, basketIds[i]);
        }

        for (uint256 i = 0; i < loanLen; i++) {
            portfolio.loans[i] = getLoanView(loanIds[i]);
        }
    }

    function _lockedUnits(
        address user,
        uint256 basketId
    ) internal view returns (uint256 lockedUnits) {
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        uint256[] storage loanIds = lending.borrowerLoanIds[user];
        uint256 len = loanIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 loanId = loanIds[i];
            LibLendingStorage.Loan storage loan = lending.loans[loanId];
            if (loan.basketId != basketId || lending.loanClosed[loanId]) continue;

            lockedUnits += loan.collateralUnits;
        }
    }

    function _feePotShare(
        uint256 basketId,
        uint256 walletUnits,
        address[] storage assets
    ) internal view returns (uint256[] memory feePotShare) {
        uint256 len = assets.length;
        feePotShare = new uint256[](len);

        if (walletUnits == 0) {
            return feePotShare;
        }

        uint256 totalUnits = LibEdenStorage.layout().baskets[basketId].totalUnits;
        if (totalUnits == 0) {
            return feePotShare;
        }

        for (uint256 i = 0; i < len; i++) {
            feePotShare[i] = Math.mulDiv(
                LibEdenStorage.layout().feePots[basketId][assets[i]], walletUnits, totalUnits
            );
        }
    }

    function _redeemableUnderlying(
        LibEdenStorage.Basket storage basket,
        uint256 walletUnits,
        uint256[] memory feePotShare
    ) internal view returns (uint256[] memory redeemableUnderlying) {
        uint256 len = basket.assets.length;
        redeemableUnderlying = new uint256[](len);

        if (walletUnits == 0) {
            return redeemableUnderlying;
        }

        for (uint256 i = 0; i < len; i++) {
            uint256 bundleOut = Math.mulDiv(basket.bundleAmounts[i], walletUnits, UNIT_SCALE);
            uint256 gross = bundleOut + feePotShare[i];
            uint256 fee = Math.mulDiv(gross, basket.burnFeeBps[i], BASIS_POINTS);
            redeemableUnderlying[i] = gross - fee;
        }
    }

    function _positionNav(
        uint256 basketId,
        uint256 totalUnits,
        LibEdenStorage.Basket storage basket
    ) internal view returns (uint256) {
        if (totalUnits == 0 || basket.assets.length != 1 || basket.totalUnits == 0) {
            return 0;
        }

        address asset = basket.assets[0];
        uint256 backing = LibEdenStorage.layout().vaultBalances[basketId][asset]
            + LibLendingStorage.layout().outstandingPrincipal[basketId][asset]
            + LibEdenStorage.layout().feePots[basketId][asset];
        return Math.mulDiv(backing, totalUnits, basket.totalUnits);
    }

    function _sliceUserBasketIds(
        uint256[] storage storedBasketIds,
        uint256 start,
        uint256 limit
    ) internal view returns (uint256[] memory basketIds) {
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

    function _requireBasketExists(
        uint256 basketId
    ) internal view {
        if (basketId >= LibEdenStorage.layout().basketCount) revert UnknownBasket(basketId);
    }
}
