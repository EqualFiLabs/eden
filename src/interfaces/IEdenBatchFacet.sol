// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEdenBatchFacet {
    struct PermitData {
        address token;
        address owner;
        address spender;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function multicall(
        bytes[] calldata calls
    ) external payable returns (bytes[] memory results);
    function claimAndMintStEVE(
        uint256 minUnitsOut,
        address to
    ) external returns (uint256 unitsMinted);
    function repayAndUnlock(
        uint256 loanId
    ) external;
    function extendMany(
        uint256[] calldata loanIds,
        uint40[] calldata addedDurations
    ) external payable;
    function mintWithPermit(
        uint256 basketId,
        uint256 units,
        address to,
        PermitData[] calldata permits
    ) external returns (uint256 minted);
    function repayWithPermit(
        uint256 loanId,
        PermitData[] calldata permits
    ) external;
    function fundRewardsWithPermit(
        uint256 amount,
        PermitData calldata permit
    ) external;
}
