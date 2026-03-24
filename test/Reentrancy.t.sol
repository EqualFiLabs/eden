// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { DiamondLoupeFacet } from "src/facets/DiamondLoupeFacet.sol";
import { EdenAdminFacet } from "src/facets/EdenAdminFacet.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";
import { EdenFlashFacet } from "src/facets/EdenFlashFacet.sol";
import { EdenLendingFacet } from "src/facets/EdenLendingFacet.sol";
import { EdenReentrancyGuard } from "src/facets/EdenReentrancyGuard.sol";
import { EdenStEVEFacet } from "src/facets/EdenStEVEFacet.sol";
import { EdenViewFacet } from "src/facets/EdenViewFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "src/interfaces/IDiamondLoupe.sol";
import { IEdenAdminFacet } from "src/interfaces/IEdenAdminFacet.sol";
import { IEdenCoreFacet } from "src/interfaces/IEdenCoreFacet.sol";
import { IEdenFlashFacet } from "src/interfaces/IEdenFlashFacet.sol";
import { IEdenFlashReceiver } from "src/interfaces/IEdenFlashReceiver.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { IEdenViewFacet } from "src/interfaces/IEdenViewFacet.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";
import { StEVEToken } from "src/tokens/StEVEToken.sol";

contract CallbackERC20 is ERC20 {
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackOnTransfer;
    bool public callbackOnTransferFrom;
    bool internal inCallback;
    bool public callbackAttempted;
    bool public callbackSucceeded;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureCallback(
        address target,
        bytes calldata data,
        bool onTransfer,
        bool onTransferFrom
    ) external {
        callbackTarget = target;
        callbackData = data;
        callbackOnTransfer = onTransfer;
        callbackOnTransferFrom = onTransferFrom;
        callbackAttempted = false;
        callbackSucceeded = false;
    }

    function clearCallback() external {
        callbackTarget = address(0);
        delete callbackData;
        callbackOnTransfer = false;
        callbackOnTransferFrom = false;
        callbackAttempted = false;
        callbackSucceeded = false;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool success = super.transfer(to, value);
        if (callbackOnTransfer) {
            _attemptCallback();
        }
        return success;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool success = super.transferFrom(from, to, value);
        if (callbackOnTransferFrom) {
            _attemptCallback();
        }
        return success;
    }

    function _attemptCallback() internal {
        if (inCallback || callbackTarget == address(0)) return;
        inCallback = true;
        callbackAttempted = true;
        (callbackSucceeded,) = callbackTarget.call(callbackData);
        inCallback = false;
    }
}

contract SettlingReceiver is IEdenFlashReceiver {
    function onEdenFlashLoan(
        uint256,
        uint256,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata
    ) external {
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            ERC20(assets[i]).transfer(msg.sender, amounts[i] + feeAmounts[i]);
        }
    }
}

