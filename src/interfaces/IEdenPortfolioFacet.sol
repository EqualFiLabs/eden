// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IEdenLendingFacet } from "./IEdenLendingFacet.sol";

interface IEdenPortfolioFacet {
    struct UserBasketPosition {
        uint256 basketId;
        address token;
        uint256 walletUnits;
        uint256 lockedUnits;
        uint256 totalUnits;
        uint256 nav;
        address[] assets;
        uint256[] bundleAmounts;
        uint256[] redeemableUnderlying;
        uint256[] feePotShare;
    }

    struct UserPortfolio {
        address user;
        uint256 eveBalance;
        uint256 claimableRewards;
        uint256 stEveBalance;
        uint256 stEveLocked;
        uint256 basketCount;
        uint256 loanCount;
        UserBasketPosition[] baskets;
        IEdenLendingFacet.LoanView[] loans;
    }

    function userBasketCount(
        address user
    ) external view returns (uint256);
    function getUserBasketIds(
        address user
    ) external view returns (uint256[] memory);
    function getUserBasketIdsPaginated(
        address user,
        uint256 start,
        uint256 limit
    ) external view returns (uint256[] memory);
    function getUserBasketPosition(
        address user,
        uint256 basketId
    ) external view returns (UserBasketPosition memory);
    function getUserBasketPositions(
        address user,
        uint256[] calldata basketIds
    ) external view returns (UserBasketPosition[] memory);
    function getUserPortfolio(
        address user
    ) external view returns (UserPortfolio memory);
}
