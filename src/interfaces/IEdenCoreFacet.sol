// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IEdenEvents } from "./IEdenEvents.sol";

interface IEdenCoreFacet is IEdenEvents {
    struct CreateBasketParams {
        string name;
        string symbol;
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
    }

    function createBasket(
        CreateBasketParams calldata params
    ) external payable returns (uint256 basketId, address token);

    function mint(
        uint256 basketId,
        uint256 units,
        address to
    ) external returns (uint256 minted);
    function burn(
        uint256 basketId,
        uint256 units,
        address to
    ) external returns (uint256[] memory assetsOut);

    function onBasketTokenTransfer(
        address from,
        address to,
        uint256 value
    ) external;
}