contract ReenteringFlashReceiver is IEdenFlashReceiver {
    function onEdenFlashLoan(
        uint256 basketId,
        uint256 units,
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external {
        IEdenFlashFacet(msg.sender).flashLoan(basketId, units, address(this), "");
    }
}

contract StateObserver {
    error UnexpectedVaultBalance(uint256 actual, uint256 expected);

    function expectVaultBalance(
        address viewFacet,
        uint256 basketId,
        address asset,
        uint256 expected
    ) external view {
        uint256 actual = IEdenViewFacet(viewFacet).getVaultBalance(basketId, asset);
        if (actual != expected) revert UnexpectedVaultBalance(actual, expected);
    }
}

contract ReenteringTreasury {
    error UnexpectedMaturity(uint40 actual, uint40 expected);

    address public target;
    bytes public data;
    address public viewFacet;
    uint256 public loanId;
    uint40 public expectedMaturity;
    bool public attempted;
    bool public succeeded;
    bool public observedUpdatedMaturity;
    bool internal inCallback;

    function configure(
        address target_,
        bytes calldata data_,
        address viewFacet_,
        uint256 loanId_,
        uint40 expectedMaturity_
    ) external {
        target = target_;
        data = data_;
        viewFacet = viewFacet_;
        loanId = loanId_;
        expectedMaturity = expectedMaturity_;
        attempted = false;
        succeeded = false;
        observedUpdatedMaturity = false;
    }

    receive() external payable {
        if (viewFacet != address(0)) {
            uint40 actual = IEdenViewFacet(viewFacet).getLoan(loanId).maturity;
            if (actual != expectedMaturity) revert UnexpectedMaturity(actual, expectedMaturity);
            observedUpdatedMaturity = true;
        }

        if (inCallback || target == address(0)) return;
        inCallback = true;
        attempted = true;
        (succeeded,) = target.call(data);
        inCallback = false;
    }
}

contract ReentrancyTest is Test {
    uint256 internal constant UNIT = 1e18;
    uint256 internal constant DAY = 1 days;
    uint256 internal constant BASE_REWARD = 100e18;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal alice = makeAddr("alice");

    EdenDiamond internal diamond;
    DiamondLoupeFacet internal loupeFacet;
    EdenCoreFacet internal coreFacet;
    EdenStEVEFacet internal stEveFacet;
    EdenLendingFacet internal lendingFacet;
    EdenAdminFacet internal adminFacet;
    EdenViewFacet internal viewFacet;
    EdenFlashFacet internal flashFacet;

    CallbackERC20 internal eve;
    ERC20 internal alt;
    SettlingReceiver internal settlingReceiver;
    ReenteringFlashReceiver internal reenteringFlashReceiver;
    StateObserver internal stateObserver;
    ReenteringTreasury internal treasury;
    StEVEToken internal stEveToken;
    BasketToken internal basketToken;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        loupeFacet = new DiamondLoupeFacet();
        coreFacet = new EdenCoreFacet();
        stEveFacet = new EdenStEVEFacet();
        lendingFacet = new EdenLendingFacet();
        adminFacet = new EdenAdminFacet();
        viewFacet = new EdenViewFacet();
        flashFacet = new EdenFlashFacet();

        eve = new CallbackERC20("EVE", "EVE");
        alt = new CallbackERC20("ALT", "ALT");
        settlingReceiver = new SettlingReceiver();
        reenteringFlashReceiver = new ReenteringFlashReceiver();
        stateObserver = new StateObserver();
        treasury = new ReenteringTreasury();

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");

        vm.startPrank(owner);
        IEdenAdminFacet(address(diamond)).setTreasury(address(treasury));
        IEdenAdminFacet(address(diamond)).setTreasuryFeeBps(1000);
        IEdenAdminFacet(address(diamond)).setFeePotShareBps(6000);
        IEdenAdminFacet(address(diamond)).setProtocolFeeSplitBps(7500);
        vm.stopPrank();

        eve.mint(owner, 20_000_000e18);
        eve.mint(alice, 20_000_000e18);
        eve.mint(address(settlingReceiver), 20_000_000e18);
        CallbackERC20(address(alt)).mint(alice, 20_000_000e18);
        CallbackERC20(address(alt)).mint(address(settlingReceiver), 20_000_000e18);

        vm.prank(owner);
        (, address stEveTokenAddress) = IEdenCoreFacet(address(diamond)).createBasket(_stEveParams());
        stEveToken = StEVEToken(stEveTokenAddress);

        vm.prank(owner);
        (, address basketTokenAddress) = IEdenCoreFacet(address(diamond)).createBasket(_basketParams());
        basketToken = BasketToken(basketTokenAddress);

        vm.startPrank(owner);
        IEdenStEVEFacet(address(diamond)).configureRewards(
            block.timestamp,
            DAY,
            183,
            3,
            BASE_REWARD,
            548,
            BASE_REWARD
        );
        eve.approve(address(diamond), type(uint256).max);
        IEdenStEVEFacet(address(diamond)).fundRewards(10_000e18);
        IEdenLendingFacet(address(diamond)).configureLending(1, 1 days, 10 days);
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(
            1, _u256Array(UNIT, 2 * UNIT), _u256Array(0.2 ether, 0.02 ether)
        );
        vm.stopPrank();

        vm.startPrank(alice);
        eve.approve(address(diamond), type(uint256).max);
        CallbackERC20(address(alt)).approve(address(diamond), type(uint256).max);
        stEveToken.approve(address(diamond), type(uint256).max);
        basketToken.approve(address(diamond), type(uint256).max);
        vm.stopPrank();

        vm.deal(alice, 20 ether);
    }

    function test_ReentrancyGuard_MintBlocksNestedFlashLoan() public {
        eve.configureCallback(
            address(diamond), abi.encodeCall(IEdenFlashFacet.flashLoan, (0, UNIT, address(settlingReceiver), "")), false, true
        );

        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);

        assertTrue(eve.callbackAttempted());
        assertFalse(eve.callbackSucceeded());
        assertEq(basketToken.balanceOf(alice), UNIT);
    }

    function test_ReentrancyGuard_ClaimRewardsBlocksNestedFlashLoan() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(0, UNIT, alice);
        vm.warp(block.timestamp + DAY + 1);

        eve.configureCallback(
            address(diamond), abi.encodeCall(IEdenFlashFacet.flashLoan, (0, UNIT, address(settlingReceiver), "")), true, false
        );

        vm.prank(alice);
        IEdenStEVEFacet(address(diamond)).claimRewards();

        assertTrue(eve.callbackAttempted());
        assertFalse(eve.callbackSucceeded());
    }

    function test_ReentrancyGuard_BorrowAndRepayBlockNestedFlashLoan() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);

        eve.configureCallback(
            address(diamond), abi.encodeCall(IEdenFlashFacet.flashLoan, (0, UNIT, address(settlingReceiver), "")), true, false
        );

        vm.prank(alice);
        uint256 loanId = IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 1 days);

        assertTrue(eve.callbackAttempted());
        assertFalse(eve.callbackSucceeded());

        eve.configureCallback(
            address(diamond), abi.encodeCall(IEdenFlashFacet.flashLoan, (0, UNIT, address(settlingReceiver), "")), false, true
        );

        vm.prank(alice);
        IEdenLendingFacet(address(diamond)).repay(loanId);

        assertTrue(eve.callbackAttempted());
        assertFalse(eve.callbackSucceeded());
    }

    function test_ReentrancyGuard_ExtendBlocksNestedFlashLoanAndUsesCEI() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, 2 * UNIT, alice);

        vm.prank(alice);
        uint256 loanId = IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 1 days);

        uint40 expectedMaturity = uint40(block.timestamp + 2 days);
        treasury.configure(
            address(diamond),
            abi.encodeCall(IEdenFlashFacet.flashLoan, (0, UNIT, address(settlingReceiver), "")),
            address(diamond),
            loanId,
            expectedMaturity
        );

        vm.prank(alice);
        IEdenLendingFacet(address(diamond)).extend{ value: 0.2 ether }(loanId, 1 days);

        assertTrue(treasury.observedUpdatedMaturity());
        assertTrue(treasury.attempted());
        assertFalse(treasury.succeeded());
    }

    function test_ReentrancyGuard_FlashLoanBlocksReceiverReentry() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(0, 2 * UNIT, alice);

        vm.expectRevert(EdenReentrancyGuard.Reentrancy.selector);
        IEdenFlashFacet(address(diamond)).flashLoan(0, UNIT, address(reenteringFlashReceiver), "");
    }

    function test_CEI_BurnUpdatesVaultStateBeforeTokenTransfer() public {
        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);

        eve.configureCallback(
            address(stateObserver),
            abi.encodeCall(StateObserver.expectVaultBalance, (address(diamond), 1, address(eve), 0)),
            true,
            false
        );

        vm.prank(alice);
        IEdenCoreFacet(address(diamond)).burn(1, UNIT, alice);

        assertTrue(eve.callbackAttempted());
        assertTrue(eve.callbackSucceeded());
    }

    function _stEveParams() internal view returns (IEdenCoreFacet.CreateBasketParams memory params) {
        params = IEdenCoreFacet.CreateBasketParams({
            name: "Staked EVE",
            symbol: "stEVE",
            assets: _addressArray(address(eve)),
            bundleAmounts: _uintArraySingle(1000e18),
            mintFeeBps: _u16ArraySingle(0),
            burnFeeBps: _u16ArraySingle(0),
            flashFeeBps: 0
        });
    }

    function _basketParams() internal view returns (IEdenCoreFacet.CreateBasketParams memory params) {
        address[] memory assets = new address[](2);
        assets[0] = address(eve);
        assets[1] = address(alt);

        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 100e18;
        bundleAmounts[1] = 50e18;

        uint16[] memory zeroFees = new uint16[](2);

        params = IEdenCoreFacet.CreateBasketParams({
            name: "Eden Basket",
            symbol: "EDEN",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeBps: zeroFees,
            burnFeeBps: zeroFees,
            flashFeeBps: 500
        });
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](7);
        cuts[0] = _cut(address(coreFacet), _coreSelectors());
        cuts[1] = _cut(address(stEveFacet), _stEveSelectors());
        cuts[2] = _cut(address(lendingFacet), _lendingSelectors());
        cuts[3] = _cut(address(adminFacet), _adminSelectors());
        cuts[4] = _cut(address(viewFacet), _viewSelectors());
        cuts[5] = _cut(address(flashFacet), _flashSelectors());
        cuts[6] = _cut(address(loupeFacet), _loupeSelectors());
    }

    function _cut(address facet, bytes4[] memory selectors)
        internal
        pure
        returns (IDiamondCut.FacetCut memory)
    {
        return IDiamondCut.FacetCut({
            facetAddress: facet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
    }

    function _coreSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IEdenCoreFacet.createBasket.selector;
        selectors[1] = IEdenCoreFacet.mint.selector;
        selectors[2] = IEdenCoreFacet.burn.selector;
        selectors[3] = IEdenCoreFacet.onBasketTokenTransfer.selector;
    }

    function _stEveSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = IEdenStEVEFacet.claimRewards.selector;
        selectors[1] = IEdenStEVEFacet.configureRewards.selector;
        selectors[2] = IEdenStEVEFacet.fundRewards.selector;
        selectors[3] = IEdenStEVEFacet.setRewardPerEpoch.selector;
        selectors[4] = IEdenStEVEFacet.rewardForEpoch.selector;
        selectors[5] = IEdenStEVEFacet.currentEpoch.selector;
        selectors[6] = IEdenStEVEFacet.rewardReserveBalance.selector;
        selectors[7] = IEdenStEVEFacet.currentEmissionRate.selector;
        selectors[8] = IEdenStEVEFacet.getUserTwab.selector;
        selectors[9] = IEdenStEVEFacet.onStEVETransfer.selector;
    }

    function _lendingSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IEdenLendingFacet.borrow.selector;
        selectors[1] = IEdenLendingFacet.repay.selector;
        selectors[2] = IEdenLendingFacet.extend.selector;
        selectors[3] = IEdenLendingFacet.recoverExpired.selector;
        selectors[4] = IEdenLendingFacet.configureLending.selector;
        selectors[5] = IEdenLendingFacet.configureBorrowFeeTiers.selector;
    }

    function _adminSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = IEdenAdminFacet.setIndexFees.selector;
        selectors[1] = IEdenAdminFacet.setTreasuryFeeBps.selector;
        selectors[2] = IEdenAdminFacet.setFeePotShareBps.selector;
        selectors[3] = IEdenAdminFacet.setProtocolFeeSplitBps.selector;
        selectors[4] = IEdenAdminFacet.setBasketCreationFee.selector;
        selectors[5] = IEdenAdminFacet.setPaused.selector;
        selectors[6] = IEdenAdminFacet.setTreasury.selector;
        selectors[7] = IEdenAdminFacet.setTimelock.selector;
        selectors[8] = IEdenAdminFacet.freezeFacet.selector;
    }

    function _viewSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](13);
        selectors[0] = IEdenViewFacet.nav.selector;
        selectors[1] = IEdenViewFacet.getBasket.selector;
        selectors[2] = IEdenViewFacet.totalBacking.selector;
        selectors[3] = IEdenViewFacet.getEconomicBalance.selector;
        selectors[4] = IEdenViewFacet.getVaultBalance.selector;
        selectors[5] = IEdenViewFacet.getFeePot.selector;
        selectors[6] = IEdenViewFacet.previewMint.selector;
        selectors[7] = IEdenViewFacet.previewBurn.selector;
        selectors[8] = IEdenViewFacet.getLoan.selector;
        selectors[9] = IEdenViewFacet.quoteBorrow.selector;
        selectors[10] = IEdenViewFacet.maxBorrowable.selector;
        selectors[11] = IEdenViewFacet.getLockedCollateral.selector;
        selectors[12] = IEdenViewFacet.getOutstandingPrincipal.selector;
    }

    function _flashSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IEdenFlashFacet.flashLoan.selector;
    }

    function _loupeSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
    }

    function _addressArray(address a) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = a;
    }

    function _uintArraySingle(uint256 a) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = a;
    }

    function _u16ArraySingle(uint16 a) internal pure returns (uint16[] memory values) {
        values = new uint16[](1);
        values[0] = a;
    }

    function _u256Array(uint256 a, uint256 b) internal pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = a;
        values[1] = b;
    }
}
