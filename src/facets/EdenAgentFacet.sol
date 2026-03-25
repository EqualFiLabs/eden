// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IEdenAgentFacet } from "src/interfaces/IEdenAgentFacet.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { IEdenMetadataFacet } from "src/interfaces/IEdenMetadataFacet.sol";
import { IEdenPortfolioFacet } from "src/interfaces/IEdenPortfolioFacet.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { IEdenViewFacet } from "src/interfaces/IEdenViewFacet.sol";
import { EdenPortfolioFacet } from "src/facets/EdenPortfolioFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";

contract EdenAgentFacet is EdenPortfolioFacet, IEdenAgentFacet {
    function getProtocolState() external view returns (IEdenMetadataFacet.ProtocolState memory) {
        return IEdenMetadataFacet(address(this)).getAdminState();
    }

    function getUserState(
        address user
    ) external view returns (IEdenPortfolioFacet.UserPortfolio memory) {
        return IEdenPortfolioFacet(address(this)).getUserPortfolio(user);
    }

    function getBasketState(
        uint256 basketId
    ) external view returns (IEdenMetadataFacet.BasketSummary memory) {
        return IEdenMetadataFacet(address(this)).getBasketSummary(basketId);
    }

    function getLoanState(
        uint256 loanId
    ) external view returns (IEdenLendingFacet.LoanView memory) {
        return IEdenLendingFacet(address(this)).getLoanView(loanId);
    }

    function canMint(
        address user,
        uint256 basketId,
        uint256 units
    ) external view returns (ActionCheck memory) {
        ActionCheck memory basketCheck = _validateBasketAndUnits(basketId, units);
        if (!basketCheck.ok) return basketCheck;

        (address[] memory assets, uint256[] memory required,) =
            IEdenViewFacet(address(this)).previewMint(basketId, units);
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            if (assets[i] == address(0)) continue;
            if (IERC20(assets[i]).balanceOf(user) < required[i]) {
                return _actionFail(ActionCode.InsufficientBalance, "insufficient balance");
            }
        }

        return _actionOk();
    }

    function canBurn(
        address user,
        uint256 basketId,
        uint256 units
    ) external view returns (ActionCheck memory) {
        ActionCheck memory basketCheck = _validateBasketAndUnits(basketId, units);
        if (!basketCheck.ok) return basketCheck;

        address token = LibEdenStorage.layout().baskets[basketId].token;
        if (IERC20(token).balanceOf(user) < units) {
            return _actionFail(ActionCode.InsufficientBalance, "insufficient balance");
        }

        return _actionOk();
    }

    function canBorrow(
        address user,
        uint256 basketId,
        uint256 collateralUnits,
        uint40 duration
    ) external view returns (ActionCheck memory) {
        if (basketId >= LibEdenStorage.layout().basketCount) {
            return _actionFail(ActionCode.UnknownBasket, "unknown basket");
        }

        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        if (basket.paused) {
            return _actionFail(ActionCode.BasketPaused, "basket paused");
        }
        if (collateralUnits == 0) {
            return _actionFail(ActionCode.InvalidUnits, "invalid units");
        }
        if (IERC20(basket.token).balanceOf(user) < collateralUnits) {
            return _actionFail(ActionCode.InsufficientBalance, "insufficient balance");
        }

        LibLendingStorage.LendingConfig storage config =
            LibLendingStorage.layout().lendingConfigs[basketId];
        if (config.maxDuration == 0) {
            return _actionFail(ActionCode.LendingDisabled, "lending disabled");
        }
        if (duration < config.minDuration || duration > config.maxDuration) {
            return _actionFail(ActionCode.InvalidDuration, "invalid duration");
        }

        (bool hasTier,) =
            _findBorrowFeeTier(LibLendingStorage.layout().borrowFeeTiers[basketId], collateralUnits);
        if (!hasTier) {
            return _actionFail(ActionCode.InvalidUnits, "collateral below minimum tier");
        }

        IEdenLendingFacet.BorrowPreview memory preview =
            IEdenLendingFacet(address(this)).previewBorrow(basketId, collateralUnits, duration);
        if (!preview.invariantSatisfied) {
            return _actionFail(ActionCode.InvalidUnits, "redeemability invariant would fail");
        }

        return _actionOk();
    }

    function canRepay(
        address user,
        uint256 loanId
    ) external view returns (ActionCheck memory) {
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        LibLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrower == address(0) || lending.loanClosed[loanId]) {
            return _actionFail(ActionCode.UnknownLoan, "unknown loan");
        }
        if (loan.borrower != user) {
            return _actionFail(ActionCode.NotBorrower, "not borrower");
        }

        return _actionOk();
    }

    function canExtend(
        address user,
        uint256 loanId,
        uint40 addedDuration
    ) external view returns (ActionCheck memory) {
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        LibLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrower == address(0) || lending.loanClosed[loanId]) {
            return _actionFail(ActionCode.UnknownLoan, "unknown loan");
        }
        if (loan.borrower != user) {
            return _actionFail(ActionCode.NotBorrower, "not borrower");
        }
        if (block.timestamp > loan.maturity) {
            return _actionFail(ActionCode.LoanExpired, "loan expired");
        }

        LibLendingStorage.LendingConfig storage config = lending.lendingConfigs[loan.basketId];
        if (addedDuration == 0 || config.maxDuration == 0) {
            return _actionFail(ActionCode.InvalidDuration, "invalid duration");
        }

        uint256 newMaturity = uint256(loan.maturity) + addedDuration;
        if (newMaturity > block.timestamp + config.maxDuration) {
            return _actionFail(ActionCode.InvalidDuration, "invalid duration");
        }

        return _actionOk();
    }

    function canClaimRewards(
        address user
    ) external view returns (ActionCheck memory) {
        if (IEdenStEVEFacet(address(this)).claimableRewards(user) == 0) {
            return _actionFail(ActionCode.NothingClaimable, "nothing claimable");
        }

        return _actionOk();
    }

    function _validateBasketAndUnits(
        uint256 basketId,
        uint256 units
    ) internal view returns (ActionCheck memory) {
        if (basketId >= LibEdenStorage.layout().basketCount) {
            return _actionFail(ActionCode.UnknownBasket, "unknown basket");
        }
        if (LibEdenStorage.layout().baskets[basketId].paused) {
            return _actionFail(ActionCode.BasketPaused, "basket paused");
        }
        if (units == 0 || units % UNIT_SCALE != 0) {
            return _actionFail(ActionCode.InvalidUnits, "invalid units");
        }

        return _actionOk();
    }

    function _actionOk() internal pure returns (ActionCheck memory check) {
        check = ActionCheck({ ok: true, code: uint8(ActionCode.OK), reason: "" });
    }

    function _actionFail(
        ActionCode code,
        string memory reason
    ) internal pure returns (ActionCheck memory check) {
        check = ActionCheck({ ok: false, code: uint8(code), reason: reason });
    }
}
