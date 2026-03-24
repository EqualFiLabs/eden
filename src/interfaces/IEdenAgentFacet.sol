// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IEdenLendingFacet } from "./IEdenLendingFacet.sol";
import { IEdenMetadataFacet } from "./IEdenMetadataFacet.sol";
import { IEdenPortfolioFacet } from "./IEdenPortfolioFacet.sol";

interface IEdenAgentFacet {
    enum ActionCode {
        OK,
        UnknownBasket,
        BasketPaused,
        InvalidUnits,
        InsufficientBalance,
        LendingDisabled,
        InvalidDuration,
        UnknownLoan,
        NotBorrower,
        LoanExpired,
        NothingClaimable
    }

    struct ActionCheck {
        bool ok;
        uint8 code;
        string reason;
    }

    function getProtocolState() external view returns (IEdenMetadataFacet.ProtocolState memory);
    function getUserState(
        address user
    ) external view returns (IEdenPortfolioFacet.UserPortfolio memory);
    function getBasketState(
        uint256 basketId
    ) external view returns (IEdenMetadataFacet.BasketSummary memory);
    function getLoanState(
        uint256 loanId
    ) external view returns (IEdenLendingFacet.LoanView memory);

    function canMint(
        address user,
        uint256 basketId,
        uint256 units
    ) external view returns (ActionCheck memory);
    function canBurn(
        address user,
        uint256 basketId,
        uint256 units
    ) external view returns (ActionCheck memory);
    function canBorrow(
        address user,
        uint256 basketId,
        uint256 collateralUnits,
        uint40 duration
    ) external view returns (ActionCheck memory);
    function canRepay(
        address user,
        uint256 loanId
    ) external view returns (ActionCheck memory);
    function canExtend(
        address user,
        uint256 loanId,
        uint40 addedDuration
    ) external view returns (ActionCheck memory);
    function canClaimRewards(
        address user
    ) external view returns (ActionCheck memory);
}
