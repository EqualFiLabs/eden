// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IEdenEvents } from "./IEdenEvents.sol";

interface IEdenLendingFacet is IEdenEvents {
    struct LoanView {
        uint256 loanId;
        address borrower;
        uint256 basketId;
        uint256 collateralUnits;
        uint16 ltvBps;
        uint40 maturity;
        uint256 createdAt;
        uint256 closedAt;
        uint8 closeReason;
        bool active;
        bool expired;
        address[] assets;
        uint256[] principals;
        uint256 extensionFeeNative;
    }

    struct BorrowPreview {
        uint256 basketId;
        uint256 collateralUnits;
        uint40 duration;
        address[] assets;
        uint256[] principals;
        uint256 feeNative;
        uint40 maturity;
        uint256 resultingLockedCollateral;
        bool invariantSatisfied;
    }

    struct RepayPreview {
        uint256 loanId;
        address[] assets;
        uint256[] principals;
        uint256 unlockedCollateralUnits;
    }

    struct ExtendPreview {
        uint256 loanId;
        uint40 addedDuration;
        uint40 newMaturity;
        uint256 feeNative;
    }

    function borrow(
        uint256 basketId,
        uint256 collateralUnits,
        uint40 duration
    ) external payable returns (uint256 loanId);

    function repay(
        uint256 loanId
    ) external;
    function extend(
        uint256 loanId,
        uint40 addedDuration
    ) external payable;
    function recoverExpired(
        uint256 loanId
    ) external;
    function configureLending(
        uint256 basketId,
        uint40 minDuration,
        uint40 maxDuration
    ) external;

    function configureBorrowFeeTiers(
        uint256 basketId,
        uint256[] calldata minCollateralUnits,
        uint256[] calldata flatFeeNative
    ) external;

    function loanCount() external view returns (uint256);
    function borrowerLoanCount(
        address user
    ) external view returns (uint256);
    function getLoanView(
        uint256 loanId
    ) external view returns (LoanView memory);
    function getLoanIdsByBorrower(
        address user
    ) external view returns (uint256[] memory);
    function getActiveLoanIdsByBorrower(
        address user
    ) external view returns (uint256[] memory);
    function getLoansByBorrower(
        address user
    ) external view returns (LoanView[] memory);
    function getActiveLoansByBorrower(
        address user
    ) external view returns (LoanView[] memory);
    function getLoanIdsByBorrowerPaginated(
        address user,
        uint256 start,
        uint256 limit
    ) external view returns (uint256[] memory);
    function getActiveLoanIdsByBorrowerPaginated(
        address user,
        uint256 start,
        uint256 limit
    ) external view returns (uint256[] memory);
    function previewBorrow(
        uint256 basketId,
        uint256 collateralUnits,
        uint40 duration
    ) external view returns (BorrowPreview memory);
    function previewRepay(
        uint256 loanId
    ) external view returns (RepayPreview memory);
    function previewExtend(
        uint256 loanId,
        uint40 addedDuration
    ) external view returns (ExtendPreview memory);
}
