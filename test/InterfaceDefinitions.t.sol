// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IEdenAdminFacet } from "src/interfaces/IEdenAdminFacet.sol";
import { IEdenAgentFacet } from "src/interfaces/IEdenAgentFacet.sol";
import { IEdenBatchFacet } from "src/interfaces/IEdenBatchFacet.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { IEdenMetadataFacet } from "src/interfaces/IEdenMetadataFacet.sol";
import { IEdenPortfolioFacet } from "src/interfaces/IEdenPortfolioFacet.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";

contract InterfaceDefinitionsTest is Test {
    function test_NewFacetInterfaces_ExposeExpectedSelectors() public pure {
        assertEq(
            IEdenAdminFacet.completeBootstrap.selector,
            bytes4(keccak256("completeBootstrap()"))
        );
        assertEq(
            IEdenAdminFacet.setBasketMetadata.selector,
            bytes4(keccak256("setBasketMetadata(uint256,string,uint8)"))
        );
        assertEq(
            IEdenAdminFacet.setProtocolURI.selector,
            bytes4(keccak256("setProtocolURI(string)"))
        );
        assertEq(
            IEdenAdminFacet.setContractVersion.selector,
            bytes4(keccak256("setContractVersion(string)"))
        );
        assertEq(
            IEdenAdminFacet.setFacetVersion.selector,
            bytes4(keccak256("setFacetVersion(address,string)"))
        );
        assertEq(IEdenMetadataFacet.basketCount.selector, bytes4(keccak256("basketCount()")));
        assertEq(
            IEdenMetadataFacet.getBasketSummariesPaginated.selector,
            bytes4(keccak256("getBasketSummariesPaginated(uint256,uint256)"))
        );
        assertEq(
            IEdenPortfolioFacet.getUserPortfolio.selector,
            bytes4(keccak256("getUserPortfolio(address)"))
        );
        assertEq(IEdenAgentFacet.getProtocolState.selector, bytes4(keccak256("getProtocolState()")));
        assertEq(IEdenBatchFacet.multicall.selector, bytes4(keccak256("multicall(bytes[])")));
        assertEq(
            IEdenBatchFacet.claimAndMintStEVE.selector,
            bytes4(keccak256("claimAndMintStEVE(uint256,address)"))
        );
        assertEq(
            IEdenBatchFacet.mintWithPermit.selector,
            bytes4(keccak256("mintWithPermit(uint256,uint256,address,(address,address,address,uint256,uint256,uint8,bytes32,bytes32)[])"))
        );
        assertEq(
            IEdenBatchFacet.repayWithPermit.selector,
            bytes4(keccak256("repayWithPermit(uint256,(address,address,address,uint256,uint256,uint8,bytes32,bytes32)[])"))
        );
        assertEq(
            IEdenBatchFacet.fundRewardsWithPermit.selector,
            bytes4(keccak256("fundRewardsWithPermit(uint256,(address,address,address,uint256,uint256,uint8,bytes32,bytes32))"))
        );
    }

    function test_ExpandedInterfaces_ExposePreviewAndLifecycleSelectors() public pure {
        assertEq(IEdenLendingFacet.loanCount.selector, bytes4(keccak256("loanCount()")));
        assertEq(
            IEdenLendingFacet.getLoanIdsByBorrowerPaginated.selector,
            bytes4(keccak256("getLoanIdsByBorrowerPaginated(address,uint256,uint256)"))
        );
        assertEq(
            IEdenLendingFacet.previewBorrow.selector,
            bytes4(keccak256("previewBorrow(uint256,uint256,uint40)"))
        );
        assertEq(
            IEdenStEVEFacet.getRewardConfig.selector,
            bytes4(keccak256("getRewardConfig()"))
        );
        assertEq(
            IEdenStEVEFacet.previewClaimRewards.selector,
            bytes4(keccak256("previewClaimRewards(address)"))
        );
        assertEq(
            IEdenStEVEFacet.getRewardEpochBreakdown.selector,
            bytes4(keccak256("getRewardEpochBreakdown(address,uint256,uint256)"))
        );
    }

    function test_ActionCodeEnum_UsesStableMachineReadableValues() public pure {
        assertEq(uint8(IEdenAgentFacet.ActionCode.OK), 0);
        assertEq(uint8(IEdenAgentFacet.ActionCode.UnknownBasket), 1);
        assertEq(uint8(IEdenAgentFacet.ActionCode.BasketPaused), 2);
        assertEq(uint8(IEdenAgentFacet.ActionCode.InvalidUnits), 3);
        assertEq(uint8(IEdenAgentFacet.ActionCode.InsufficientBalance), 4);
        assertEq(uint8(IEdenAgentFacet.ActionCode.LendingDisabled), 5);
        assertEq(uint8(IEdenAgentFacet.ActionCode.InvalidDuration), 6);
        assertEq(uint8(IEdenAgentFacet.ActionCode.UnknownLoan), 7);
        assertEq(uint8(IEdenAgentFacet.ActionCode.NotBorrower), 8);
        assertEq(uint8(IEdenAgentFacet.ActionCode.LoanExpired), 9);
        assertEq(uint8(IEdenAgentFacet.ActionCode.NothingClaimable), 10);
    }
}
