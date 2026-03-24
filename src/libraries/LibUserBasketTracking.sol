// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";

library LibUserBasketTracking {
    function syncUserBasketPosition(
        address user,
        uint256 basketId
    ) internal {
        if (user == address(0) || user == address(this)) return;

        if (_hasBasketPosition(user, basketId)) {
            _addBasketPosition(user, basketId);
        } else {
            _removeBasketPosition(user, basketId);
        }
    }

    function basketIdForToken(
        address token
    ) internal view returns (bool found, uint256 basketId) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 count = store.basketCount;
        for (uint256 i = 0; i < count; i++) {
            if (store.baskets[i].token == token) {
                return (true, i);
            }
        }
    }

    function _hasBasketPosition(
        address user,
        uint256 basketId
    ) private view returns (bool) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        if (IERC20(store.baskets[basketId].token).balanceOf(user) > 0) {
            return true;
        }

        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        uint256[] storage loanIds = lending.borrowerLoanIds[user];
        uint256 len = loanIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 loanId = loanIds[i];
            LibLendingStorage.Loan storage loan = lending.loans[loanId];
            if (
                loan.borrower == user && loan.basketId == basketId && !lending.loanClosed[loanId]
                    && loan.collateralUnits > 0
            ) {
                return true;
            }
        }

        return false;
    }

    function _addBasketPosition(
        address user,
        uint256 basketId
    ) private {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        if (store.userHasBasket[user][basketId]) return;

        store.userHasBasket[user][basketId] = true;
        store.userBasketIds[user].push(basketId);
    }

    function _removeBasketPosition(
        address user,
        uint256 basketId
    ) private {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        if (!store.userHasBasket[user][basketId]) return;

        uint256[] storage basketIds = store.userBasketIds[user];
        uint256 len = basketIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (basketIds[i] == basketId) {
                uint256 lastIndex = len - 1;
                if (i != lastIndex) {
                    basketIds[i] = basketIds[lastIndex];
                }
                basketIds.pop();
                break;
            }
        }

        store.userHasBasket[user][basketId] = false;
    }
}
