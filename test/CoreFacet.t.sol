// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenCoreFacet } from "src/interfaces/IEdenCoreFacet.sol";
import { IEdenTwabHook } from "src/interfaces/IEdenTwabHook.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";
import { StEVEToken } from "src/tokens/StEVEToken.sol";

contract MockERC20 is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) { }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

contract CoreHarnessFacet is EdenCoreFacet, IEdenTwabHook {
    function setCoreConfig(
        address treasury,
        uint256 treasuryFeeBps,
        uint256 feePotShareBps,
        uint256 protocolFeeSplitBps,
        uint256 basketCreationFee
    ) external {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        store.treasury = treasury;
        store.treasuryFeeBps = uint16(treasuryFeeBps);
        store.feePotShareBps = uint16(feePotShareBps);
        store.protocolFeeSplitBps = uint16(protocolFeeSplitBps);
        store.basketCreationFee = basketCreationFee;
    }

    function setOutstandingPrincipal(
        uint256 basketId,
        address asset,
        uint256 amount
    ) external {
        LibLendingStorage.layout().outstandingPrincipal[basketId][asset] = amount;
    }

    function setVaultBalance(
        uint256 basketId,
        address asset,
        uint256 amount
    ) external {
        LibEdenStorage.layout().vaultBalances[basketId][asset] = amount;
    }

    function setFeePot(
        uint256 basketId,
        address asset,
        uint256 amount
    ) external {
        LibEdenStorage.layout().feePots[basketId][asset] = amount;
    }

    function setPaused(
        uint256 basketId,
        bool paused
    ) external {
        LibEdenStorage.layout().baskets[basketId].paused = paused;
    }

    function getBasketCount() external view returns (uint256) {
        return LibEdenStorage.layout().basketCount;
    }

    function getSteveBasketId() external view returns (uint256) {
        return LibEdenStorage.layout().steveBasketId;
    }

    function getBasket(
        uint256 basketId
    ) external view returns (LibEdenStorage.Basket memory basket) {
        basket = LibEdenStorage.layout().baskets[basketId];
    }

    function getVaultBalance(
        uint256 basketId,
        address asset
    ) external view returns (uint256) {
        return LibEdenStorage.layout().vaultBalances[basketId][asset];
    }

    function getFeePot(
        uint256 basketId,
        address asset
    ) external view returns (uint256) {
        return LibEdenStorage.layout().feePots[basketId][asset];
    }

    function getOutstandingPrincipal(
        uint256 basketId,
        address asset
    ) external view returns (uint256) {
        return LibLendingStorage.layout().outstandingPrincipal[basketId][asset];
    }

    function getBasketMetadata(
        uint256 basketId
    ) external view returns (LibEdenStorage.BasketMetadata memory metadata) {
        metadata = LibEdenStorage.layout().basketMetadata[basketId];
    }

    function setProtocolMetadata(
        string calldata protocolURI_,
        string calldata contractVersion_,
        address facet,
        string calldata facetVersion_
    ) external {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        store.protocolURI = protocolURI_;
        store.contractVersion = contractVersion_;
        store.facetVersions[facet] = facetVersion_;
    }

    function getProtocolURI() external view returns (string memory) {
        return LibEdenStorage.layout().protocolURI;
    }

    function getContractVersion() external view returns (string memory) {
        return LibEdenStorage.layout().contractVersion;
    }

    function getFacetVersion(
        address facet
    ) external view returns (string memory) {
        return LibEdenStorage.layout().facetVersions[facet];
    }

    function exposeDistributeFee(
        uint256 basketId,
        address asset,
        uint256 fee,
        bytes32 source
    ) external {
        _distributeFee(basketId, asset, fee, source);
    }

    function onStEVETransfer(
        address,
        address,
        uint256
    ) external { }
}

