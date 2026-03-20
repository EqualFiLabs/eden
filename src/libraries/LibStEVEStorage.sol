// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library LibStEVEStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("eden.steve.storage");

    struct TwabAccount {
        uint256 cumulativeBalance;
        uint256 lastUpdateTimestamp;
        uint256 lastBalance;
    }

    struct Checkpoint {
        uint48 timestamp;
        uint208 cumulativeBalance;
    }

    struct StEVEStorage {
        uint256 genesisTimestamp;
        uint256 epochDuration;
        uint256 halvingInterval;
        uint256 maxPeriods;
        uint256 baseRewardPerEpoch;
        uint256 totalEpochs;
        uint256 rewardReserve;
        uint256 rewardPerEpochOverride;
        uint256 maxRewardPerEpochOverride;
        mapping(address => uint256) liquidBalances;
        mapping(address => uint256) lockedBalances;
        mapping(address => TwabAccount) userTwabs;
        TwabAccount globalTwab;
        mapping(address => Checkpoint[]) userCheckpoints;
        Checkpoint[] globalCheckpoints;
        mapping(address => uint256) lastClaimedEpoch;
    }

    function layout() internal pure returns (StEVEStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function storagePosition() internal pure returns (bytes32 position) {
        return STORAGE_POSITION;
    }

    function effectiveBalance(
        address account
    ) internal view returns (uint256) {
        StEVEStorage storage store = layout();
        return store.liquidBalances[account] + store.lockedBalances[account];
    }
}
