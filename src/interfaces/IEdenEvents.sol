// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEdenEvents {
    event BasketCreated(
        uint256 indexed basketId,
        address indexed creator,
        address token,
        address[] assets,
        uint256[] bundleAmounts
    );

    event Minted(
        uint256 indexed basketId,
        address indexed user,
        uint256 units,
        uint256[] deposited,
        uint256[] fees
    );

    event Burned(
        uint256 indexed basketId,
        address indexed user,
        uint256 units,
        uint256[] returned,
        uint256[] fees
    );

    event FeePotAccrued(
        uint256 indexed basketId, address indexed asset, uint256 amount, bytes32 source
    );
    event ProtocolFeeRouted(
        uint256 indexed fromBasketId,
        address indexed asset,
        uint256 protocolShare,
        uint256 basketShare
    );

    event RewardsClaimed(address indexed user, uint256 fromEpoch, uint256 toEpoch, uint256 amount);
    event RewardsFunded(uint256 amount, uint256 newReserve);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);

    event LoanCreated(
        uint256 indexed loanId,
        uint256 indexed basketId,
        address indexed borrower,
        uint256 collateral,
        address[] assets,
        uint256[] principals,
        uint16 ltvBps,
        uint40 maturity
    );

    event LoanRepaid(uint256 indexed loanId);
    event LoanExtended(uint256 indexed loanId, uint40 newMaturity, uint256 fee);
    event LoanRecovered(
        uint256 indexed loanId,
        uint256 collateralBurned,
        address[] assets,
        uint256[] principalWrittenOff
    );

    event FlashLoaned(
        uint256 indexed basketId,
        address indexed receiver,
        uint256 units,
        uint256[] amounts,
        uint256[] fees
    );

    event ProtocolFeeSplitUpdated(uint16 oldBps, uint16 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event TimelockUpdated(address indexed oldTimelock, address indexed newTimelock);
    event BasketPausedUpdated(uint256 indexed basketId, bool paused);
    event BasketFeeConfigUpdated(
        uint256 indexed basketId, uint16[] mintFeeBps, uint16[] burnFeeBps, uint16 flashFeeBps
    );
    event BasketCreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event LendingConfigUpdated(
        uint256 indexed basketId, uint40 minDuration, uint40 maxDuration, uint16 ltvBps
    );
    event BorrowFeeTiersUpdated(
        uint256 indexed basketId, uint256[] minCollateralUnits, uint256[] flatFeeNative
    );
    event RewardConfigUpdated(
        uint256 genesisTimestamp,
        uint256 epochDuration,
        uint256 halvingInterval,
        uint256 maxPeriods,
        uint256 baseRewardPerEpoch,
        uint256 totalEpochs,
        uint256 maxRewardOverride
    );
    event RewardOverrideUpdated(uint256 oldRate, uint256 newRate);
    event BasketMetadataUpdated(uint256 indexed basketId, string uri, uint8 basketType);
    event ProtocolURIUpdated(string oldURI, string newURI);
    event ContractVersionUpdated(string oldVersion, string newVersion);
    event FacetVersionUpdated(address indexed facet, string oldVersion, string newVersion);
    event FacetFrozen(address indexed facet);
}
