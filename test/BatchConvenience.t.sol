// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenBatchFacet } from "src/facets/EdenBatchFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenBatchFacet } from "src/interfaces/IEdenBatchFacet.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { IEdenTwabHook } from "src/interfaces/IEdenTwabHook.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { LibStEVEStorage } from "src/libraries/LibStEVEStorage.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";
import { StEVEToken } from "src/tokens/StEVEToken.sol";

contract BatchConvenienceMockERC20 is ERC20 {
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

contract BatchConvenienceHarnessFacet is EdenBatchFacet {
    function onBasketTokenTransfer(
        address,
        address,
        uint256
    ) external pure { }

    function setCoreConfig(
        address treasury,
        uint256 treasuryFeeBps,
        uint256 feePotShareBps,
        uint256 protocolFeeSplitBps
    ) external {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        store.treasury = treasury;
        store.treasuryFeeBps = uint16(treasuryFeeBps);
        store.feePotShareBps = uint16(feePotShareBps);
        store.protocolFeeSplitBps = uint16(protocolFeeSplitBps);
    }

    function setBasket(
        uint256 basketId,
        address token,
        address[] calldata assets,
        uint256[] calldata bundleAmounts,
        uint16[] calldata mintFeeBps,
        bool isSteve
    ) external {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        if (basketId >= store.basketCount) {
            store.basketCount = basketId + 1;
        }
        if (isSteve) {
            store.steveBasketId = basketId;
        }

        LibEdenStorage.Basket storage basket = store.baskets[basketId];
        delete basket.assets;
        delete basket.bundleAmounts;
        delete basket.mintFeeBps;
        delete basket.burnFeeBps;
        basket.token = token;
        basket.paused = false;
        basket.flashFeeBps = 0;

        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            basket.assets.push(assets[i]);
            basket.bundleAmounts.push(bundleAmounts[i]);
            basket.mintFeeBps.push(mintFeeBps[i]);
            basket.burnFeeBps.push(0);
        }
    }

    function setRewardConfig(
        uint256 genesisTimestamp,
        uint256 epochDuration,
        uint256 halvingInterval,
        uint256 maxPeriods,
        uint256 baseRewardPerEpoch,
        uint256 totalEpochs
    ) external {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        st.genesisTimestamp = genesisTimestamp;
        st.epochDuration = epochDuration;
        st.halvingInterval = halvingInterval;
        st.maxPeriods = maxPeriods;
        st.baseRewardPerEpoch = baseRewardPerEpoch;
        st.totalEpochs = totalEpochs;
        st.maxRewardPerEpochOverride = baseRewardPerEpoch;
    }

    function setRewardReserve(
        uint256 amount
    ) external {
        LibStEVEStorage.layout().rewardReserve = amount;
    }

    function mintReceiptUnits(
        uint256 basketId,
        address to,
        uint256 amount
    ) external {
        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        basket.totalUnits += amount;
        BasketToken(basket.token).mintIndexUnits(to, amount);
    }

    function setVaultBalance(
        uint256 basketId,
        address asset,
        uint256 amount
    ) external {
        LibEdenStorage.layout().vaultBalances[basketId][asset] = amount;
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

    function getRewardReserve() external view returns (uint256) {
        return LibStEVEStorage.layout().rewardReserve;
    }

    function getLastClaimedEpoch(
        address user
    ) external view returns (uint256) {
        return LibStEVEStorage.layout().lastClaimedEpoch[user];
    }

    function getLoan(
        uint256 loanId
    ) external view returns (LibLendingStorage.Loan memory) {
        return LibLendingStorage.layout().loans[loanId];
    }
}

contract BatchConvenienceTest is Test {
    uint256 internal constant UNIT = 1e18;
    bytes4 internal constant INVALID_ARRAY_LENGTH_SELECTOR =
        bytes4(keccak256("InvalidArrayLength()"));
    bytes4 internal constant INVALID_DURATION_SELECTOR =
        bytes4(keccak256("InvalidDuration(uint256,uint256,uint256)"));

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    EdenDiamond internal diamond;
    BatchConvenienceHarnessFacet internal batchFacet;
    BatchConvenienceMockERC20 internal rewardToken;
    BatchConvenienceMockERC20 internal altToken;
    StEVEToken internal stEveToken;
    BasketToken internal indexToken;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        batchFacet = new BatchConvenienceHarnessFacet();
        rewardToken = new BatchConvenienceMockERC20("EVE", "EVE");
        altToken = new BatchConvenienceMockERC20("ALT", "ALT");
        stEveToken = new StEVEToken("stEVE", "stEVE", address(diamond));
        indexToken = new BasketToken("Index", "IDX", address(diamond));

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");

        BatchConvenienceHarnessFacet(address(diamond)).setCoreConfig(treasury, 1000, 6000, 7500);
        _setUpSteveBasket();
        _setUpIndexBasket();
        _setUpRewards();
        _setUpLending();
    }

    function test_ClaimAndMintStEVE_ClaimsThenMintsWithoutAllowance() public {
        vm.warp(block.timestamp + 1 days);
        uint256 claimable = IEdenStEVEFacet(address(diamond)).claimableRewards(alice);
        assertEq(claimable, 100e18);
        assertEq(rewardToken.allowance(alice, address(diamond)), 0);

        vm.prank(alice);
        uint256 minted = IEdenBatchFacet(address(diamond)).claimAndMintStEVE(0, alice);

        assertEq(minted, 0.1e18);
        assertEq(stEveToken.balanceOf(alice), 1.1e18);
        assertEq(BatchConvenienceHarnessFacet(address(diamond)).getRewardReserve(), 0);
        assertEq(BatchConvenienceHarnessFacet(address(diamond)).getLastClaimedEpoch(alice), 1);
        assertEq(
            BatchConvenienceHarnessFacet(address(diamond)).getVaultBalance(0, address(rewardToken)),
            1100e18
        );
    }

    function test_ClaimAndMintStEVE_RevertsOnSlippageAndZeroClaimable() public {
        vm.prank(alice);
        vm.expectRevert(EdenBatchFacet.ZeroClaimableRewards.selector);
        IEdenBatchFacet(address(diamond)).claimAndMintStEVE(0, alice);

        vm.warp(block.timestamp + 1 days);
        uint256 reserveBefore = BatchConvenienceHarnessFacet(address(diamond)).getRewardReserve();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EdenBatchFacet.MintOutputTooLow.selector, 0.1e18, 0.2e18));
        IEdenBatchFacet(address(diamond)).claimAndMintStEVE(0.2e18, alice);

        assertEq(BatchConvenienceHarnessFacet(address(diamond)).getRewardReserve(), reserveBefore);
        assertEq(BatchConvenienceHarnessFacet(address(diamond)).getLastClaimedEpoch(alice), 0);
        assertEq(stEveToken.balanceOf(alice), 1e18);
    }

    function test_ExtendMany_ValidatesLengthsAndIsAtomic() public {
        (uint256 loanId0, uint256 loanId1) = _openTwoLoans();
        uint40 maturity0Before = BatchConvenienceHarnessFacet(address(diamond)).getLoan(loanId0).maturity;
        uint40 maturity1Before = BatchConvenienceHarnessFacet(address(diamond)).getLoan(loanId1).maturity;

        uint256[] memory loanIds = new uint256[](2);
        loanIds[0] = loanId0;
        loanIds[1] = loanId1;

        uint40[] memory badDurations = new uint40[](1);
        badDurations[0] = 1 days;

        vm.prank(alice);
        vm.expectRevert(INVALID_ARRAY_LENGTH_SELECTOR);
        IEdenBatchFacet(address(diamond)).extendMany(loanIds, badDurations);

        uint40[] memory durations = new uint40[](2);
        durations[0] = 1 days;
        durations[1] = 20 days;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(INVALID_DURATION_SELECTOR, uint256(20 days), 1 days, 10 days)
        );
        IEdenBatchFacet(address(diamond)).extendMany{ value: 0.22 ether }(loanIds, durations);

        assertEq(BatchConvenienceHarnessFacet(address(diamond)).getLoan(loanId0).maturity, maturity0Before);
        assertEq(BatchConvenienceHarnessFacet(address(diamond)).getLoan(loanId1).maturity, maturity1Before);
    }

    function test_ExtendMany_AggregatesFeesAndExtendsAllLoans() public {
        (uint256 loanId0, uint256 loanId1) = _openTwoLoans();
        uint40 maturity0Before = BatchConvenienceHarnessFacet(address(diamond)).getLoan(loanId0).maturity;
        uint40 maturity1Before = BatchConvenienceHarnessFacet(address(diamond)).getLoan(loanId1).maturity;

        uint256[] memory loanIds = new uint256[](2);
        loanIds[0] = loanId0;
        loanIds[1] = loanId1;
        uint40[] memory durations = new uint40[](2);
        durations[0] = 1 days;
        durations[1] = 1 days;

        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        IEdenBatchFacet(address(diamond)).extendMany{ value: 0.22 ether }(loanIds, durations);

        assertEq(treasury.balance - treasuryBefore, 0.22 ether);
        assertEq(
            BatchConvenienceHarnessFacet(address(diamond)).getLoan(loanId0).maturity,
            maturity0Before + 1 days
        );
        assertEq(
            BatchConvenienceHarnessFacet(address(diamond)).getLoan(loanId1).maturity,
            maturity1Before + 1 days
        );
    }

    function _setUpSteveBasket() internal {
        address[] memory assets = new address[](1);
        assets[0] = address(rewardToken);
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = 1000e18;
        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = 0;

        BatchConvenienceHarnessFacet(address(diamond))
            .setBasket(0, address(stEveToken), assets, bundleAmounts, mintFees, true);
        BatchConvenienceHarnessFacet(address(diamond)).mintReceiptUnits(0, alice, UNIT);
        BatchConvenienceHarnessFacet(address(diamond))
            .setVaultBalance(0, address(rewardToken), 1000e18);
    }

    function _setUpIndexBasket() internal {
        address[] memory assets = new address[](2);
        assets[0] = address(rewardToken);
        assets[1] = address(altToken);
        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 100e18;
        bundleAmounts[1] = 50e18;
        uint16[] memory mintFees = new uint16[](2);
        mintFees[0] = 0;
        mintFees[1] = 0;

        BatchConvenienceHarnessFacet(address(diamond))
            .setBasket(1, address(indexToken), assets, bundleAmounts, mintFees, false);
        BatchConvenienceHarnessFacet(address(diamond)).mintReceiptUnits(1, alice, 3 * UNIT);
        BatchConvenienceHarnessFacet(address(diamond))
            .setVaultBalance(1, address(rewardToken), 300e18);
        BatchConvenienceHarnessFacet(address(diamond)).setVaultBalance(1, address(altToken), 150e18);
    }

    function _setUpRewards() internal {
        BatchConvenienceHarnessFacet(address(diamond))
            .setRewardConfig(block.timestamp, 1 days, 183, 3, 100e18, 10);
        BatchConvenienceHarnessFacet(address(diamond)).setRewardReserve(100e18);
        rewardToken.mint(address(diamond), 1_000_000e18);
        altToken.mint(address(diamond), 1_000_000e18);
    }

    function _setUpLending() internal {
        vm.startPrank(owner);
        IEdenLendingFacet(address(diamond)).configureLending(1, 1 days, 10 days);

        uint256[] memory mins = new uint256[](2);
        mins[0] = UNIT;
        mins[1] = 2 * UNIT;
        uint256[] memory fees = new uint256[](2);
        fees[0] = 0.2 ether;
        fees[1] = 0.02 ether;
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(1, mins, fees);
        vm.stopPrank();

        rewardToken.mint(alice, 1_000_000e18);
        altToken.mint(alice, 1_000_000e18);
        vm.deal(alice, 10 ether);

        vm.prank(alice);
        indexToken.approve(address(diamond), type(uint256).max);
    }

    function _openTwoLoans() internal returns (uint256 loanId0, uint256 loanId1) {
        vm.prank(alice);
        loanId0 = IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 2 days);

        vm.prank(alice);
        loanId1 = IEdenLendingFacet(address(diamond)).borrow{ value: 0.02 ether }(1, 2 * UNIT, 2 days);
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](1);

        bytes4[] memory selectors = new bytes4[](19);
        selectors[0] = IEdenBatchFacet.multicall.selector;
        selectors[1] = IEdenBatchFacet.claimAndMintStEVE.selector;
        selectors[2] = IEdenBatchFacet.extendMany.selector;
        selectors[3] = IEdenStEVEFacet.onStEVETransfer.selector;
        selectors[4] = IEdenLendingFacet.borrow.selector;
        selectors[5] = IEdenLendingFacet.configureLending.selector;
        selectors[6] = IEdenLendingFacet.configureBorrowFeeTiers.selector;
        selectors[7] = IEdenStEVEFacet.claimableRewards.selector;
        selectors[8] = BatchConvenienceHarnessFacet.onBasketTokenTransfer.selector;
        selectors[9] = BatchConvenienceHarnessFacet.setCoreConfig.selector;
        selectors[10] = BatchConvenienceHarnessFacet.setBasket.selector;
        selectors[11] = BatchConvenienceHarnessFacet.setRewardConfig.selector;
        selectors[12] = BatchConvenienceHarnessFacet.setRewardReserve.selector;
        selectors[13] = BatchConvenienceHarnessFacet.mintReceiptUnits.selector;
        selectors[14] = BatchConvenienceHarnessFacet.setVaultBalance.selector;
        selectors[15] = BatchConvenienceHarnessFacet.getVaultBalance.selector;
        selectors[16] = BatchConvenienceHarnessFacet.getRewardReserve.selector;
        selectors[17] = BatchConvenienceHarnessFacet.getLastClaimedEpoch.selector;
        selectors[18] = BatchConvenienceHarnessFacet.getLoan.selector;

        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(batchFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
    }
}
