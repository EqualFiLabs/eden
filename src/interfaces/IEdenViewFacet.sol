// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";

interface IEdenViewFacet {
    function nav(
        uint256 basketId
    ) external view returns (uint256);
    function getBasket(
        uint256 basketId
    ) external view returns (LibEdenStorage.Basket memory basket);
    function totalBacking(
        uint256 basketId,
        address asset
    ) external view returns (uint256);
    function getEconomicBalance(
        uint256 basketId,
        address asset
    ) external view returns (uint256);
    function getVaultBalance(
        uint256 basketId,
        address asset
    ) external view returns (uint256);
    function getFeePot(
        uint256 basketId,
        address asset
    ) external view returns (uint256);

    function previewMint(
        uint256 basketId,
        uint256 units
    )
        external
        view
        returns (address[] memory assets, uint256[] memory required, uint256[] memory feeAmounts);

    function previewBurn(
        uint256 basketId,
        uint256 units
    )
        external
        view
        returns (address[] memory assets, uint256[] memory returned, uint256[] memory feeAmounts);

    function getLoan(
        uint256 loanId
    ) external view returns (LibLendingStorage.Loan memory loan);

    function quoteBorrow(
        uint256 basketId,
        uint256 collateralUnits
    )
        external
        view
        returns (address[] memory assets, uint256[] memory principals, uint256 feeNative);

    function maxBorrowable(
        uint256 basketId,
        address asset,
        uint256 collateralUnits
    ) external view returns (uint256);

    function getLockedCollateral(
        uint256 basketId
    ) external view returns (uint256);
    function getOutstandingPrincipal(
        uint256 basketId,
        address asset
    ) external view returns (uint256);
}
