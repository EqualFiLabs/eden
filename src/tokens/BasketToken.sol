// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { IEdenBasketPositionHook } from "src/interfaces/IEdenBasketPositionHook.sol";

contract BasketToken is ERC20, ERC20Permit {
    error ZeroMinter();
    error OnlyMinter(address caller);

    address public immutable minter;

    modifier onlyMinter() {
        if (msg.sender != minter) revert OnlyMinter(msg.sender);
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address minter_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (minter_ == address(0)) revert ZeroMinter();
        minter = minter_;
    }

    function mintIndexUnits(
        address to,
        uint256 amount
    ) external virtual onlyMinter {
        _mint(to, amount);
    }

    function burnIndexUnits(
        address from,
        uint256 amount
    ) external virtual onlyMinter {
        _burn(from, amount);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        super._update(from, to, value);

        if (from != address(0) && to != address(0)) {
            IEdenBasketPositionHook(minter).onBasketTokenTransfer(from, to, value);
        }
    }
}
