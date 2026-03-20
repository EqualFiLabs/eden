// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IEdenEvents } from "./IEdenEvents.sol";

interface IEdenStEVEFacet is IEdenEvents {
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
    function onStEVETransfer(
        address from,
        address to,
        uint256 value
    ) external;
}