contract CoreFacetTest is Test {
    bytes32 internal constant TEST_FEE_SOURCE = keccak256("TEST_FEE");
    uint256 internal constant UNIT = 1e18;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    EdenDiamond internal diamond;
    CoreHarnessFacet internal coreFacet;
    MockERC20 internal eve;
    MockERC20 internal alt;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        coreFacet = new CoreHarnessFacet();
        eve = new MockERC20("EVE", "EVE");
        alt = new MockERC20("ALT", "ALT");

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_coreCuts(), address(0), "");

        vm.prank(owner);
        CoreHarnessFacet(address(diamond)).setCoreConfig(treasury, 1000, 6000, 7500, 0);

        eve.mint(alice, 1_000_000e18);
        eve.mint(bob, 1_000_000e18);
        alt.mint(alice, 1_000_000e18);
        alt.mint(bob, 1_000_000e18);
    }

    function test_CreateBasket_SequentialIdsAndTokenDeployment() public {
        (uint256 basket0, address token0) = _createSteveBasket(owner);
        (uint256 basket1, address token1) =
            _createSingleAssetBasket(owner, address(eve), 100e18, 0, 0);

        assertEq(basket0, 0);
        assertEq(basket1, 1);
        assertEq(CoreHarnessFacet(address(diamond)).getBasketCount(), 2);
        assertTrue(token0 != address(0));
        assertTrue(token1 != address(0));
        assertEq(BasketToken(token0).minter(), address(diamond));
        assertEq(BasketToken(token1).minter(), address(diamond));
    }

    function test_CreateBasket_GovernanceBypassAndValueRevert() public {
        vm.prank(owner);
        CoreHarnessFacet(address(diamond)).setCoreConfig(treasury, 1000, 6000, 7500, 1 ether);

        _createSteveBasket(owner);
        vm.deal(owner, 1 ether);
        assertEq(treasury.balance, 0);

        vm.prank(owner);
        vm.expectRevert(EdenCoreFacet.GovernanceBypassRequiresZeroMsgValue.selector);
        IEdenCoreFacet(address(diamond)).createBasket{ value: 1 ether }(_steveParams());
    }

    function test_CreateBasket_PermissionlessCreationFeeEnforced() public {
        vm.prank(owner);
        CoreHarnessFacet(address(diamond)).setCoreConfig(treasury, 1000, 6000, 7500, 1 ether);

        vm.deal(alice, 1 ether);
        IEdenCoreFacet.CreateBasketParams memory params = _steveParams();

        vm.prank(alice);
        (uint256 basketId,) =
            IEdenCoreFacet(address(diamond)).createBasket{ value: 1 ether }(params);

        assertEq(basketId, 0);
        assertEq(treasury.balance, 1 ether);
    }

    function test_CreateBasket_PermissionlessDisabledAndValidation() public {
        vm.prank(alice);
        vm.expectRevert(EdenCoreFacet.PermissionlessCreationDisabled.selector);
        IEdenCoreFacet(address(diamond)).createBasket(_steveParams());

        IEdenCoreFacet.CreateBasketParams memory zeroBundle =
            _singleAssetParams("Bad", "BAD", address(eve), 0, 0, 0);
        vm.prank(owner);
        vm.expectRevert(EdenCoreFacet.InvalidBundleDefinition.selector);
        IEdenCoreFacet(address(diamond)).createBasket(zeroBundle);

        address[] memory dupAssets = new address[](2);
        dupAssets[0] = address(eve);
        dupAssets[1] = address(eve);
        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 1e18;
        bundleAmounts[1] = 2e18;
        uint16[] memory mintFeeBps = new uint16[](2);
        uint16[] memory burnFeeBps = new uint16[](2);

        IEdenCoreFacet.CreateBasketParams memory dupParams = IEdenCoreFacet.CreateBasketParams({
            name: "Dup",
            symbol: "DUP",
            assets: dupAssets,
            bundleAmounts: bundleAmounts,
            mintFeeBps: mintFeeBps,
            burnFeeBps: burnFeeBps,
            flashFeeBps: 0
        });

        vm.prank(owner);
        vm.expectRevert(EdenCoreFacet.InvalidBundleDefinition.selector);
        IEdenCoreFacet(address(diamond)).createBasket(dupParams);

        IEdenCoreFacet.CreateBasketParams memory highFee =
            _singleAssetParams("High", "HIGH", address(eve), 1e18, 1001, 0);
        vm.prank(owner);
        vm.expectRevert(EdenCoreFacet.FeeCapExceeded.selector);
        IEdenCoreFacet(address(diamond)).createBasket(highFee);
    }

    function test_CreateBasket_StEVEIsBasketZero() public {
        (uint256 basketId, address token) = _createSteveBasket(owner);

        LibEdenStorage.Basket memory basket = CoreHarnessFacet(address(diamond)).getBasket(basketId);
        assertEq(basketId, 0);
        assertEq(CoreHarnessFacet(address(diamond)).getSteveBasketId(), 0);
        assertEq(basket.assets.length, 1);
        assertEq(basket.assets[0], address(eve));
        assertEq(basket.bundleAmounts[0], 1000e18);

        (bool success,) =
            token.staticcall(abi.encodeWithSelector(bytes4(keccak256("delegates(address)")), alice));
        assertTrue(success);
    }

    function test_StorageExtensions_BasketMetadataAndProtocolMetadataPersist() public {
        (uint256 steveBasketId,) = _createSteveBasket(owner);
        (uint256 basketId,) = _createSingleAssetBasket(owner, address(eve), 100e18, 0, 0);

        vm.prank(owner);
        CoreHarnessFacet(address(diamond)).setProtocolMetadata(
            "ipfs://eden-protocol", "1.0.0", address(coreFacet), "core-v1"
        );

        LibEdenStorage.BasketMetadata memory steveMetadata =
            CoreHarnessFacet(address(diamond)).getBasketMetadata(steveBasketId);
        assertEq(steveMetadata.name, "stEVE");
        assertEq(steveMetadata.symbol, "stEVE");
        assertEq(steveMetadata.uri, "");
        assertEq(steveMetadata.creator, owner);
        assertEq(steveMetadata.createdAt, uint64(block.timestamp));
        assertEq(steveMetadata.basketType, 1);

        LibEdenStorage.BasketMetadata memory basketMetadata =
            CoreHarnessFacet(address(diamond)).getBasketMetadata(basketId);
        assertEq(basketMetadata.name, "Basket");
        assertEq(basketMetadata.symbol, "BASK");
        assertEq(basketMetadata.uri, "");
        assertEq(basketMetadata.creator, owner);
        assertEq(basketMetadata.createdAt, uint64(block.timestamp));
        assertEq(basketMetadata.basketType, 0);

        assertEq(CoreHarnessFacet(address(diamond)).getProtocolURI(), "ipfs://eden-protocol");
        assertEq(CoreHarnessFacet(address(diamond)).getContractVersion(), "1.0.0");
        assertEq(CoreHarnessFacet(address(diamond)).getFacetVersion(address(coreFacet)), "core-v1");
    }

    function test_FeeWaterfall_ConservationAndNonSteveRouting() public {
        _createSteveBasket(owner);
        _createSingleAssetBasket(owner, address(eve), 100e18, 0, 0);

        eve.mint(address(diamond), 100e18);
        CoreHarnessFacet(address(diamond))
            .exposeDistributeFee(1, address(eve), 100e18, TEST_FEE_SOURCE);

        uint256 treasuryShare = 10e18;
        uint256 feePotDirect = 54e18;
        uint256 protocolFeeAmount = 36e18;
        uint256 steveShare = 27e18;
        uint256 basketShare = 9e18;

        assertEq(eve.balanceOf(treasury), treasuryShare);
        assertEq(
            CoreHarnessFacet(address(diamond)).getFeePot(1, address(eve)),
            feePotDirect + basketShare
        );
        assertEq(CoreHarnessFacet(address(diamond)).getFeePot(0, address(eve)), steveShare);
        assertEq(treasuryShare + feePotDirect + protocolFeeAmount, 100e18);
        assertEq(steveShare + basketShare, protocolFeeAmount);
    }

    function test_FeeWaterfall_StEveSelfRouting() public {
        _createSteveBasket(owner);

        eve.mint(address(diamond), 100e18);
        CoreHarnessFacet(address(diamond))
            .exposeDistributeFee(0, address(eve), 100e18, TEST_FEE_SOURCE);

        assertEq(eve.balanceOf(treasury), 10e18);
        assertEq(CoreHarnessFacet(address(diamond)).getFeePot(0, address(eve)), 90e18);
    }

    function test_Mint_FirstMintPricingAndStateUpdates() public {
        _createSteveBasket(owner);
        _createSingleAssetBasket(owner, address(eve), 100e18, 1000, 0);

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);
        vm.stopPrank();

        assertEq(eve.balanceOf(alice), 1_000_000e18 - 110e18);
        assertEq(CoreHarnessFacet(address(diamond)).getVaultBalance(1, address(eve)), 100e18);
        assertEq(CoreHarnessFacet(address(diamond)).getFeePot(1, address(eve)), 63e17);
        assertEq(CoreHarnessFacet(address(diamond)).getFeePot(0, address(eve)), 27e17);
        assertEq(
            BasketToken(CoreHarnessFacet(address(diamond)).getBasket(1).token).balanceOf(alice),
            UNIT
        );
        assertEq(CoreHarnessFacet(address(diamond)).getBasket(1).totalUnits, UNIT);
        assertEq(eve.balanceOf(treasury), 1e18);
    }

    function test_Mint_EconomicBalancePricingAndPreviewAccuracy() public {
        _createSteveBasket(owner);
        _createSingleAssetBasket(owner, address(eve), 100e18, 0, 0);

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);
        vm.stopPrank();

        CoreHarnessFacet(address(diamond)).setFeePot(1, address(eve), 10e18);
        CoreHarnessFacet(address(diamond)).setOutstandingPrincipal(1, address(eve), 50e18);

        (address[] memory assets, uint256[] memory required, uint256[] memory fees) =
            EdenCoreFacet(address(diamond)).previewMint(1, UNIT);

        assertEq(assets.length, 1);
        assertEq(assets[0], address(eve));
        assertEq(required[0], 160e18);
        assertEq(fees[0], 0);

        uint256 balanceBefore = eve.balanceOf(alice);
        vm.startPrank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);
        vm.stopPrank();

        assertEq(balanceBefore - eve.balanceOf(alice), required[0]);
        assertEq(CoreHarnessFacet(address(diamond)).getVaultBalance(1, address(eve)), 250e18);
        assertEq(CoreHarnessFacet(address(diamond)).getFeePot(1, address(eve)), 20e18);

        uint256 navBefore = (100e18 + 50e18 + 10e18) * UNIT / UNIT;
        uint256 navAfter = (250e18 + 50e18 + 20e18) * UNIT / (2 * UNIT);
        assertGe(navAfter, navBefore);
    }

    function test_Mint_FeeDistributionAndInsufficientBalanceRevert() public {
        _createSteveBasket(owner);
        _createSingleAssetBasket(owner, address(eve), 100e18, 1000, 0);

        address carol = makeAddr("carol");
        vm.startPrank(carol);
        eve.approve(address(diamond), type(uint256).max);
        vm.expectRevert();
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, carol);
        vm.stopPrank();

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);
        vm.stopPrank();

        assertEq(eve.balanceOf(treasury), 1e18);
        assertEq(CoreHarnessFacet(address(diamond)).getFeePot(1, address(eve)), 63e17);
        assertEq(CoreHarnessFacet(address(diamond)).getFeePot(0, address(eve)), 27e17);
    }

    function test_Burn_FixedBundlePricingAndPreviewAccuracy() public {
        _createSteveBasket(owner);
        _createSingleAssetBasket(owner, address(eve), 100e18, 0, 1000);

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);
        vm.stopPrank();

        CoreHarnessFacet(address(diamond)).setFeePot(1, address(eve), 20e18);

        (address[] memory assets, uint256[] memory returned, uint256[] memory fees) =
            EdenCoreFacet(address(diamond)).previewBurn(1, UNIT);

        assertEq(assets.length, 1);
        assertEq(assets[0], address(eve));
        assertEq(returned[0], 99e18);
        assertEq(fees[0], 11e18);

        uint256 balanceBefore = eve.balanceOf(alice);
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).burn(1, UNIT, alice);

        assertEq(eve.balanceOf(alice) - balanceBefore, returned[0]);
        assertEq(CoreHarnessFacet(address(diamond)).getVaultBalance(1, address(eve)), 100e18);
        assertEq(CoreHarnessFacet(address(diamond)).getFeePot(1, address(eve)), 1693e16);
        assertEq(CoreHarnessFacet(address(diamond)).getFeePot(0, address(eve)), 297e16);
        assertEq(eve.balanceOf(treasury), 11e17);
    }

    function test_Burn_StateUpdatesAndVaultRevert() public {
        _createSteveBasket(owner);
        _createSingleAssetBasket(owner, address(eve), 100e18, 0, 0);

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);
        vm.stopPrank();

        CoreHarnessFacet(address(diamond)).setVaultBalance(1, address(eve), 50e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                EdenCoreFacet.InsufficientVaultBalance.selector, address(eve), 100e18, 50e18
            )
        );
        IEdenCoreFacet(address(diamond)).burn(1, UNIT, alice);
    }

    function _createSteveBasket(
        address caller
    ) internal returns (uint256 basketId, address token) {
        vm.prank(caller);
        return IEdenCoreFacet(address(diamond)).createBasket(_steveParams());
    }

    function _createSingleAssetBasket(
        address caller,
        address asset,
        uint256 bundleAmount,
        uint16 mintFeeBps,
        uint16 burnFeeBps
    ) internal returns (uint256 basketId, address token) {
        vm.prank(caller);
        return IEdenCoreFacet(address(diamond))
            .createBasket(
                _singleAssetParams("Basket", "BASK", asset, bundleAmount, mintFeeBps, burnFeeBps)
            );
    }

    function _steveParams()
        internal
        view
        returns (IEdenCoreFacet.CreateBasketParams memory params)
    {
        return _singleAssetParams("stEVE", "stEVE", address(eve), 1000e18, 0, 0);
    }

    function _singleAssetParams(
        string memory name_,
        string memory symbol_,
        address asset,
        uint256 bundleAmount,
        uint16 mintFeeBps,
        uint16 burnFeeBps
    ) internal pure returns (IEdenCoreFacet.CreateBasketParams memory params) {
        address[] memory assets = new address[](1);
        assets[0] = asset;

        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = bundleAmount;

        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = mintFeeBps;

        uint16[] memory burnFees = new uint16[](1);
        burnFees[0] = burnFeeBps;

        return IEdenCoreFacet.CreateBasketParams({
            name: name_,
            symbol: symbol_,
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeBps: mintFees,
            burnFeeBps: burnFees,
            flashFeeBps: 0
        });
    }

    function _coreCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        bytes4[] memory selectors = new bytes4[](20);
        selectors[0] = IEdenCoreFacet.createBasket.selector;
        selectors[1] = IEdenCoreFacet.mint.selector;
        selectors[2] = IEdenCoreFacet.burn.selector;
        selectors[3] = EdenCoreFacet.previewMint.selector;
        selectors[4] = EdenCoreFacet.previewBurn.selector;
        selectors[5] = CoreHarnessFacet.setCoreConfig.selector;
        selectors[6] = CoreHarnessFacet.setOutstandingPrincipal.selector;
        selectors[7] = CoreHarnessFacet.setVaultBalance.selector;
        selectors[8] = CoreHarnessFacet.setFeePot.selector;
        selectors[9] = CoreHarnessFacet.setPaused.selector;
        selectors[10] = CoreHarnessFacet.getBasketCount.selector;
        selectors[11] = CoreHarnessFacet.getSteveBasketId.selector;
        selectors[12] = CoreHarnessFacet.getBasket.selector;
        selectors[13] = CoreHarnessFacet.getVaultBalance.selector;
        selectors[14] = CoreHarnessFacet.getFeePot.selector;
        selectors[15] = CoreHarnessFacet.getBasketMetadata.selector;
        selectors[16] = CoreHarnessFacet.setProtocolMetadata.selector;
        selectors[17] = CoreHarnessFacet.getProtocolURI.selector;
        selectors[18] = CoreHarnessFacet.getContractVersion.selector;
        selectors[19] = CoreHarnessFacet.getFacetVersion.selector;

        bytes4[] memory extraSelectors = new bytes4[](3);
        extraSelectors[0] = CoreHarnessFacet.getOutstandingPrincipal.selector;
        extraSelectors[1] = CoreHarnessFacet.exposeDistributeFee.selector;
        extraSelectors[2] = IEdenTwabHook.onStEVETransfer.selector;

        bytes4[] memory allSelectors = new bytes4[](selectors.length + extraSelectors.length);
        for (uint256 i = 0; i < selectors.length; i++) {
            allSelectors[i] = selectors[i];
        }
        for (uint256 i = 0; i < extraSelectors.length; i++) {
            allSelectors[selectors.length + i] = extraSelectors[i];
        }

        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(coreFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: allSelectors
        });
    }
}
