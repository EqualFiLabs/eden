// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IEdenEvents } from "./IEdenEvents.sol";

interface IEdenStEVEFacet is IEdenEvents {
    struct RewardConfig {
        uint256 genesisTimestamp;
        uint256 epochDuration;
        uint256 halvingInterval;
        uint256 maxPeriods;
        uint256 baseRewardPerEpoch;
        uint256 totalEpochs;
        uint256 rewardReserve;
        uint256 rewardPerEpochOverride;
        uint256 maxRewardPerEpochOverride;
    }

    struct RewardPreview {
        address user;
        uint256 fromEpoch;
        uint256 toEpoch;
        uint256 totalClaimable;
    }

    struct RewardEpochBreakdown {
        uint256 epoch;
        uint256 reward;
        uint256 userTwab;
        uint256 totalTwab;
    }

    function claimRewards() external returns (uint256 totalClaimed);
    function configureRewards(
        uint256 genesisTimestamp,
        uint256 epochDuration,
        uint256 halvingInterval,
        uint256 maxPeriods,
        uint256 baseRewardPerEpoch,
        uint256 totalEpochs,
        uint256 maxRewardPerEpochOverride
    ) external;
    function fundRewards(
        uint256 amount
    ) external;
    function setRewardPerEpoch(
        uint256 newRate
    ) external;
    function rewardForEpoch(
        uint256 epoch
    ) external view returns (uint256);
    function currentEpoch() external view returns (uint256);
    function rewardReserveBalance() external view returns (uint256);
    function currentEmissionRate() external view returns (uint256);
    function getUserTwab(
        address user,
        uint256 startTime,
        uint256 endTime
    ) external view returns (uint256);
    function getRewardConfig() external view returns (RewardConfig memory);
    function claimableRewards(
        address user
    ) external view returns (uint256);
    function previewClaimRewards(
        address user
    ) external view returns (RewardPreview memory);
    function claimableRewardsThroughEpoch(
        address user,
        uint256 epoch
    ) external view returns (uint256);
    function getRewardEpochBreakdown(
        address user,
        uint256 startEpoch,
        uint256 endEpoch
    ) external view returns (RewardEpochBreakdown[] memory);
    function onStEVETransfer(
        address from,
        address to,
        uint256 value
    ) external;
}
