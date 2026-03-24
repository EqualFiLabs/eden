// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenStEVEFacet } from "src/facets/EdenStEVEFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibStEVEStorage } from "src/libraries/LibStEVEStorage.sol";
import { StEVEToken } from "src/tokens/StEVEToken.sol";

contract MockRewardToken is ERC20 {
    constructor() ERC20("EVE", "EVE") { }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

contract StEVEHarnessFacet is EdenStEVEFacet {
    function onBasketTokenTransfer(
        address,
        address,
        uint256
    ) external pure { }

    function setStEveBasket(
        address token,
        address rewardToken
    ) external {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        store.steveBasketId = 0;
        if (store.basketCount == 0) {
            store.basketCount = 1;
        }

        LibEdenStorage.Basket storage basket = store.baskets[0];
        delete basket.assets;
        basket.assets.push(rewardToken);
        basket.token = token;
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

    function mintStEve(
        address token,
        address to,
        uint256 amount
    ) external {
        StEVEToken(token).mintIndexUnits(to, amount);
    }

    function burnStEve(
        address token,
        address from,
        uint256 amount
    ) external {
        StEVEToken(token).burnIndexUnits(from, amount);
    }

    function moveToLocked(
        address user,
        uint256 amount
    ) external {
        _moveLiquidToLocked(user, amount);
    }

    function moveToLiquid(
        address user,
        uint256 amount
    ) external {
        _moveLockedToLiquid(user, amount);
    }

    function burnLocked(
        address user,
        uint256 amount
    ) external {
        _burnLocked(user, amount);
    }

    function getLiquidBalance(
        address user
    ) external view returns (uint256) {
        return LibStEVEStorage.layout().liquidBalances[user];
    }

    function getLockedBalance(
        address user
    ) external view returns (uint256) {
        return LibStEVEStorage.layout().lockedBalances[user];
    }

    function getEffectiveBalance(
        address user
    ) external view returns (uint256) {
        return LibStEVEStorage.effectiveBalance(user);
    }

    function getUserTwabAccount(
        address user
    )
        external
        view
        returns (uint256 cumulativeBalance, uint256 lastUpdateTimestamp, uint256 lastBalance)
    {
        LibStEVEStorage.TwabAccount storage account = LibStEVEStorage.layout().userTwabs[user];
        return (account.cumulativeBalance, account.lastUpdateTimestamp, account.lastBalance);
    }

    function getGlobalTwabAccount()
        external
        view
        returns (uint256 cumulativeBalance, uint256 lastUpdateTimestamp, uint256 lastBalance)
    {
        LibStEVEStorage.TwabAccount storage account = LibStEVEStorage.layout().globalTwab;
        return (account.cumulativeBalance, account.lastUpdateTimestamp, account.lastBalance);
    }

    function getUserCheckpointCount(
        address user
    ) external view returns (uint256) {
        return LibStEVEStorage.layout().userCheckpoints[user].length;
    }

    function getUserCheckpoint(
        address user,
        uint256 index
    ) external view returns (uint48 timestamp, uint208 cumulativeBalance) {
        LibStEVEStorage.Checkpoint storage checkpoint =
            LibStEVEStorage.layout().userCheckpoints[user][index];
        return (checkpoint.timestamp, checkpoint.cumulativeBalance);
    }

    function getGlobalCheckpointCount() external view returns (uint256) {
        return LibStEVEStorage.layout().globalCheckpoints.length;
    }

    function getGlobalCheckpoint(
        uint256 index
    ) external view returns (uint48 timestamp, uint208 cumulativeBalance) {
        LibStEVEStorage.Checkpoint storage checkpoint =
            LibStEVEStorage.layout().globalCheckpoints[index];
        return (checkpoint.timestamp, checkpoint.cumulativeBalance);
    }

    function getLastClaimedEpoch(
        address user
    ) external view returns (uint256) {
        return LibStEVEStorage.layout().lastClaimedEpoch[user];
    }

    function getUserRewardForEpoch(
        address user,
        uint256 epoch
    ) external view returns (uint256) {
        return _getUserRewardForEpoch(user, epoch);
    }
}

contract StEVEFacetTest is Test {
    uint256 internal constant DAY = 1 days;
    uint256 internal constant BASE_REWARD = 4_380_000e18;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    EdenDiamond internal diamond;
    StEVEHarnessFacet internal stEveFacet;
    StEVEToken internal token;
    MockRewardToken internal rewardToken;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        stEveFacet = new StEVEHarnessFacet();
        rewardToken = new MockRewardToken();
        token = new StEVEToken("stEVE", "stEVE", address(diamond));

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");

        StEVEHarnessFacet(address(diamond)).setStEveBasket(address(token), address(rewardToken));
        StEVEHarnessFacet(address(diamond))
            .setRewardConfig(block.timestamp, DAY, 183, 3, BASE_REWARD, 548);

        rewardToken.mint(owner, 50_000_000e18);
    }

    function test_TWABAccounting_TransferUpdatesLedgersAndCheckpoints() public {
        StEVEHarnessFacet(address(diamond)).mintStEve(address(token), alice, 100e18);
        vm.warp(block.timestamp + 10);

        vm.prank(alice);
        token.transfer(bob, 40e18);

        assertEq(StEVEHarnessFacet(address(diamond)).getLiquidBalance(alice), 60e18);
        assertEq(StEVEHarnessFacet(address(diamond)).getLiquidBalance(bob), 40e18);
        assertEq(StEVEHarnessFacet(address(diamond)).getEffectiveBalance(alice), 60e18);
        assertEq(StEVEHarnessFacet(address(diamond)).getEffectiveBalance(bob), 40e18);

        (uint256 aliceCumulative,, uint256 aliceLastBalance) =
            StEVEHarnessFacet(address(diamond)).getUserTwabAccount(alice);
        (uint256 bobCumulative,, uint256 bobLastBalance) =
            StEVEHarnessFacet(address(diamond)).getUserTwabAccount(bob);
        (uint256 globalCumulative,, uint256 globalLastBalance) =
            StEVEHarnessFacet(address(diamond)).getGlobalTwabAccount();

        assertEq(aliceCumulative, 100e18 * 10);
        assertEq(bobCumulative, 0);
        assertEq(globalCumulative, 100e18 * 10);
        assertEq(aliceLastBalance, 60e18);
        assertEq(bobLastBalance, 40e18);
        assertEq(globalLastBalance, 100e18);

        assertEq(StEVEHarnessFacet(address(diamond)).getUserCheckpointCount(alice), 2);
        assertEq(StEVEHarnessFacet(address(diamond)).getUserCheckpointCount(bob), 1);
        assertEq(StEVEHarnessFacet(address(diamond)).getGlobalCheckpointCount(), 2);
    }

    function test_TWABAccounting_LockUnlockPreservesEffectiveBalanceAndMonotonicity() public {
        StEVEHarnessFacet(address(diamond)).mintStEve(address(token), alice, 100e18);
        vm.warp(block.timestamp + 20);

        StEVEHarnessFacet(address(diamond)).moveToLocked(alice, 30e18);
        (uint256 cumulativeAfterLock,, uint256 lastBalanceAfterLock) =
            StEVEHarnessFacet(address(diamond)).getUserTwabAccount(alice);

        assertEq(StEVEHarnessFacet(address(diamond)).getLiquidBalance(alice), 70e18);
        assertEq(StEVEHarnessFacet(address(diamond)).getLockedBalance(alice), 30e18);
        assertEq(StEVEHarnessFacet(address(diamond)).getEffectiveBalance(alice), 100e18);
        assertEq(cumulativeAfterLock, 100e18 * 20);
        assertEq(lastBalanceAfterLock, 100e18);

        vm.warp(block.timestamp + 10);
        StEVEHarnessFacet(address(diamond)).moveToLiquid(alice, 10e18);

        (uint256 cumulativeAfterUnlock,, uint256 lastBalanceAfterUnlock) =
            StEVEHarnessFacet(address(diamond)).getUserTwabAccount(alice);
        assertGe(cumulativeAfterUnlock, cumulativeAfterLock);
        assertEq(cumulativeAfterUnlock, 100e18 * 30);
        assertEq(lastBalanceAfterUnlock, 100e18);
        assertEq(StEVEHarnessFacet(address(diamond)).getLiquidBalance(alice), 80e18);
        assertEq(StEVEHarnessFacet(address(diamond)).getLockedBalance(alice), 20e18);

        (uint48 checkpoint0Time, uint208 checkpoint0Cumulative) =
            StEVEHarnessFacet(address(diamond)).getUserCheckpoint(alice, 0);
        (uint48 checkpoint1Time, uint208 checkpoint1Cumulative) =
            StEVEHarnessFacet(address(diamond)).getUserCheckpoint(alice, 1);
        (uint48 checkpoint2Time, uint208 checkpoint2Cumulative) =
            StEVEHarnessFacet(address(diamond)).getUserCheckpoint(alice, 2);

        assertLe(checkpoint0Time, checkpoint1Time);
        assertLe(checkpoint1Time, checkpoint2Time);
        assertLe(checkpoint0Cumulative, checkpoint1Cumulative);
        assertLe(checkpoint1Cumulative, checkpoint2Cumulative);
    }

    function test_TWABAccounting_FlashMintResistance() public {
        uint256 start = block.timestamp;

        StEVEHarnessFacet(address(diamond)).mintStEve(address(token), alice, 50e18);
        StEVEHarnessFacet(address(diamond)).burnStEve(address(token), alice, 50e18);

        vm.warp(start + DAY);
        uint256 twab = IEdenStEVEFacet(address(diamond)).getUserTwab(alice, start, start + DAY);
        assertEq(twab, 0);
    }

    function test_EpochRewards_CurrentEpochAndDecayCurve() public {
        assertEq(IEdenStEVEFacet(address(diamond)).currentEpoch(), 0);

        vm.warp(block.timestamp + (2 * DAY) + 1);
        assertEq(IEdenStEVEFacet(address(diamond)).currentEpoch(), 2);

        assertEq(IEdenStEVEFacet(address(diamond)).rewardForEpoch(182), BASE_REWARD);
        assertEq(IEdenStEVEFacet(address(diamond)).rewardForEpoch(183), BASE_REWARD / 2);
        assertEq(IEdenStEVEFacet(address(diamond)).rewardForEpoch(366), BASE_REWARD / 4);
        assertGt(IEdenStEVEFacet(address(diamond)).rewardForEpoch(547), 0);
        assertEq(IEdenStEVEFacet(address(diamond)).rewardForEpoch(548), 0);
    }

    function test_EpochRewards_UserRewardProportionalityAndZeroTwab() public {
        StEVEHarnessFacet(address(diamond)).mintStEve(address(token), alice, 100e18);
        StEVEHarnessFacet(address(diamond)).mintStEve(address(token), bob, 100e18);

        vm.warp(block.timestamp + DAY + 1);

        uint256 aliceReward = StEVEHarnessFacet(address(diamond)).getUserRewardForEpoch(alice, 0);
        uint256 bobReward = StEVEHarnessFacet(address(diamond)).getUserRewardForEpoch(bob, 0);

        assertEq(aliceReward, BASE_REWARD / 2);
        assertEq(bobReward, BASE_REWARD / 2);
        assertEq(aliceReward + bobReward, BASE_REWARD);

        vm.warp(block.timestamp + DAY);
        address carol = makeAddr("carol");
        assertEq(StEVEHarnessFacet(address(diamond)).getUserRewardForEpoch(carol, 1), 0);
    }

    function test_ClaimRewards_MultiEpochNoDoubleClaimAndNoExpiry() public {
        StEVEHarnessFacet(address(diamond)).mintStEve(address(token), alice, 100e18);
        uint256 initialFunding = BASE_REWARD * 4;
        _fundRewards(initialFunding);

        vm.warp(block.timestamp + (3 * DAY) + 1);
        uint256 balanceBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        uint256 claimed = IEdenStEVEFacet(address(diamond)).claimRewards();

        assertEq(claimed, BASE_REWARD * 3);
        assertEq(rewardToken.balanceOf(alice) - balanceBefore, claimed);
        assertEq(StEVEHarnessFacet(address(diamond)).getLastClaimedEpoch(alice), 3);
        assertEq(IEdenStEVEFacet(address(diamond)).rewardReserveBalance(), initialFunding - claimed);

        vm.prank(alice);
        assertEq(IEdenStEVEFacet(address(diamond)).claimRewards(), 0);

        vm.warp(block.timestamp + (5 * DAY));
        _fundRewards(BASE_REWARD * 5);

        vm.prank(alice);
        uint256 laterClaim = IEdenStEVEFacet(address(diamond)).claimRewards();
        assertGt(laterClaim, 0);
        assertEq(StEVEHarnessFacet(address(diamond)).getLastClaimedEpoch(alice), 8);
    }

    function test_ClaimRewards_PartialReserveAndHardCap() public {
        uint256 epochReward = 100e18;
        StEVEHarnessFacet(address(diamond))
            .setRewardConfig(block.timestamp, DAY, 183, 3, epochReward, 548);
        StEVEHarnessFacet(address(diamond)).mintStEve(address(token), alice, 100e18);
        _fundRewards(150e18);

        vm.warp(block.timestamp + (2 * DAY) + 1);

        vm.prank(alice);
        uint256 claimed = IEdenStEVEFacet(address(diamond)).claimRewards();

        assertEq(claimed, epochReward);
        assertEq(rewardToken.balanceOf(alice), epochReward);
        assertEq(IEdenStEVEFacet(address(diamond)).rewardReserveBalance(), 50e18);
        assertEq(StEVEHarnessFacet(address(diamond)).getLastClaimedEpoch(alice), 1);
        assertEq(IEdenStEVEFacet(address(diamond)).claimableRewards(alice), 0);

        _fundRewards(100e18);

        vm.prank(alice);
        uint256 secondClaim = IEdenStEVEFacet(address(diamond)).claimRewards();

        assertEq(secondClaim, epochReward);
        assertEq(rewardToken.balanceOf(alice), 2 * epochReward);
        assertEq(StEVEHarnessFacet(address(diamond)).getLastClaimedEpoch(alice), 2);
    }

    function test_RewardViews_ConfigPreviewAndBreakdown() public {
        StEVEHarnessFacet(address(diamond)).mintStEve(address(token), alice, 100e18);
        _fundRewards(BASE_REWARD * 3);

        vm.warp(block.timestamp + (2 * DAY) + 1);

        IEdenStEVEFacet.RewardConfig memory config =
            IEdenStEVEFacet(address(diamond)).getRewardConfig();
        assertEq(config.genesisTimestamp, block.timestamp - ((2 * DAY) + 1));
        assertEq(config.epochDuration, DAY);
        assertEq(config.baseRewardPerEpoch, BASE_REWARD);
        assertEq(config.totalEpochs, 548);
        assertEq(config.rewardReserve, BASE_REWARD * 3);

        assertEq(IEdenStEVEFacet(address(diamond)).claimableRewards(alice), BASE_REWARD * 2);
        assertEq(
            IEdenStEVEFacet(address(diamond)).claimableRewardsThroughEpoch(alice, 0), BASE_REWARD
        );

        IEdenStEVEFacet.RewardPreview memory preview =
            IEdenStEVEFacet(address(diamond)).previewClaimRewards(alice);
        assertEq(preview.user, alice);
        assertEq(preview.fromEpoch, 0);
        assertEq(preview.toEpoch, 1);
        assertEq(preview.totalClaimable, BASE_REWARD * 2);

        IEdenStEVEFacet.RewardEpochBreakdown[] memory breakdown =
            IEdenStEVEFacet(address(diamond)).getRewardEpochBreakdown(alice, 0, 1);
        assertEq(breakdown.length, 2);
        assertEq(breakdown[0].epoch, 0);
        assertEq(breakdown[0].reward, BASE_REWARD);
        assertEq(breakdown[0].userTwab, 100e18);
        assertEq(breakdown[0].totalTwab, 100e18);
        assertEq(breakdown[1].epoch, 1);
        assertEq(breakdown[1].reward, BASE_REWARD);
    }

    function test_RewardViews_MonotonicBreakdownAndClaimConsistency() public {
        StEVEHarnessFacet(address(diamond)).mintStEve(address(token), alice, 100e18);
        StEVEHarnessFacet(address(diamond)).mintStEve(address(token), bob, 300e18);
        _fundRewards(BASE_REWARD * 3);

        vm.warp(block.timestamp + (2 * DAY) + 1);

        uint256 throughEpoch0 =
            IEdenStEVEFacet(address(diamond)).claimableRewardsThroughEpoch(alice, 0);
        uint256 throughEpoch1 =
            IEdenStEVEFacet(address(diamond)).claimableRewardsThroughEpoch(alice, 1);
        uint256 totalClaimable = IEdenStEVEFacet(address(diamond)).claimableRewards(alice);

        assertEq(throughEpoch0, BASE_REWARD / 4);
        assertEq(throughEpoch1, BASE_REWARD / 2);
        assertEq(totalClaimable, throughEpoch1);
        assertLe(throughEpoch0, throughEpoch1);

        IEdenStEVEFacet.RewardPreview memory preview =
            IEdenStEVEFacet(address(diamond)).previewClaimRewards(alice);
        assertEq(preview.fromEpoch, 0);
        assertEq(preview.toEpoch, 1);
        assertEq(preview.totalClaimable, totalClaimable);

        IEdenStEVEFacet.RewardEpochBreakdown[] memory breakdown =
            IEdenStEVEFacet(address(diamond)).getRewardEpochBreakdown(alice, 0, 1);
        uint256 summedRewards;
        for (uint256 i = 0; i < breakdown.length; i++) {
            summedRewards += breakdown[i].reward;
            assertEq(breakdown[i].reward, BASE_REWARD / 4);
            assertEq(breakdown[i].userTwab, 100e18);
            assertEq(breakdown[i].totalTwab, 400e18);
        }
        assertEq(summedRewards, totalClaimable);

        vm.prank(alice);
        uint256 claimed = IEdenStEVEFacet(address(diamond)).claimRewards();
        assertEq(claimed, totalClaimable);
        assertEq(StEVEHarnessFacet(address(diamond)).getLastClaimedEpoch(alice), 2);
    }

    function test_ReserveManagement_FundAndOverrideViews() public {
        _fundRewards(500e18);
        assertEq(IEdenStEVEFacet(address(diamond)).rewardReserveBalance(), 500e18);
        assertEq(IEdenStEVEFacet(address(diamond)).currentEmissionRate(), BASE_REWARD);

        vm.prank(owner);
        IEdenStEVEFacet(address(diamond)).setRewardPerEpoch(100e18);
        assertEq(IEdenStEVEFacet(address(diamond)).currentEmissionRate(), 100e18);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                EdenStEVEFacet.InvalidRewardRate.selector, BASE_REWARD + 1, BASE_REWARD
            )
        );
        IEdenStEVEFacet(address(diamond)).setRewardPerEpoch(BASE_REWARD + 1);

        vm.prank(owner);
        IEdenStEVEFacet(address(diamond)).setRewardPerEpoch(0);
        assertEq(IEdenStEVEFacet(address(diamond)).currentEmissionRate(), BASE_REWARD);
    }

    function _fundRewards(
        uint256 amount
    ) internal {
        vm.startPrank(owner);
        rewardToken.approve(address(diamond), amount);
        IEdenStEVEFacet(address(diamond)).fundRewards(amount);
        vm.stopPrank();
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        bytes4[] memory selectors = new bytes4[](27);
        selectors[0] = IEdenStEVEFacet.claimRewards.selector;
        selectors[1] = IEdenStEVEFacet.fundRewards.selector;
        selectors[2] = IEdenStEVEFacet.setRewardPerEpoch.selector;
        selectors[3] = IEdenStEVEFacet.rewardForEpoch.selector;
        selectors[4] = IEdenStEVEFacet.currentEpoch.selector;
        selectors[5] = IEdenStEVEFacet.rewardReserveBalance.selector;
        selectors[6] = IEdenStEVEFacet.currentEmissionRate.selector;
        selectors[7] = IEdenStEVEFacet.getUserTwab.selector;
        selectors[8] = IEdenStEVEFacet.getRewardConfig.selector;
        selectors[9] = IEdenStEVEFacet.claimableRewards.selector;
        selectors[10] = IEdenStEVEFacet.previewClaimRewards.selector;
        selectors[11] = IEdenStEVEFacet.claimableRewardsThroughEpoch.selector;
        selectors[12] = IEdenStEVEFacet.getRewardEpochBreakdown.selector;
        selectors[13] = IEdenStEVEFacet.onStEVETransfer.selector;
        selectors[14] = StEVEHarnessFacet.onBasketTokenTransfer.selector;
        selectors[15] = StEVEHarnessFacet.setStEveBasket.selector;
        selectors[16] = StEVEHarnessFacet.setRewardConfig.selector;
        selectors[17] = StEVEHarnessFacet.mintStEve.selector;
        selectors[18] = StEVEHarnessFacet.burnStEve.selector;
        selectors[19] = StEVEHarnessFacet.moveToLocked.selector;
        selectors[20] = StEVEHarnessFacet.moveToLiquid.selector;
        selectors[21] = StEVEHarnessFacet.burnLocked.selector;
        selectors[22] = StEVEHarnessFacet.getLiquidBalance.selector;
        selectors[23] = StEVEHarnessFacet.getLockedBalance.selector;
        selectors[24] = StEVEHarnessFacet.getEffectiveBalance.selector;
        selectors[25] = StEVEHarnessFacet.getUserTwabAccount.selector;
        selectors[26] = StEVEHarnessFacet.getGlobalTwabAccount.selector;

        bytes4[] memory extras = new bytes4[](5);
        extras[0] = StEVEHarnessFacet.getUserCheckpointCount.selector;
        extras[1] = StEVEHarnessFacet.getUserCheckpoint.selector;
        extras[2] = StEVEHarnessFacet.getGlobalCheckpointCount.selector;
        extras[3] = StEVEHarnessFacet.getGlobalCheckpoint.selector;
        extras[4] = StEVEHarnessFacet.getLastClaimedEpoch.selector;

        bytes4[] memory more = new bytes4[](1);
        more[0] = StEVEHarnessFacet.getUserRewardForEpoch.selector;

        bytes4[] memory allSelectors = new bytes4[](selectors.length + extras.length + more.length);
        for (uint256 i = 0; i < selectors.length; i++) {
            allSelectors[i] = selectors[i];
        }
        for (uint256 i = 0; i < extras.length; i++) {
            allSelectors[selectors.length + i] = extras[i];
        }
        allSelectors[selectors.length + extras.length] = more[0];

        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(stEveFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: allSelectors
        });
    }
}
