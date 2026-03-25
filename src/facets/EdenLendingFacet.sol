// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { LibUserBasketTracking } from "src/libraries/LibUserBasketTracking.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";
import { EdenStEVEFacet } from "src/facets/EdenStEVEFacet.sol";

contract EdenLendingFacet is EdenStEVEFacet, IEdenLendingFacet {
    using SafeERC20 for IERC20;

    uint256 internal constant BASIS_POINTS = 10_000;
    uint256 internal constant UNIT_SCALE = 1e18;

    error UnknownBasket(uint256 basketId);
    error BasketPaused(uint256 basketId);
    error InvalidArrayLength();
    error InvalidDuration(uint256 provided, uint256 minDuration, uint256 maxDuration);
    error InvalidTierConfiguration();
    error InvalidCollateralUnits();
    error UnexpectedNativeFee(uint256 expected, uint256 actual);
    error NativeTransferFailed(address recipient, uint256 amount);
    error NativeAssetUnsupported();
    error TreasuryNotSet();
    error InsufficientVaultBalance(address asset, uint256 expected, uint256 actual);
    error RedeemabilityInvariantBroken(address asset, uint256 required, uint256 remaining);
    error LoanNotFound(uint256 loanId);
    error NotBorrower(address caller, address borrower);
    error LoanExpired(uint256 loanId, uint40 maturity);
    error LoanNotExpired(uint256 loanId, uint40 maturity);
    error BelowMinimumTier(uint256 basketId, uint256 collateralUnits);

    modifier basketExists(
        uint256 basketId
    ) {
        if (basketId >= LibEdenStorage.layout().basketCount) revert UnknownBasket(basketId);
        _;
    }

    function borrow(
        uint256 basketId,
        uint256 collateralUnits,
        uint40 duration
    ) external payable nonReentrant basketExists(basketId) returns (uint256 loanId) {
        if (collateralUnits == 0) revert InvalidCollateralUnits();

        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        if (basket.paused) revert BasketPaused(basketId);

        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        _validateDuration(lending.lendingConfigs[basketId], duration);

        uint256 nativeFee =
            _selectBorrowFeeTier(lending.borrowFeeTiers[basketId], basketId, collateralUnits)
        .flatFeeNative;
        _requireNativeFee(nativeFee);

        IERC20(basket.token).safeTransferFrom(msg.sender, address(this), collateralUnits);

        if (basketId == LibEdenStorage.layout().steveBasketId) {
            _moveCustodyLiquidToLocked(msg.sender, address(this), collateralUnits);
        }

        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(basket, collateralUnits, LibLendingStorage.DEFAULT_LTV_BPS);

        uint256 newLockedCollateral = lending.lockedCollateralUnits[basketId] + collateralUnits;
        _enforceRedeemabilityInvariant(
            basketId, basket, assets, principals, newLockedCollateral, basket.totalUnits
        );

        lending.lockedCollateralUnits[basketId] = newLockedCollateral;
        uint40 maturity = uint40(block.timestamp + duration);
        loanId = _createLoan(lending, basketId, collateralUnits, maturity, msg.sender);
        lending.borrowerLoanIds[msg.sender].push(loanId);
        lending.loanCreatedAt[loanId] = block.timestamp;
        LibUserBasketTracking.syncUserBasketPosition(msg.sender, basketId);
        _executeBorrowPayouts(basketId, assets, principals, msg.sender);

        _forwardNativeFee(nativeFee);
        emit LoanCreated(
            loanId,
            basketId,
            msg.sender,
            collateralUnits,
            assets,
            principals,
            LibLendingStorage.DEFAULT_LTV_BPS,
            maturity
        );
    }

    function repay(
        uint256 loanId
    ) external nonReentrant {
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        LibLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrower == address(0) || lending.loanClosed[loanId]) revert LoanNotFound(loanId);
        if (msg.sender != loan.borrower) revert NotBorrower(msg.sender, loan.borrower);

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibEdenStorage.Basket storage basket = store.baskets[loan.basketId];
        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(basket, loan.collateralUnits, loan.ltvBps);

        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            uint256 principal = principals[i];
            IERC20(asset).safeTransferFrom(msg.sender, address(this), principal);
            store.vaultBalances[loan.basketId][asset] += principal;
            lending.outstandingPrincipal[loan.basketId][asset] -= principal;
        }

        lending.lockedCollateralUnits[loan.basketId] -= loan.collateralUnits;

        if (loan.basketId == store.steveBasketId) {
            _moveLockedToCustodyLiquid(loan.borrower, address(this), loan.collateralUnits);
        }

        IERC20(basket.token).safeTransfer(loan.borrower, loan.collateralUnits);

        lending.loanClosed[loanId] = true;
        lending.loanClosedAt[loanId] = block.timestamp;
        lending.loanCloseReason[loanId] = 1;
        LibUserBasketTracking.syncUserBasketPosition(loan.borrower, loan.basketId);
        emit LoanRepaid(loanId);
    }

    function extend(
        uint256 loanId,
        uint40 addedDuration
    ) external payable nonReentrant {
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        (uint40 newMaturity, uint256 feeNative) =
            _validateAndQuoteExtension(lending, loanId, addedDuration, msg.sender);
        _requireNativeFee(feeNative);

        _applyExtension(lending, loanId, newMaturity, feeNative);
        _forwardNativeFee(feeNative);
    }

    function recoverExpired(
        uint256 loanId
    ) external nonReentrant {
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        LibLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrower == address(0) || lending.loanClosed[loanId]) revert LoanNotFound(loanId);
        if (block.timestamp <= loan.maturity) revert LoanNotExpired(loanId, loan.maturity);

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibEdenStorage.Basket storage basket = store.baskets[loan.basketId];
        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(basket, loan.collateralUnits, loan.ltvBps);

        lending.lockedCollateralUnits[loan.basketId] -= loan.collateralUnits;
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            lending.outstandingPrincipal[loan.basketId][assets[i]] -= principals[i];
        }

        if (loan.basketId == store.steveBasketId) {
            _moveLockedToCustodyLiquid(loan.borrower, address(this), loan.collateralUnits);
        }

        basket.totalUnits -= loan.collateralUnits;
        BasketToken(basket.token).burnIndexUnits(address(this), loan.collateralUnits);

        _enforcePostRecoveryInvariant(
            loan.basketId, basket, lending.lockedCollateralUnits[loan.basketId], basket.totalUnits
        );

        lending.loanClosed[loanId] = true;
        lending.loanClosedAt[loanId] = block.timestamp;
        lending.loanCloseReason[loanId] = 2;
        LibUserBasketTracking.syncUserBasketPosition(loan.borrower, loan.basketId);
        emit LoanRecovered(loanId, loan.collateralUnits, assets, principals);
    }

    function configureLending(
        uint256 basketId,
        uint40 minDuration,
        uint40 maxDuration
    ) external onlyOwnerOrTimelock basketExists(basketId) {
        if (minDuration == 0 || maxDuration < minDuration) {
            revert InvalidDuration(0, minDuration, maxDuration);
        }

        LibLendingStorage.layout().lendingConfigs[basketId] =
            LibLendingStorage.LendingConfig({ minDuration: minDuration, maxDuration: maxDuration });
    }

    function configureBorrowFeeTiers(
        uint256 basketId,
        uint256[] calldata minCollateralUnits,
        uint256[] calldata flatFeeNative
    ) external onlyOwnerOrTimelock basketExists(basketId) {
        uint256 len = minCollateralUnits.length;
        if (len == 0 || len != flatFeeNative.length) revert InvalidArrayLength();

        LibLendingStorage.BorrowFeeTier[] storage tiers =
            LibLendingStorage.layout().borrowFeeTiers[basketId];
        while (tiers.length > 0) {
            tiers.pop();
        }

        uint256 previousMin = 0;
        for (uint256 i = 0; i < len; i++) {
            uint256 currentMin = minCollateralUnits[i];
            if (currentMin == 0 || (i > 0 && currentMin <= previousMin)) {
                revert InvalidTierConfiguration();
            }

            tiers.push(
                LibLendingStorage.BorrowFeeTier({
                    minCollateralUnits: currentMin, flatFeeNative: flatFeeNative[i]
                })
            );
            previousMin = currentMin;
        }
    }

    function loanCount() external view returns (uint256) {
        return LibLendingStorage.layout().nextLoanId;
    }

    function borrowerLoanCount(
        address user
    ) external view returns (uint256) {
        return LibLendingStorage.layout().borrowerLoanIds[user].length;
    }

    function getLoanView(
        uint256 loanId
    ) public view returns (LoanView memory loanView) {
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        LibLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrower == address(0)) revert LoanNotFound(loanId);

        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(LibEdenStorage.layout().baskets[loan.basketId], loan.collateralUnits, loan.ltvBps);
        (bool hasTier, uint256 extensionFeeNative) =
            _findBorrowFeeTier(lending.borrowFeeTiers[loan.basketId], loan.collateralUnits);

        bool closed = lending.loanClosed[loanId];
        bool expired = block.timestamp > loan.maturity;
        loanView = LoanView({
            loanId: loanId,
            borrower: loan.borrower,
            basketId: loan.basketId,
            collateralUnits: loan.collateralUnits,
            ltvBps: loan.ltvBps,
            maturity: loan.maturity,
            createdAt: lending.loanCreatedAt[loanId],
            closedAt: lending.loanClosedAt[loanId],
            closeReason: lending.loanCloseReason[loanId],
            active: !closed && !expired,
            expired: expired,
            assets: assets,
            principals: principals,
            extensionFeeNative: hasTier ? extensionFeeNative : 0
        });
    }

    function getLoanIdsByBorrower(
        address user
    ) public view returns (uint256[] memory) {
        return _sliceLoanIds(LibLendingStorage.layout().borrowerLoanIds[user], 0, type(uint256).max);
    }

    function getActiveLoanIdsByBorrower(
        address user
    ) public view returns (uint256[] memory loanIds) {
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        uint256[] storage allLoanIds = lending.borrowerLoanIds[user];
        uint256 len = allLoanIds.length;
        uint256 activeCount;

        for (uint256 i = 0; i < len; i++) {
            LibLendingStorage.Loan storage loan = lending.loans[allLoanIds[i]];
            if (_isActiveLoan(lending, allLoanIds[i], loan)) {
                activeCount++;
            }
        }

        loanIds = new uint256[](activeCount);
        uint256 index;
        for (uint256 i = 0; i < len; i++) {
            uint256 loanId = allLoanIds[i];
            LibLendingStorage.Loan storage loan = lending.loans[loanId];
            if (_isActiveLoan(lending, loanId, loan)) {
                loanIds[index++] = loanId;
            }
        }
    }

    function getLoansByBorrower(
        address user
    ) external view returns (LoanView[] memory loans) {
        uint256[] memory loanIds = getLoanIdsByBorrower(user);
        uint256 len = loanIds.length;
        loans = new LoanView[](len);
        for (uint256 i = 0; i < len; i++) {
            loans[i] = getLoanView(loanIds[i]);
        }
    }

    function getActiveLoansByBorrower(
        address user
    ) external view returns (LoanView[] memory loans) {
        uint256[] memory loanIds = getActiveLoanIdsByBorrower(user);
        uint256 len = loanIds.length;
        loans = new LoanView[](len);
        for (uint256 i = 0; i < len; i++) {
            loans[i] = getLoanView(loanIds[i]);
        }
    }

    function getLoanIdsByBorrowerPaginated(
        address user,
        uint256 start,
        uint256 limit
    ) external view returns (uint256[] memory) {
        return _sliceLoanIds(LibLendingStorage.layout().borrowerLoanIds[user], start, limit);
    }

    function getActiveLoanIdsByBorrowerPaginated(
        address user,
        uint256 start,
        uint256 limit
    ) external view returns (uint256[] memory loanIds) {
        if (limit == 0) return new uint256[](0);

        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        uint256[] storage allLoanIds = lending.borrowerLoanIds[user];
        uint256 len = allLoanIds.length;
        uint256 activeCount;

        for (uint256 i = 0; i < len; i++) {
            LibLendingStorage.Loan storage loan = lending.loans[allLoanIds[i]];
            if (_isActiveLoan(lending, allLoanIds[i], loan)) {
                activeCount++;
            }
        }

        if (start >= activeCount) {
            return new uint256[](0);
        }

        uint256 remaining = activeCount - start;
        uint256 resultLen = remaining < limit ? remaining : limit;
        loanIds = new uint256[](resultLen);

        uint256 activeIndex;
        uint256 resultIndex;
        for (uint256 i = 0; i < len && resultIndex < resultLen; i++) {
            uint256 loanId = allLoanIds[i];
            LibLendingStorage.Loan storage loan = lending.loans[loanId];
            if (!_isActiveLoan(lending, loanId, loan)) continue;
            if (activeIndex++ < start) continue;

            loanIds[resultIndex++] = loanId;
        }
    }

    function previewBorrow(
        uint256 basketId,
        uint256 collateralUnits,
        uint40 duration
    ) external view basketExists(basketId) returns (BorrowPreview memory preview) {
        if (collateralUnits == 0) revert InvalidCollateralUnits();

        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        _validateDuration(lending.lendingConfigs[basketId], duration);

        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(basket, collateralUnits, LibLendingStorage.DEFAULT_LTV_BPS);
        uint256 resultingLockedCollateral = lending.lockedCollateralUnits[basketId] + collateralUnits;

        preview.basketId = basketId;
        preview.collateralUnits = collateralUnits;
        preview.duration = duration;
        preview.assets = assets;
        preview.principals = principals;
        preview.feeNative =
            _selectBorrowFeeTier(lending.borrowFeeTiers[basketId], basketId, collateralUnits)
                .flatFeeNative;
        preview.maturity = uint40(block.timestamp + duration);
        preview.resultingLockedCollateral = resultingLockedCollateral;
        preview.invariantSatisfied = _redeemabilityInvariantSatisfied(
            basketId, basket, assets, principals, resultingLockedCollateral, basket.totalUnits
        );
    }

    function previewRepay(
        uint256 loanId
    ) external view returns (RepayPreview memory preview) {
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        LibLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrower == address(0) || lending.loanClosed[loanId]) revert LoanNotFound(loanId);

        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(LibEdenStorage.layout().baskets[loan.basketId], loan.collateralUnits, loan.ltvBps);
        preview = RepayPreview({
            loanId: loanId,
            assets: assets,
            principals: principals,
            unlockedCollateralUnits: loan.collateralUnits
        });
    }

    function previewExtend(
        uint256 loanId,
        uint40 addedDuration
    ) external view returns (ExtendPreview memory preview) {
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        (uint40 newMaturity, uint256 feeNative) =
            _validateAndQuoteExtension(lending, loanId, addedDuration, address(0));

        preview = ExtendPreview({
            loanId: loanId,
            addedDuration: addedDuration,
            newMaturity: uint40(newMaturity),
            feeNative: feeNative
        });
    }

    function _validateDuration(
        LibLendingStorage.LendingConfig memory config,
        uint40 duration
    ) internal pure {
        if (
            duration == 0 || config.minDuration == 0 || duration < config.minDuration
                || duration > config.maxDuration
        ) {
            revert InvalidDuration(duration, config.minDuration, config.maxDuration);
        }
    }

    function _createLoan(
        LibLendingStorage.LendingStorage storage lending,
        uint256 basketId,
        uint256 collateralUnits,
        uint40 maturity,
        address borrower
    ) internal returns (uint256 loanId) {
        loanId = lending.nextLoanId;
        lending.nextLoanId = loanId + 1;
        lending.loans[loanId] = LibLendingStorage.Loan({
            borrower: borrower,
            basketId: basketId,
            collateralUnits: collateralUnits,
            ltvBps: LibLendingStorage.DEFAULT_LTV_BPS,
            maturity: maturity
        });
    }

    function _validateAndQuoteExtension(
        LibLendingStorage.LendingStorage storage lending,
        uint256 loanId,
        uint40 addedDuration,
        address expectedBorrower
    ) internal view returns (uint40 newMaturity, uint256 feeNative) {
        LibLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrower == address(0) || lending.loanClosed[loanId]) revert LoanNotFound(loanId);
        if (expectedBorrower != address(0) && expectedBorrower != loan.borrower) {
            revert NotBorrower(expectedBorrower, loan.borrower);
        }
        if (block.timestamp > loan.maturity) revert LoanExpired(loanId, loan.maturity);

        LibLendingStorage.LendingConfig memory config = lending.lendingConfigs[loan.basketId];
        if (addedDuration == 0 || config.maxDuration == 0) {
            revert InvalidDuration(addedDuration, config.minDuration, config.maxDuration);
        }

        uint256 extendedMaturity = uint256(loan.maturity) + addedDuration;
        uint256 maxAllowedMaturity = block.timestamp + config.maxDuration;
        if (extendedMaturity > maxAllowedMaturity) {
            revert InvalidDuration(uint256(addedDuration), config.minDuration, config.maxDuration);
        }

        newMaturity = uint40(extendedMaturity);
        feeNative = _selectBorrowFeeTier(
            lending.borrowFeeTiers[loan.basketId], loan.basketId, loan.collateralUnits
        ).flatFeeNative;
    }

    function _applyExtension(
        LibLendingStorage.LendingStorage storage lending,
        uint256 loanId,
        uint40 newMaturity,
        uint256 feeNative
    ) internal {
        lending.loans[loanId].maturity = newMaturity;
        emit LoanExtended(loanId, newMaturity, feeNative);
    }

    function _executeBorrowPayouts(
        uint256 basketId,
        address[] memory assets,
        uint256[] memory principals,
        address borrower
    ) internal {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibLendingStorage.LendingStorage storage lending = LibLendingStorage.layout();
        uint256 len = assets.length;

        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            uint256 principal = principals[i];
            store.vaultBalances[basketId][asset] -= principal;
            lending.outstandingPrincipal[basketId][asset] += principal;
            _transferAsset(asset, borrower, principal);
        }
    }

    function _selectBorrowFeeTier(
        LibLendingStorage.BorrowFeeTier[] storage tiers,
        uint256 basketId,
        uint256 collateralUnits
    ) internal view returns (LibLendingStorage.BorrowFeeTier memory tier) {
        uint256 len = tiers.length;
        if (len == 0) revert BelowMinimumTier(basketId, collateralUnits);

        bool found;
        for (uint256 i = 0; i < len; i++) {
            if (collateralUnits >= tiers[i].minCollateralUnits) {
                tier = tiers[i];
                found = true;
            } else {
                break;
            }
        }

        if (!found) revert BelowMinimumTier(basketId, collateralUnits);
    }

    function _findBorrowFeeTier(
        LibLendingStorage.BorrowFeeTier[] storage tiers,
        uint256 collateralUnits
    ) internal view returns (bool found, uint256 flatFeeNative) {
        uint256 len = tiers.length;
        for (uint256 i = 0; i < len; i++) {
            if (collateralUnits >= tiers[i].minCollateralUnits) {
                found = true;
                flatFeeNative = tiers[i].flatFeeNative;
            } else {
                break;
            }
        }
    }

    function _deriveLoanPrincipals(
        LibEdenStorage.Basket storage basket,
        uint256 collateralUnits,
        uint16 ltvBps
    ) internal view returns (address[] memory assets, uint256[] memory principals) {
        uint256 len = basket.assets.length;
        assets = new address[](len);
        principals = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            assets[i] = basket.assets[i];
            principals[i] = Math.mulDiv(
                collateralUnits, basket.bundleAmounts[i] * ltvBps, UNIT_SCALE * BASIS_POINTS
            );
        }
    }

    function _sliceLoanIds(
        uint256[] storage source,
        uint256 start,
        uint256 limit
    ) internal view returns (uint256[] memory loanIds) {
        uint256 len = source.length;
        if (start >= len || limit == 0) {
            return new uint256[](0);
        }

        uint256 remaining = len - start;
        uint256 resultLen = remaining < limit ? remaining : limit;
        loanIds = new uint256[](resultLen);
        for (uint256 i = 0; i < resultLen; i++) {
            loanIds[i] = source[start + i];
        }
    }

    function _isActiveLoan(
        LibLendingStorage.LendingStorage storage lending,
        uint256 loanId,
        LibLendingStorage.Loan storage loan
    ) internal view returns (bool) {
        return loan.borrower != address(0) && !lending.loanClosed[loanId] && block.timestamp <= loan.maturity;
    }

    function _redeemabilityInvariantSatisfied(
        uint256 basketId,
        LibEdenStorage.Basket storage basket,
        address[] memory assets,
        uint256[] memory principals,
        uint256 lockedCollateralUnits,
        uint256 totalUnits
    ) internal view returns (bool) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 redeemableSupply = totalUnits - lockedCollateralUnits;
        uint256 len = assets.length;

        for (uint256 i = 0; i < len; i++) {
            uint256 currentVault = store.vaultBalances[basketId][assets[i]];
            if (currentVault < principals[i]) return false;

            uint256 remainingVault = currentVault - principals[i];
            uint256 requiredVault =
                Math.mulDiv(redeemableSupply, basket.bundleAmounts[i], UNIT_SCALE);
            if (remainingVault < requiredVault) return false;
        }

        return true;
    }

    function _enforceRedeemabilityInvariant(
        uint256 basketId,
        LibEdenStorage.Basket storage basket,
        address[] memory assets,
        uint256[] memory principals,
        uint256 lockedCollateralUnits,
        uint256 totalUnits
    ) internal view {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 redeemableSupply = totalUnits - lockedCollateralUnits;

        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 currentVault = store.vaultBalances[basketId][assets[i]];
            if (currentVault < principals[i]) {
                revert InsufficientVaultBalance(assets[i], principals[i], currentVault);
            }

            uint256 remainingVault = currentVault - principals[i];
            uint256 requiredVault =
                Math.mulDiv(redeemableSupply, basket.bundleAmounts[i], UNIT_SCALE);
            if (remainingVault < requiredVault) {
                revert RedeemabilityInvariantBroken(assets[i], requiredVault, remainingVault);
            }
        }
    }

    function _enforcePostRecoveryInvariant(
        uint256 basketId,
        LibEdenStorage.Basket storage basket,
        uint256 lockedCollateralUnits,
        uint256 totalUnits
    ) internal view {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 redeemableSupply = totalUnits - lockedCollateralUnits;
        uint256 len = basket.assets.length;

        for (uint256 i = 0; i < len; i++) {
            address asset = basket.assets[i];
            uint256 currentVault = store.vaultBalances[basketId][asset];
            uint256 requiredVault =
                Math.mulDiv(redeemableSupply, basket.bundleAmounts[i], UNIT_SCALE);
            if (currentVault < requiredVault) {
                revert RedeemabilityInvariantBroken(asset, requiredVault, currentVault);
            }
        }
    }

    function _requireNativeFee(
        uint256 expected
    ) internal view {
        if (msg.value != expected) revert UnexpectedNativeFee(expected, msg.value);
    }

    function _forwardNativeFee(
        uint256 amount
    ) internal {
        if (amount == 0) return;

        address treasury = LibEdenStorage.layout().treasury;
        if (treasury == address(0)) revert TreasuryNotSet();

        (bool success,) = treasury.call{ value: amount }("");
        if (!success) revert NativeTransferFailed(treasury, amount);
    }

    function _transferAsset(
        address asset,
        address to,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        if (asset == address(0)) revert NativeAssetUnsupported();
        IERC20(asset).safeTransfer(to, amount);
    }
}
