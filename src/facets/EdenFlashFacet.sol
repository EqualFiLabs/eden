// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IEdenFlashFacet } from "src/interfaces/IEdenFlashFacet.sol";
import { IEdenFlashReceiver } from "src/interfaces/IEdenFlashReceiver.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";

contract EdenFlashFacet is EdenCoreFacet, IEdenFlashFacet {
    using SafeERC20 for IERC20;

    bytes32 internal constant FLASH_FEE_SOURCE = keccak256("FLASH_FEE");

    error IncompleteFlashRepayment(address asset, uint256 expected, uint256 actual);

    struct FlashQuote {
        address[] assets;
        uint256[] amounts;
        uint256[] feeAmounts;
        uint256[] preBalances;
    }

    function flashLoan(
        uint256 basketId,
        uint256 units,
        address receiver,
        bytes calldata data
    ) external nonReentrant basketExists(basketId) {
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();

        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        if (basket.paused) revert BasketPaused(basketId);

        FlashQuote memory quote = _quoteFlashLoan(basket, units);
        _dispatchFlashLoan(receiver, quote.assets, quote.amounts);

        IEdenFlashReceiver(receiver)
            .onEdenFlashLoan(basketId, units, quote.assets, quote.amounts, quote.feeAmounts, data);

        _settleFlashLoan(basketId, quote);
        emit FlashLoaned(basketId, receiver, units, quote.amounts, quote.feeAmounts);
    }

    function _quoteFlashLoan(
        LibEdenStorage.Basket storage basket,
        uint256 units
    ) internal view returns (FlashQuote memory quote) {
        uint256 len = basket.assets.length;
        quote.assets = new address[](len);
        quote.amounts = new uint256[](len);
        quote.feeAmounts = new uint256[](len);
        quote.preBalances = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address asset = basket.assets[i];
            if (_isNative(asset)) revert NativeAssetUnsupported();

            uint256 preBalance = IERC20(asset).balanceOf(address(this));
            uint256 amount = Math.mulDiv(basket.bundleAmounts[i], units, UNIT_SCALE);
            uint256 fee = Math.mulDiv(amount, basket.flashFeeBps, BASIS_POINTS);
            if (preBalance < amount) {
                revert InsufficientVaultBalance(asset, amount, preBalance);
            }

            quote.assets[i] = asset;
            quote.amounts[i] = amount;
            quote.feeAmounts[i] = fee;
            quote.preBalances[i] = preBalance;
        }
    }

    function _dispatchFlashLoan(
        address receiver,
        address[] memory assets,
        uint256[] memory amounts
    ) internal {
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            IERC20(assets[i]).safeTransfer(receiver, amounts[i]);
        }
    }

    function _settleFlashLoan(
        uint256 basketId,
        FlashQuote memory quote
    ) internal {
        uint256 len = quote.assets.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 actualBalance = IERC20(quote.assets[i]).balanceOf(address(this));
            uint256 expectedBalance = quote.preBalances[i] + quote.feeAmounts[i];
            if (actualBalance < expectedBalance) {
                revert IncompleteFlashRepayment(quote.assets[i], expectedBalance, actualBalance);
            }

            _distributeFee(basketId, quote.assets[i], quote.feeAmounts[i], FLASH_FEE_SOURCE);
        }
    }
}
