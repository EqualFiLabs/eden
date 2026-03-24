// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IEdenCoreFacet } from "src/interfaces/IEdenCoreFacet.sol";
import { EdenReentrancyGuard } from "src/facets/EdenReentrancyGuard.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";
import { StEVEToken } from "src/tokens/StEVEToken.sol";

contract EdenCoreFacet is EdenReentrancyGuard, IEdenCoreFacet {
    using SafeERC20 for IERC20;

    uint256 internal constant BASIS_POINTS = 10_000;
    uint256 internal constant UNIT_SCALE = 1e18;

    bytes32 internal constant FEE_POT_BUY_IN_SOURCE = keccak256("FEE_POT_BUY_IN");
    bytes32 internal constant MINT_FEE_SOURCE = keccak256("MINT_FEE");
    bytes32 internal constant BURN_FEE_SOURCE = keccak256("BURN_FEE");
    bytes32 internal constant PROTOCOL_FEE_SELF_SOURCE = keccak256("PROTOCOL_FEE_SELF");
    bytes32 internal constant PROTOCOL_FEE_STEVE_SOURCE = keccak256("PROTOCOL_FEE_STEVE");
    bytes32 internal constant PROTOCOL_FEE_ORIGIN_SOURCE = keccak256("PROTOCOL_FEE_ORIGIN");

    error Unauthorized();
    error InvalidArrayLength();
    error InvalidBundleDefinition();
    error InvalidUnits();
    error UnknownBasket(uint256 basketId);
    error BasketPaused(uint256 basketId);
    error PermissionlessCreationDisabled();
    error IncorrectBasketCreationFee(uint256 expected, uint256 actual);
    error GovernanceBypassRequiresZeroMsgValue();
    error TreasuryNotSet();
    error NativeTransferFailed(address recipient, uint256 amount);
    error NativeAssetUnsupported();
    error FeeCapExceeded();
    error UnexpectedMsgValue(uint256 expected, uint256 actual);
    error InsufficientVaultBalance(address asset, uint256 expected, uint256 actual);
    struct MintQuote {
        address[] assets;
        uint256[] baseDeposits;
        uint256[] grossInputs;
        uint256[] totalRequired;
        uint256[] potBuyIns;
        uint256[] feeAmounts;
    }

    struct BurnQuote {
        address[] assets;
        uint256[] bundleOutputs;
        uint256[] payoutAmounts;
        uint256[] potShares;
        uint256[] feeAmounts;
    }

    modifier basketExists(
        uint256 basketId
    ) {
        if (basketId >= LibEdenStorage.layout().basketCount) revert UnknownBasket(basketId);
        _;
    }

    function createBasket(
        CreateBasketParams calldata params
    ) external payable nonReentrant returns (uint256 basketId, address token) {
        _validateCreateBasketParams(params);
        _handleBasketCreationFee();

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        basketId = store.basketCount;
        store.basketCount = basketId + 1;

        if (basketId == 0) {
            store.steveBasketId = 0;
            token = address(new StEVEToken(params.name, params.symbol, address(this)));
        } else {
            token = address(new BasketToken(params.name, params.symbol, address(this)));
        }

        LibEdenStorage.Basket storage basket = store.baskets[basketId];
        basket.assets = params.assets;
        basket.bundleAmounts = params.bundleAmounts;
        basket.mintFeeBps = params.mintFeeBps;
        basket.burnFeeBps = params.burnFeeBps;
        basket.flashFeeBps = params.flashFeeBps;
        basket.token = token;
        basket.paused = false;

        store.basketMetadata[basketId] = LibEdenStorage.BasketMetadata({
            name: params.name,
            symbol: params.symbol,
            uri: "",
            creator: msg.sender,
            createdAt: uint64(block.timestamp),
            basketType: basketId == 0 ? uint8(1) : uint8(0)
        });

        emit BasketCreated(basketId, msg.sender, token, params.assets, params.bundleAmounts);
    }

    function mint(
        uint256 basketId,
        uint256 units,
        address to
    ) external nonReentrant basketExists(basketId) returns (uint256 minted) {
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();

        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        if (basket.paused) revert BasketPaused(basketId);

        MintQuote memory quote = _previewMintQuote(basketId, units);
        _collectMintInputs(quote);

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 len = quote.assets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = quote.assets[i];
            store.vaultBalances[basketId][asset] += quote.baseDeposits[i];

            if (quote.potBuyIns[i] > 0) {
                store.feePots[basketId][asset] += quote.potBuyIns[i];
                emit FeePotAccrued(basketId, asset, quote.potBuyIns[i], FEE_POT_BUY_IN_SOURCE);
            }

            _distributeFee(basketId, asset, quote.feeAmounts[i], MINT_FEE_SOURCE);
        }

        basket.totalUnits += units;
        BasketToken(basket.token).mintIndexUnits(to, units);

        emit Minted(basketId, msg.sender, units, quote.totalRequired, quote.feeAmounts);
        return units;
    }

    function burn(
        uint256 basketId,
        uint256 units,
        address to
    ) external nonReentrant basketExists(basketId) returns (uint256[] memory assetsOut) {
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();

        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        if (basket.paused) revert BasketPaused(basketId);
        if (units > basket.totalUnits) revert InvalidUnits();

        BurnQuote memory quote = _previewBurnQuote(basketId, units);
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 len = quote.assets.length;

        for (uint256 i = 0; i < len; i++) {
            address asset = quote.assets[i];
            store.vaultBalances[basketId][asset] -= quote.bundleOutputs[i];
            store.feePots[basketId][asset] -= quote.potShares[i];
            _distributeFee(basketId, asset, quote.feeAmounts[i], BURN_FEE_SOURCE);
        }

        basket.totalUnits -= units;
        BasketToken(basket.token).burnIndexUnits(msg.sender, units);

        for (uint256 i = 0; i < len; i++) {
            _transferAsset(quote.assets[i], to, quote.payoutAmounts[i]);
        }

        emit Burned(basketId, msg.sender, units, quote.payoutAmounts, quote.feeAmounts);
        return quote.payoutAmounts;
    }

    function previewMint(
        uint256 basketId,
        uint256 units
    )
        external
        view
        virtual
        basketExists(basketId)
        returns (address[] memory assets, uint256[] memory required, uint256[] memory feeAmounts)
    {
        MintQuote memory quote = _previewMintQuote(basketId, units);
        return (quote.assets, quote.totalRequired, quote.feeAmounts);
    }

    function previewBurn(
        uint256 basketId,
        uint256 units
    )
        external
        view
        virtual
        basketExists(basketId)
        returns (address[] memory assets, uint256[] memory returned, uint256[] memory feeAmounts)
    {
        BurnQuote memory quote = _previewBurnQuote(basketId, units);
        return (quote.assets, quote.payoutAmounts, quote.feeAmounts);
    }

    function _previewMintQuote(
        uint256 basketId,
        uint256 units
    ) internal view returns (MintQuote memory quote) {
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibEdenStorage.Basket storage basket = store.baskets[basketId];
        uint256 len = basket.assets.length;
        uint256 totalSupply = basket.totalUnits;

        quote.assets = basket.assets;
        quote.baseDeposits = new uint256[](len);
        quote.grossInputs = new uint256[](len);
        quote.totalRequired = new uint256[](len);
        quote.potBuyIns = new uint256[](len);
        quote.feeAmounts = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address asset = basket.assets[i];
            uint256 baseDeposit;
            uint256 potBuyIn;

            if (totalSupply == 0) {
                baseDeposit = Math.mulDiv(basket.bundleAmounts[i], units, UNIT_SCALE);
            } else {
                uint256 economicBalance = _economicBalance(basketId, asset);
                baseDeposit = Math.mulDiv(economicBalance, units, totalSupply, Math.Rounding.Ceil);
                potBuyIn = Math.mulDiv(
                    store.feePots[basketId][asset], units, totalSupply, Math.Rounding.Ceil
                );
            }

            uint256 grossInput = baseDeposit + potBuyIn;
            uint256 fee =
                Math.mulDiv(grossInput, basket.mintFeeBps[i], BASIS_POINTS, Math.Rounding.Ceil);

            quote.baseDeposits[i] = baseDeposit;
            quote.grossInputs[i] = grossInput;
            quote.potBuyIns[i] = potBuyIn;
            quote.feeAmounts[i] = fee;
            quote.totalRequired[i] = grossInput + fee;
        }
    }

    function _previewBurnQuote(
        uint256 basketId,
        uint256 units
    ) internal view returns (BurnQuote memory quote) {
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibEdenStorage.Basket storage basket = store.baskets[basketId];
        uint256 totalSupply = basket.totalUnits;
        if (units > totalSupply) revert InvalidUnits();

        uint256 len = basket.assets.length;
        quote.assets = basket.assets;
        quote.bundleOutputs = new uint256[](len);
        quote.payoutAmounts = new uint256[](len);
        quote.potShares = new uint256[](len);
        quote.feeAmounts = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address asset = basket.assets[i];
            uint256 bundleOut = Math.mulDiv(basket.bundleAmounts[i], units, UNIT_SCALE);
            uint256 vaultBalance = store.vaultBalances[basketId][asset];
            if (vaultBalance < bundleOut) {
                revert InsufficientVaultBalance(asset, bundleOut, vaultBalance);
            }

            uint256 potShare = Math.mulDiv(store.feePots[basketId][asset], units, totalSupply);
            uint256 gross = bundleOut + potShare;
            uint256 fee = Math.mulDiv(gross, basket.burnFeeBps[i], BASIS_POINTS);
            uint256 payout = gross - fee;

            quote.bundleOutputs[i] = bundleOut;
            quote.potShares[i] = potShare;
            quote.feeAmounts[i] = fee;
            quote.payoutAmounts[i] = payout;
        }
    }

    function _collectMintInputs(
        MintQuote memory quote
    ) internal {
        uint256 len = quote.assets.length;
        for (uint256 i = 0; i < len; i++) {
            if (_isNative(quote.assets[i])) {
                revert NativeAssetUnsupported();
            }
        }

        for (uint256 i = 0; i < len; i++) {
            if (_isNative(quote.assets[i])) continue;
            IERC20(quote.assets[i])
                .safeTransferFrom(msg.sender, address(this), quote.totalRequired[i]);
        }
    }

    function _distributeFee(
        uint256 basketId,
        address asset,
        uint256 fee,
        bytes32 source
    ) internal {
        if (fee == 0) return;

        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        uint256 treasuryShare = Math.mulDiv(fee, store.treasuryFeeBps, BASIS_POINTS);
        uint256 remainder = fee - treasuryShare;
        uint256 feePotDirect = Math.mulDiv(remainder, store.feePotShareBps, BASIS_POINTS);
        uint256 protocolFeeAmount = remainder - feePotDirect;

        if (treasuryShare > 0) {
            address treasury = store.treasury;
            if (treasury == address(0)) revert TreasuryNotSet();
            _transferAsset(asset, treasury, treasuryShare);
        }

        if (feePotDirect > 0) {
            store.feePots[basketId][asset] += feePotDirect;
            emit FeePotAccrued(basketId, asset, feePotDirect, source);
        }

        _routeProtocolFee(basketId, asset, protocolFeeAmount);
    }

    function _routeProtocolFee(
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

        uint256 steveShare = Math.mulDiv(amount, store.protocolFeeSplitBps, BASIS_POINTS);
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

    function _validateCreateBasketParams(
        CreateBasketParams calldata params
    ) internal pure {
        uint256 len = params.assets.length;
        if (len == 0 || len != params.bundleAmounts.length) revert InvalidArrayLength();
        if (params.mintFeeBps.length != len || params.burnFeeBps.length != len) {
            revert InvalidArrayLength();
        }
        if (params.flashFeeBps > 1000) revert FeeCapExceeded();

        for (uint256 i = 0; i < len; i++) {
            if (params.bundleAmounts[i] == 0) revert InvalidBundleDefinition();
            if (params.mintFeeBps[i] > 1000 || params.burnFeeBps[i] > 1000) {
                revert FeeCapExceeded();
            }

            for (uint256 j = i + 1; j < len; j++) {
                if (params.assets[i] == params.assets[j]) revert InvalidBundleDefinition();
            }
        }
    }

    function _handleBasketCreationFee() internal {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        bool isGov = _isOwnerOrTimelock(msg.sender, store);
        if (isGov) {
            if (msg.value != 0) revert GovernanceBypassRequiresZeroMsgValue();
            return;
        }

        uint256 fee = store.basketCreationFee;
        if (fee == 0) revert PermissionlessCreationDisabled();
        if (msg.value != fee) revert IncorrectBasketCreationFee(fee, msg.value);

        address treasury = store.treasury;
        if (treasury == address(0)) revert TreasuryNotSet();

        (bool sent,) = treasury.call{ value: fee }("");
        if (!sent) revert NativeTransferFailed(treasury, fee);
    }

    function _economicBalance(
        uint256 basketId,
        address asset
    ) internal view returns (uint256) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        return store.vaultBalances[basketId][asset]
            + LibLendingStorage.layout().outstandingPrincipal[basketId][asset];
    }

    function _transferAsset(
        address asset,
        address to,
        uint256 amount
    ) internal {
        if (amount == 0) return;

        if (_isNative(asset)) {
            (bool sent,) = payable(to).call{ value: amount }("");
            if (!sent) revert NativeTransferFailed(to, amount);
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function _isOwnerOrTimelock(
        address caller,
        LibEdenStorage.EdenStorage storage store
    ) internal view returns (bool) {
        return caller == store.owner || caller == store.timelock;
    }

    function _isNative(
        address asset
    ) internal pure returns (bool) {
        return asset == address(0);
    }
}
