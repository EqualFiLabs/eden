// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenAgentFacet } from "src/facets/EdenAgentFacet.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";
import { EdenLendingFacet } from "src/facets/EdenLendingFacet.sol";
import { EdenMetadataFacet } from "src/facets/EdenMetadataFacet.sol";
import { EdenPortfolioFacet } from "src/facets/EdenPortfolioFacet.sol";
import { EdenViewFacet } from "src/facets/EdenViewFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenAgentFacet } from "src/interfaces/IEdenAgentFacet.sol";
import { IEdenCoreFacet } from "src/interfaces/IEdenCoreFacet.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { IEdenMetadataFacet } from "src/interfaces/IEdenMetadataFacet.sol";
import { IEdenPortfolioFacet } from "src/interfaces/IEdenPortfolioFacet.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { IEdenViewFacet } from "src/interfaces/IEdenViewFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";

contract AgentMockERC20 is ERC20 {
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

contract AgentHarnessFacet is EdenAgentFacet {
    function setTreasury(
        address treasury
    ) external {
        LibEdenStorage.layout().treasury = treasury;
    }

    function setBasketPaused(
        uint256 basketId,
        bool paused
    ) external {
        LibEdenStorage.layout().baskets[basketId].paused = paused;
    }
}

contract AgentFacetTest is Test {
    uint256 internal constant UNIT = 1e18;
    uint256 internal constant BASE_REWARD = 50e18;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    EdenDiamond internal diamond;
    EdenCoreFacet internal coreFacet;
    EdenLendingFacet internal lendingFacet;
    EdenMetadataFacet internal metadataFacet;
    EdenPortfolioFacet internal portfolioFacet;
    EdenViewFacet internal viewFacet;
    AgentHarnessFacet internal agentFacet;
    AgentMockERC20 internal eve;
    AgentMockERC20 internal alt;
    address internal basketToken;
    uint256 internal loanId;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        coreFacet = new EdenCoreFacet();
        lendingFacet = new EdenLendingFacet();
        metadataFacet = new EdenMetadataFacet();
        portfolioFacet = new EdenPortfolioFacet();
        viewFacet = new EdenViewFacet();
        agentFacet = new AgentHarnessFacet();
        eve = new AgentMockERC20("EVE", "EVE");
        alt = new AgentMockERC20("ALT", "ALT");

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");
        AgentHarnessFacet(address(diamond)).setTreasury(treasury);

        eve.mint(owner, 20_000e18);
        eve.mint(alice, 20_000e18);
        alt.mint(alice, 20_000e18);
        vm.deal(alice, 10 ether);

        vm.startPrank(owner);
        IEdenCoreFacet(address(diamond)).createBasket(
            _basketParams("stEVE", "stEVE", _singleAddressArray(address(eve)), _singleUintArray(1_000e18))
        );
        (, basketToken) = IEdenCoreFacet(address(diamond)).createBasket(
            _basketParams(
                "Index Basket",
                "BASK",
                _doubleAddressArray(address(eve), address(alt)),
                _doubleUintArray(100e18, 50e18)
            )
        );
        IEdenCoreFacet(address(diamond)).createBasket(
            _basketParams("Alt Basket", "ALTB", _singleAddressArray(address(alt)), _singleUintArray(25e18))
        );
        IEdenLendingFacet(address(diamond)).configureLending(1, 1 days, 7 days);
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(
            1, _singleUintArray(UNIT), _singleUintArray(0.01 ether)
        );
        IEdenStEVEFacet(address(diamond)).configureRewards(
            block.timestamp, 1 days, 30, 2, BASE_REWARD, 10, BASE_REWARD
        );
        eve.approve(address(diamond), type(uint256).max);
        IEdenStEVEFacet(address(diamond)).fundRewards(500e18);
        vm.stopPrank();

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        alt.approve(address(diamond), type(uint256).max);
        IEdenCoreFacet(address(diamond)).mint(0, 2 * UNIT, alice);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);
        IERC20(basketToken).approve(address(diamond), type(uint256).max);
        loanId = IEdenLendingFacet(address(diamond)).borrow{ value: 0.01 ether }(1, UNIT, 2 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days + 1);
    }

    function test_GetProtocolState_EqualsMetadataAdminState() public view {
        IEdenMetadataFacet.ProtocolState memory protocolState =
            IEdenAgentFacet(address(diamond)).getProtocolState();
        IEdenMetadataFacet.ProtocolState memory adminState =
            IEdenMetadataFacet(address(diamond)).getAdminState();

        assertEq(protocolState.config.owner, adminState.config.owner);
        assertEq(protocolState.config.timelock, adminState.config.timelock);
        assertEq(protocolState.config.treasury, adminState.config.treasury);
        assertEq(protocolState.rewards.rewardReserve, adminState.rewards.rewardReserve);
        assertEq(protocolState.basketCount, adminState.basketCount);
        assertEq(protocolState.loanCount, adminState.loanCount);
        assertEq(protocolState.steveBasketId, adminState.steveBasketId);
        assertEq(protocolState.frozenFacets.length, adminState.frozenFacets.length);
        assertEq(protocolState.featureFlags.rewardsEnabled, adminState.featureFlags.rewardsEnabled);
        assertEq(protocolState.featureFlags.lendingEnabled, adminState.featureFlags.lendingEnabled);
    }

    function test_GetUserState_EqualsUserPortfolio() public view {
        IEdenPortfolioFacet.UserPortfolio memory userState =
            IEdenAgentFacet(address(diamond)).getUserState(alice);
        IEdenPortfolioFacet.UserPortfolio memory portfolio =
            IEdenPortfolioFacet(address(diamond)).getUserPortfolio(alice);

        assertEq(userState.user, portfolio.user);
        assertEq(userState.eveBalance, portfolio.eveBalance);
        assertEq(userState.claimableRewards, portfolio.claimableRewards);
        assertEq(userState.stEveBalance, portfolio.stEveBalance);
        assertEq(userState.stEveLocked, portfolio.stEveLocked);
        assertEq(userState.basketCount, portfolio.basketCount);
        assertEq(userState.loanCount, portfolio.loanCount);
        assertEq(userState.baskets.length, portfolio.baskets.length);
        assertEq(userState.loans.length, portfolio.loans.length);
    }

    function test_GetBasketState_EqualsBasketSummary() public view {
        IEdenMetadataFacet.BasketSummary memory basketState =
            IEdenAgentFacet(address(diamond)).getBasketState(1);
        IEdenMetadataFacet.BasketSummary memory summary =
            IEdenMetadataFacet(address(diamond)).getBasketSummary(1);

        assertEq(basketState.basketId, summary.basketId);
        assertEq(basketState.token, summary.token);
        assertEq(basketState.lendingEnabled, summary.lendingEnabled);
        assertEq(basketState.totalUnits, summary.totalUnits);
        assertEq(basketState.assets.length, summary.assets.length);
        assertEq(basketState.bundleAmounts[0], summary.bundleAmounts[0]);
    }

    function test_GetLoanState_EqualsLoanView() public view {
        IEdenLendingFacet.LoanView memory loanState = IEdenAgentFacet(address(diamond)).getLoanState(loanId);
        IEdenLendingFacet.LoanView memory loanView =
            IEdenLendingFacet(address(diamond)).getLoanView(loanId);

        assertEq(loanState.loanId, loanView.loanId);
        assertEq(loanState.borrower, loanView.borrower);
        assertEq(loanState.basketId, loanView.basketId);
        assertEq(loanState.collateralUnits, loanView.collateralUnits);
        assertEq(loanState.expired, loanView.expired);
    }

    function test_ActionValidation_MintBurnAndBorrowChecks() public {
        IEdenAgentFacet.ActionCheck memory validMint =
            IEdenAgentFacet(address(diamond)).canMint(alice, 1, UNIT);
        assertTrue(validMint.ok);
        assertEq(validMint.code, uint8(IEdenAgentFacet.ActionCode.OK));

        AgentHarnessFacet(address(diamond)).setBasketPaused(1, true);
        IEdenAgentFacet.ActionCheck memory pausedMint =
            IEdenAgentFacet(address(diamond)).canMint(alice, 1, UNIT);
        assertFalse(pausedMint.ok);
        assertEq(pausedMint.code, uint8(IEdenAgentFacet.ActionCode.BasketPaused));
        AgentHarnessFacet(address(diamond)).setBasketPaused(1, false);

        IEdenAgentFacet.ActionCheck memory invalidMint =
            IEdenAgentFacet(address(diamond)).canMint(alice, 1, 1);
        assertFalse(invalidMint.ok);
        assertEq(invalidMint.code, uint8(IEdenAgentFacet.ActionCode.InvalidUnits));

        IEdenAgentFacet.ActionCheck memory insufficientBurn =
            IEdenAgentFacet(address(diamond)).canBurn(bob, 1, UNIT);
        assertFalse(insufficientBurn.ok);
        assertEq(insufficientBurn.code, uint8(IEdenAgentFacet.ActionCode.InsufficientBalance));

        IEdenAgentFacet.ActionCheck memory disabledBorrow =
            IEdenAgentFacet(address(diamond)).canBorrow(alice, 0, UNIT, 2 days);
        assertFalse(disabledBorrow.ok);
        assertEq(disabledBorrow.code, uint8(IEdenAgentFacet.ActionCode.LendingDisabled));

        IEdenAgentFacet.ActionCheck memory invalidDurationBorrow =
            IEdenAgentFacet(address(diamond)).canBorrow(alice, 1, UNIT, 12 hours);
        assertFalse(invalidDurationBorrow.ok);
        assertEq(invalidDurationBorrow.code, uint8(IEdenAgentFacet.ActionCode.InvalidDuration));

        IEdenAgentFacet.ActionCheck memory validBorrow =
            IEdenAgentFacet(address(diamond)).canBorrow(alice, 1, UNIT, 2 days);
        assertTrue(validBorrow.ok);
        assertEq(validBorrow.code, uint8(IEdenAgentFacet.ActionCode.OK));
    }

    function test_ActionValidation_RepayExtendClaimChecksAndStableCodes() public view {
        IEdenAgentFacet.ActionCheck memory unknownLoan =
            IEdenAgentFacet(address(diamond)).canRepay(alice, 999);
        assertFalse(unknownLoan.ok);
        assertEq(unknownLoan.code, uint8(IEdenAgentFacet.ActionCode.UnknownLoan));

        IEdenAgentFacet.ActionCheck memory notBorrower =
            IEdenAgentFacet(address(diamond)).canRepay(bob, loanId);
        assertFalse(notBorrower.ok);
        assertEq(notBorrower.code, uint8(IEdenAgentFacet.ActionCode.NotBorrower));

        IEdenAgentFacet.ActionCheck memory expiredLoan =
            IEdenAgentFacet(address(diamond)).canExtend(alice, loanId, 1 days);
        assertFalse(expiredLoan.ok);
        assertEq(expiredLoan.code, uint8(IEdenAgentFacet.ActionCode.LoanExpired));

        IEdenAgentFacet.ActionCheck memory nothingClaimable =
            IEdenAgentFacet(address(diamond)).canClaimRewards(bob);
        assertFalse(nothingClaimable.ok);
        assertEq(nothingClaimable.code, uint8(IEdenAgentFacet.ActionCode.NothingClaimable));
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](6);

        bytes4[] memory coreSelectors = new bytes4[](4);
        coreSelectors[0] = IEdenCoreFacet.createBasket.selector;
        coreSelectors[1] = IEdenCoreFacet.mint.selector;
        coreSelectors[2] = IEdenCoreFacet.burn.selector;
        coreSelectors[3] = IEdenCoreFacet.onBasketTokenTransfer.selector;
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(coreFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: coreSelectors
        });

        bytes4[] memory lendingSelectors = new bytes4[](10);
        lendingSelectors[0] = IEdenLendingFacet.configureLending.selector;
        lendingSelectors[1] = IEdenLendingFacet.configureBorrowFeeTiers.selector;
        lendingSelectors[2] = IEdenLendingFacet.borrow.selector;
        lendingSelectors[3] = IEdenLendingFacet.repay.selector;
        lendingSelectors[4] = IEdenLendingFacet.getLoanView.selector;
        lendingSelectors[5] = IEdenLendingFacet.previewBorrow.selector;
        lendingSelectors[6] = IEdenStEVEFacet.onStEVETransfer.selector;
        lendingSelectors[7] = IEdenStEVEFacet.configureRewards.selector;
        lendingSelectors[8] = IEdenStEVEFacet.fundRewards.selector;
        lendingSelectors[9] = IEdenStEVEFacet.claimableRewards.selector;
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(lendingFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: lendingSelectors
        });

        bytes4[] memory metadataSelectors = new bytes4[](2);
        metadataSelectors[0] = IEdenMetadataFacet.getAdminState.selector;
        metadataSelectors[1] = IEdenMetadataFacet.getBasketSummary.selector;
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(metadataFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: metadataSelectors
        });

        bytes4[] memory portfolioSelectors = new bytes4[](1);
        portfolioSelectors[0] = IEdenPortfolioFacet.getUserPortfolio.selector;
        cuts[3] = IDiamondCut.FacetCut({
            facetAddress: address(portfolioFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: portfolioSelectors
        });

        bytes4[] memory viewSelectors = new bytes4[](1);
        viewSelectors[0] = IEdenViewFacet.previewMint.selector;
        cuts[4] = IDiamondCut.FacetCut({
            facetAddress: address(viewFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: viewSelectors
        });

        bytes4[] memory agentSelectors = new bytes4[](12);
        agentSelectors[0] = AgentHarnessFacet.setTreasury.selector;
        agentSelectors[1] = AgentHarnessFacet.setBasketPaused.selector;
        agentSelectors[2] = IEdenAgentFacet.getProtocolState.selector;
        agentSelectors[3] = IEdenAgentFacet.getUserState.selector;
        agentSelectors[4] = IEdenAgentFacet.getBasketState.selector;
        agentSelectors[5] = IEdenAgentFacet.getLoanState.selector;
        agentSelectors[6] = IEdenAgentFacet.canMint.selector;
        agentSelectors[7] = IEdenAgentFacet.canBurn.selector;
        agentSelectors[8] = IEdenAgentFacet.canBorrow.selector;
        agentSelectors[9] = IEdenAgentFacet.canRepay.selector;
        agentSelectors[10] = IEdenAgentFacet.canExtend.selector;
        agentSelectors[11] = IEdenAgentFacet.canClaimRewards.selector;
        cuts[5] = IDiamondCut.FacetCut({
            facetAddress: address(agentFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: agentSelectors
        });
    }

    function _basketParams(
        string memory name_,
        string memory symbol_,
        address[] memory assets,
        uint256[] memory bundleAmounts
    ) internal pure returns (IEdenCoreFacet.CreateBasketParams memory params) {
        params = IEdenCoreFacet.CreateBasketParams({
            name: name_,
            symbol: symbol_,
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeBps: _zeroUint16Array(assets.length),
            burnFeeBps: _zeroUint16Array(assets.length),
            flashFeeBps: 0
        });
    }

    function _singleAddressArray(
        address value
    ) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _doubleAddressArray(
        address a0,
        address a1
    ) internal pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = a0;
        values[1] = a1;
    }

    function _singleUintArray(
        uint256 value
    ) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _doubleUintArray(
        uint256 v0,
        uint256 v1
    ) internal pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = v0;
        values[1] = v1;
    }

    function _zeroUint16Array(
        uint256 len
    ) internal pure returns (uint16[] memory values) {
        values = new uint16[](len);
    }
}
