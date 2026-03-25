// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IEdenBatchFacet } from "src/interfaces/IEdenBatchFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { LibStEVEStorage } from "src/libraries/LibStEVEStorage.sol";
import { LibUserBasketTracking } from "src/libraries/LibUserBasketTracking.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";
import { EdenLendingFacet } from "src/facets/EdenLendingFacet.sol";

contract EdenBatchFacet is EdenLendingFacet {
    using SafeERC20 for IERC20;

    uint256 internal constant BATCH_BASIS_POINTS = 10_000;
    uint256 internal constant BATCH_UNIT_SCALE = 1e18;

    bytes32 internal constant FEE_POT_BUY_IN_SOURCE = keccak256("FEE_POT_BUY_IN");
    bytes32 internal constant MINT_FEE_SOURCE = keccak256("MINT_FEE");
    bytes32 internal constant PROTOCOL_FEE_SELF_SOURCE = keccak256("PROTOCOL_FEE_SELF");
    bytes32 internal constant PROTOCOL_FEE_STEVE_SOURCE = keccak256("PROTOCOL_FEE_STEVE");
    bytes32 internal constant PROTOCOL_FEE_ORIGIN_SOURCE = keccak256("PROTOCOL_FEE_ORIGIN");

    error NativeValueUnsupported(uint256 actual);
    error ZeroClaimableRewards();
    error MintOutputTooLow(uint256 actual, uint256 minimum);

    struct SingleAssetMintQuote {
        uint256 unitsMinted;
        uint256 totalRequired;
        uint256 baseDeposit;
        uint256 potBuyIn;
        uint256 fee;
    }

    function multicall(
        bytes[] calldata calls
    ) external payable returns (bytes[] memory results) {
        if (msg.value != 0) revert NativeValueUnsupported(msg.value);

        uint256 len = calls.length;
        results = new bytes[](len);
        for (uint256 i = 0; i < len; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(calls[i]);
            if (!success) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
    }

    function claimAndMintStEVE(
        uint256 minUnitsOut,
        address to
    ) external nonReentrant returns (uint256 unitsMinted) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 basketId = store.steveBasketId;
        LibEdenStorage.Basket storage basket = store.baskets[basketId];
        address rewardToken = _rewardToken();

        if (basket.paused) revert BasketPaused(basketId);
        if (basket.token == address(0) || basket.assets.length != 1 || basket.assets[0] != rewardToken)
        {
            revert InvalidBasketConfiguration();
        }

        (uint256 claimed,,) = _claimRewards(msg.sender, false);
        if (claimed == 0) revert ZeroClaimableRewards();

        SingleAssetMintQuote memory quote = _quoteSingleAssetMintFromInput(basketId, claimed);
        unitsMinted = quote.unitsMinted;
        if (unitsMinted == 0 || unitsMinted < minUnitsOut) {
            revert MintOutputTooLow(unitsMinted, minUnitsOut);
        }

        _finalizeClaimAndMint(store, basketId, rewardToken, basket, to, msg.sender, quote, claimed);
    }

    function extendMany(
        uint256[] calldata loanIds,
        uint40[] calldata addedDurations
    ) external payable nonReentrant {
        uint256 len = loanIds.length;
        if (len != addedDurations.length) revert InvalidArrayLength();
        if (len == 0) {
            if (msg.value != 0) revert UnexpectedNativeFee(0, msg.value);
            return;
        }

        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        uint40[] memory newMaturities = new uint40[](len);
        uint256[] memory fees = new uint256[](len);
        uint256 totalFee;

        for (uint256 i = 0; i < len; i++) {
            (uint40 newMaturity, uint256 feeNative) =
                _validateAndQuoteExtension(lending, loanIds[i], addedDurations[i], msg.sender);
            newMaturities[i] = newMaturity;
            fees[i] = feeNative;
            totalFee += feeNative;
        }

        if (msg.value != totalFee) revert UnexpectedNativeFee(totalFee, msg.value);

        for (uint256 i = 0; i < len; i++) {
            _applyExtension(lending, loanIds[i], newMaturities[i], fees[i]);
        }

        _forwardNativeFee(totalFee);
    }

    function _quoteSingleAssetMintFromInput(
        uint256 basketId,
        uint256 availableInput
    )
        internal
        view
        returns (SingleAssetMintQuote memory quote)
    {
        if (availableInput == 0) {
            return quote;
        }

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibEdenStorage.Basket storage basket = store.baskets[basketId];

        uint256 high = _initialMintSearchUpperBound(basketId, availableInput);
        while (high > 0) {
            (uint256 requiredAtHigh,,,) = _singleAssetMintRequirement(basketId, high);
            if (requiredAtHigh > availableInput) break;

            if (high > type(uint256).max / 2) {
                break;
            }
            high *= 2;
        }

        uint256 low;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            (uint256 requiredAtMid,,,) = _singleAssetMintRequirement(basketId, mid);
            if (requiredAtMid <= availableInput) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        quote.unitsMinted = low;
        if (quote.unitsMinted == 0) {
            return quote;
        }

        (quote.totalRequired, quote.baseDeposit, quote.potBuyIn, quote.fee) =
            _singleAssetMintRequirement(basketId, quote.unitsMinted);
        if (basket.totalUnits == 0 && quote.totalRequired > availableInput) {
            delete quote;
        }
    }

    function _finalizeClaimAndMint(
        LibEdenStorage.EdenStorage storage store,
        uint256 basketId,
        address rewardToken,
        LibEdenStorage.Basket storage basket,
        address to,
        address claimant,
        SingleAssetMintQuote memory quote,
        uint256 claimed
    ) internal {
        store.vaultBalances[basketId][rewardToken] += quote.baseDeposit;
        if (quote.potBuyIn > 0) {
            store.feePots[basketId][rewardToken] += quote.potBuyIn;
            emit FeePotAccrued(basketId, rewardToken, quote.potBuyIn, FEE_POT_BUY_IN_SOURCE);
        }

        _distributeBatchFee(basketId, rewardToken, quote.fee, MINT_FEE_SOURCE);

        basket.totalUnits += quote.unitsMinted;
        BasketToken(basket.token).mintIndexUnits(to, quote.unitsMinted);
        LibUserBasketTracking.syncUserBasketPosition(to, basketId);

        uint256 leftoverRewards = claimed - quote.totalRequired;
        if (leftoverRewards > 0) {
            IERC20(rewardToken).safeTransfer(claimant, leftoverRewards);
        }

        uint256[] memory deposited = new uint256[](1);
        deposited[0] = quote.totalRequired;
        uint256[] memory fees = new uint256[](1);
        fees[0] = quote.fee;
        emit Minted(basketId, claimant, quote.unitsMinted, deposited, fees);
    }

    function _singleAssetMintRequirement(
        uint256 basketId,
        uint256 units
    )
        internal
        view
        returns (uint256 totalRequired, uint256 baseDeposit, uint256 potBuyIn, uint256 fee)
    {
        if (units == 0) {
            return (0, 0, 0, 0);
        }

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibEdenStorage.Basket storage basket = store.baskets[basketId];
        uint256 totalSupply = basket.totalUnits;

        if (totalSupply == 0) {
            baseDeposit = Math.mulDiv(basket.bundleAmounts[0], units, BATCH_UNIT_SCALE);
        } else {
            uint256 economicBalance = _batchEconomicBalance(basketId, basket.assets[0]);
            baseDeposit = Math.mulDiv(economicBalance, units, totalSupply, Math.Rounding.Ceil);
            potBuyIn = Math.mulDiv(
                store.feePots[basketId][basket.assets[0]], units, totalSupply, Math.Rounding.Ceil
            );
        }

        uint256 grossInput = baseDeposit + potBuyIn;
        fee =
            Math.mulDiv(grossInput, basket.mintFeeBps[0], BATCH_BASIS_POINTS, Math.Rounding.Ceil);
        totalRequired = grossInput + fee;
    }

    function _initialMintSearchUpperBound(
        uint256 basketId,
        uint256 availableInput
    ) internal view returns (uint256 high) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibEdenStorage.Basket storage basket = store.baskets[basketId];
        uint256 totalSupply = basket.totalUnits;

        if (totalSupply == 0) {
            high =
                Math.mulDiv(availableInput, BATCH_UNIT_SCALE, basket.bundleAmounts[0], Math.Rounding.Ceil)
                + 1;
            return high;
        }

        uint256 grossUnitCost =
            _batchEconomicBalance(basketId, basket.assets[0])
                + store.feePots[basketId][basket.assets[0]];
        if (grossUnitCost == 0) {
            return totalSupply + 1;
        }

        high = Math.mulDiv(availableInput, totalSupply, grossUnitCost, Math.Rounding.Ceil) + 1;
    }

    function _batchEconomicBalance(
        uint256 basketId,
        address asset
    ) internal view returns (uint256) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        return store.vaultBalances[basketId][asset]
            + LibLendingStorage.layout().outstandingPrincipal[basketId][asset];
    }

    function _distributeBatchFee(
        uint256 basketId,
        address asset,
        uint256 fee,
        bytes32 source
    ) internal {
        if (fee == 0) return;

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 treasuryShare = Math.mulDiv(fee, store.treasuryFeeBps, BATCH_BASIS_POINTS);
        uint256 remainder = fee - treasuryShare;
        uint256 feePotDirect = Math.mulDiv(remainder, store.feePotShareBps, BATCH_BASIS_POINTS);
        uint256 protocolFeeAmount = remainder - feePotDirect;

        if (treasuryShare > 0) {
            address treasury = store.treasury;
            if (treasury == address(0)) revert TreasuryNotSet();
            _transferBatchAsset(asset, treasury, treasuryShare);
        }

        if (feePotDirect > 0) {
            store.feePots[basketId][asset] += feePotDirect;
            emit FeePotAccrued(basketId, asset, feePotDirect, source);
        }

        _routeBatchProtocolFee(basketId, asset, protocolFeeAmount);
    }

    function _routeBatchProtocolFee(
        uint256 basketId,
        address asset,
        uint256 amount
    ) internal {
        if (amount == 0) return;

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 steveBasketId = store.steveBasketId;

        if (basketId == steveBasketId) {
            store.feePots[basketId][asset] += amount;
            emit FeePotAccrued(basketId, asset, amount, PROTOCOL_FEE_SELF_SOURCE);
            emit ProtocolFeeRouted(basketId, asset, amount, 0);
            return;
        }

        uint256 steveShare = Math.mulDiv(amount, store.protocolFeeSplitBps, BATCH_BASIS_POINTS);
        uint256 basketShare = amount - steveShare;

        if (steveShare > 0) {
            store.feePots[steveBasketId][asset] += steveShare;
            emit FeePotAccrued(steveBasketId, asset, steveShare, PROTOCOL_FEE_STEVE_SOURCE);
        }

        if (basketShare > 0) {
            store.feePots[basketId][asset] += basketShare;
            emit FeePotAccrued(basketId, asset, basketShare, PROTOCOL_FEE_ORIGIN_SOURCE);
        }

        emit ProtocolFeeRouted(basketId, asset, steveShare, basketShare);
    }

    function _transferBatchAsset(
        address asset,
        address to,
        uint256 amount
    ) internal {
        if (amount == 0) return;

        if (asset == address(0)) {
            (bool sent,) = payable(to).call{ value: amount }("");
            if (!sent) revert NativeTransferFailed(to, amount);
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }
}
