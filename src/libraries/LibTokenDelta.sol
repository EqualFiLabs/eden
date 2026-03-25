// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library LibTokenDelta {
    using SafeERC20 for IERC20;

    error InsufficientTokenDelta(address asset, uint256 expected, uint256 actual);

    function pullTokenAtLeast(
        address token,
        address from,
        uint256 expected
    ) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), expected);
        received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received < expected) {
            revert InsufficientTokenDelta(token, expected, received);
        }
    }
}
