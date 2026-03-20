// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibStEVEStorage } from "src/libraries/LibStEVEStorage.sol";

contract EdenStEVEFacet is IEdenStEVEFacet {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error InvalidRewardConfig();
    error InvalidRewardRate(uint256 requested, uint256 maxAllowed);
    error InvalidTimeRange(uint256 start, uint256 end);
    error InvalidHookCaller(address caller);
    error InvalidBasketConfiguration();
    error NativeRewardTokenUnsupported();
    error CheckpointOverflow();

    modifier onlyOwnerOrTimelock() {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        if (msg.sender != store.owner && msg.sender != store.timelock) revert Unauthorized();
        _;
    }

    modifier onlyStEVEToken() {
        address token = _stEveToken();
        if (msg.sender != token) revert InvalidHookCaller(msg.sender);
        _;
    }

    function claimRewards() external returns (uint256 totalClaimed) {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        uint256 current = currentEpoch();
        if (current == 0 || st.totalEpochs == 0) return 0;

        uint256 startEpoch = st.lastClaimedEpoch[msg.sender];
        uint256 latestCompleted = current - 1;
        if (startEpoch >= st.totalEpochs || startEpoch > latestCompleted) return 0;

        uint256 endEpoch = latestCompleted;
        if (endEpoch >= st.totalEpochs) {
            endEpoch = st.totalEpochs - 1;
        }

        for (uint256 epoch = startEpoch; epoch <= endEpoch; epoch++) {
            totalClaimed += _getUserRewardForEpoch(msg.sender, epoch);
        }

        uint256 reserve = st.rewardReserve;
        if (totalClaimed > reserve) {
            totalClaimed = reserve;
        }

        st.rewardReserve = reserve - totalClaimed;
        st.lastClaimedEpoch[msg.sender] = endEpoch + 1;

        if (totalClaimed > 0) {
            IERC20(_rewardToken()).safeTransfer(msg.sender, totalClaimed);
        }

        emit RewardsClaimed(msg.sender, startEpoch, endEpoch, totalClaimed);
    }

    function fundRewards(
        uint256 amount
    ) external onlyOwnerOrTimelock {
        IERC20(_rewardToken()).safeTransferFrom(msg.sender, address(this), amount);

        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        st.rewardReserve += amount;
        emit RewardsFunded(amount, st.rewardReserve);
    }

    function setRewardPerEpoch(
        uint256 newRate
    ) external onlyOwnerOrTimelock {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        uint256 maxAllowed = st.maxRewardPerEpochOverride;
        if (maxAllowed == 0) {
            maxAllowed = st.baseRewardPerEpoch;
        }

        if (newRate != 0 && newRate > maxAllowed) {
            revert InvalidRewardRate(newRate, maxAllowed);
        }

        uint256 oldRate = st.rewardPerEpochOverride;
        st.rewardPerEpochOverride = newRate;
        emit RewardRateUpdated(oldRate, newRate);
    }

    function rewardForEpoch(
        uint256 epoch
    ) public view returns (uint256) {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        if (epoch >= st.totalEpochs) return 0;

        uint256 period = epoch / st.halvingInterval;
        if (period >= st.maxPeriods) return 0;

        if (st.rewardPerEpochOverride > 0) {
            return st.rewardPerEpochOverride;
        }

        return st.baseRewardPerEpoch >> period;
    }

    function currentEpoch() public view returns (uint256) {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        if (st.epochDuration == 0 || block.timestamp <= st.genesisTimestamp) return 0;
        return (block.timestamp - st.genesisTimestamp) / st.epochDuration;
    }

    function rewardReserveBalance() external view returns (uint256) {
        return LibStEVEStorage.layout().rewardReserve;
    }

    function currentEmissionRate() external view returns (uint256) {
        return rewardForEpoch(currentEpoch());
    }

    function getUserTwab(
        address user,
        uint256 startTime,
        uint256 endTime
    ) external view returns (uint256) {
        if (endTime <= startTime) revert InvalidTimeRange(startTime, endTime);
        return _averageBalanceOverInterval(user, startTime, endTime);
    }

    function onStEVETransfer(
        address from,
        address to,
        uint256 value
    ) external onlyStEVEToken {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        uint256 oldTotal = st.globalTwab.lastBalance;
        uint256 newTotal = oldTotal;

        if (from == address(0)) {
            newTotal += value;
        } else {
            st.liquidBalances[from] -= value;
        }

        if (to == address(0)) {
            newTotal -= value;
        } else {
            st.liquidBalances[to] += value;
        }

        if (from != address(0)) {
            _syncAccountTwab(from);
        }

        if (to != address(0) && to != from) {
            _syncAccountTwab(to);
        }

        _syncGlobalTwab(newTotal);
    }

    function _moveLiquidToLocked(
        address user,
        uint256 amount
    ) internal {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        st.liquidBalances[user] -= amount;
        st.lockedBalances[user] += amount;
        _syncAccountTwab(user);
        _syncGlobalTwab(st.globalTwab.lastBalance);
    }

    function _moveLockedToLiquid(
        address user,
        uint256 amount
    ) internal {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        st.lockedBalances[user] -= amount;
        st.liquidBalances[user] += amount;
        _syncAccountTwab(user);
        _syncGlobalTwab(st.globalTwab.lastBalance);
    }

    function _burnLocked(
        address user,
        uint256 amount
    ) internal {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        st.lockedBalances[user] -= amount;
        _syncAccountTwab(user);
        _syncGlobalTwab(st.globalTwab.lastBalance - amount);
    }

    function _syncAccountTwab(
        address user
    ) internal {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        uint256 effectiveBalance = st.liquidBalances[user] + st.lockedBalances[user];
        _updateTwabAccount(st.userTwabs[user], st.userCheckpoints[user], effectiveBalance);
    }

    function _syncGlobalTwab(
        uint256 newTotalEffectiveSupply
    ) internal {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        _updateTwabAccount(st.globalTwab, st.globalCheckpoints, newTotalEffectiveSupply);
    }

    function _updateTwabAccount(
        LibStEVEStorage.TwabAccount storage account,
        LibStEVEStorage.Checkpoint[] storage checkpoints,
        uint256 newBalance
    ) internal {
        uint256 lastTimestamp = account.lastUpdateTimestamp;
        if (lastTimestamp == 0) {
            account.lastUpdateTimestamp = block.timestamp;
            account.lastBalance = newBalance;
        } else {
            uint256 elapsed = block.timestamp - lastTimestamp;
            account.cumulativeBalance += account.lastBalance * elapsed;
            account.lastUpdateTimestamp = block.timestamp;
            account.lastBalance = newBalance;
        }

        if (account.cumulativeBalance > type(uint208).max) revert CheckpointOverflow();

        checkpoints.push(
            LibStEVEStorage.Checkpoint({
                timestamp: SafeCast.toUint48(block.timestamp),
                cumulativeBalance: SafeCast.toUint208(account.cumulativeBalance)
            })
        );
    }

    function _getUserRewardForEpoch(
        address user,
        uint256 epoch
    ) internal view returns (uint256 reward) {
        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        if (st.epochDuration == 0) return 0;

        uint256 epochStart = st.genesisTimestamp + (epoch * st.epochDuration);
        uint256 epochEnd = epochStart + st.epochDuration;

        uint256 userTwab = _averageBalanceOverInterval(user, epochStart, epochEnd);
        uint256 totalTwab = _averageGlobalBalanceOverInterval(epochStart, epochEnd);
        if (totalTwab == 0) return 0;

        return Math.mulDiv(rewardForEpoch(epoch), userTwab, totalTwab);
    }

    function _averageBalanceOverInterval(
        address user,
        uint256 startTime,
        uint256 endTime
    ) internal view returns (uint256) {
        if (endTime <= startTime) return 0;

        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        uint256 startCumulative =
            _cumulativeAt(st.userCheckpoints[user], st.userTwabs[user], startTime);
        uint256 endCumulative = _cumulativeAt(st.userCheckpoints[user], st.userTwabs[user], endTime);
        return (endCumulative - startCumulative) / (endTime - startTime);
    }

    function _averageGlobalBalanceOverInterval(
        uint256 startTime,
        uint256 endTime
    ) internal view returns (uint256) {
        if (endTime <= startTime) return 0;

        LibStEVEStorage.StEVEStorage storage st = LibStEVEStorage.layout();
        uint256 startCumulative = _cumulativeAt(st.globalCheckpoints, st.globalTwab, startTime);
        uint256 endCumulative = _cumulativeAt(st.globalCheckpoints, st.globalTwab, endTime);
        return (endCumulative - startCumulative) / (endTime - startTime);
    }

    function _cumulativeAt(
        LibStEVEStorage.Checkpoint[] storage checkpoints,
        LibStEVEStorage.TwabAccount storage account,
        uint256 targetTime
    ) internal view returns (uint256) {
        uint256 len = checkpoints.length;
        if (len == 0) return 0;

        uint256 upper = _upperBound(checkpoints, targetTime);
        if (upper == 0) return 0;

        uint256 lower = upper - 1;
        LibStEVEStorage.Checkpoint storage lowerCheckpoint = checkpoints[lower];
        if (lowerCheckpoint.timestamp == targetTime) {
            return lowerCheckpoint.cumulativeBalance;
        }

        if (upper == len) {
            if (targetTime <= account.lastUpdateTimestamp) {
                return lowerCheckpoint.cumulativeBalance;
            }
            return account.cumulativeBalance
                + (account.lastBalance * (targetTime - account.lastUpdateTimestamp));
        }

        LibStEVEStorage.Checkpoint storage upperCheckpoint = checkpoints[upper];
        uint256 deltaTime = uint256(upperCheckpoint.timestamp) - uint256(lowerCheckpoint.timestamp);
        if (deltaTime == 0) {
            return upperCheckpoint.cumulativeBalance;
        }

        uint256 balance =
            (uint256(upperCheckpoint.cumulativeBalance)
                    - uint256(lowerCheckpoint.cumulativeBalance)) / deltaTime;
        return uint256(lowerCheckpoint.cumulativeBalance)
            + (balance * (targetTime - uint256(lowerCheckpoint.timestamp)));
    }

    function _upperBound(
        LibStEVEStorage.Checkpoint[] storage checkpoints,
        uint256 targetTime
    ) internal view returns (uint256 index) {
        uint256 low = 0;
        uint256 high = checkpoints.length;

        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (uint256(checkpoints[mid].timestamp) <= targetTime) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        return low;
    }

    function _rewardToken() internal view returns (address) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        LibEdenStorage.Basket storage basket = store.baskets[store.steveBasketId];
        if (basket.assets.length == 0) revert InvalidBasketConfiguration();

        address token = basket.assets[0];
        if (token == address(0)) revert NativeRewardTokenUnsupported();
        return token;
    }

    function _stEveToken() internal view returns (address) {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        address token = store.baskets[store.steveBasketId].token;
        if (token == address(0)) revert InvalidBasketConfiguration();
        return token;
    }
}
