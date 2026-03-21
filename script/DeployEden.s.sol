// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { DiamondLoupeFacet } from "src/facets/DiamondLoupeFacet.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";
import { EdenStEVEFacet } from "src/facets/EdenStEVEFacet.sol";
import { EdenLendingFacet } from "src/facets/EdenLendingFacet.sol";
import { EdenAdminFacet } from "src/facets/EdenAdminFacet.sol";
import { EdenViewFacet } from "src/facets/EdenViewFacet.sol";
import { EdenFlashFacet } from "src/facets/EdenFlashFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "src/interfaces/IDiamondLoupe.sol";
import { IEdenAdminFacet } from "src/interfaces/IEdenAdminFacet.sol";
import { IEdenCoreFacet } from "src/interfaces/IEdenCoreFacet.sol";
import { IEdenFlashFacet } from "src/interfaces/IEdenFlashFacet.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { IEdenViewFacet } from "src/interfaces/IEdenViewFacet.sol";

contract DeployEden is Script {
    uint16 internal constant DEFAULT_TREASURY_FEE_BPS = 1000;
    uint16 internal constant DEFAULT_FEE_POT_SHARE_BPS = 6000;
    uint16 internal constant DEFAULT_PROTOCOL_FEE_SPLIT_BPS = 7500;
    uint256 internal constant ST_EVE_BUNDLE = 1000e18;
    uint256 internal constant BASE_REWARD_PER_EPOCH = 6_250_000e18;
    uint256 internal constant MAX_REWARD_OVERRIDE = BASE_REWARD_PER_EPOCH;
    uint256 internal constant HALVING_INTERVAL = 183;
    uint256 internal constant MAX_PERIODS = 3;
    uint256 internal constant TOTAL_EPOCHS = 548;
    uint256 internal constant EPOCH_DURATION = 1 days;
    uint256 internal constant INITIAL_REWARD_RESERVE = 2_000_000_000e18;

    struct Deployment {
        EdenDiamond diamond;
        EdenCoreFacet coreFacet;
        EdenStEVEFacet stEveFacet;
        EdenLendingFacet lendingFacet;
        EdenAdminFacet adminFacet;
        EdenViewFacet viewFacet;
        EdenFlashFacet flashFacet;
        DiamondLoupeFacet loupeFacet;
    }

    function run() external returns (Deployment memory deployment) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(deployerKey);
        address owner = vm.envOr("EDEN_OWNER", broadcaster);
        address timelock = vm.envOr("EDEN_TIMELOCK", broadcaster);
        address treasury = vm.envOr("EDEN_TREASURY", broadcaster);
        address eve = vm.envAddress("EDEN_EVE_TOKEN");
        uint256 genesisTimestamp = vm.envOr("EDEN_GENESIS_TIMESTAMP", block.timestamp);

        vm.startBroadcast(deployerKey);

        deployment = _deploySystem(owner, timelock);
        _registerFacets(deployment);
        _initializeProtocol(deployment.diamond, eve, treasury, genesisTimestamp);

        vm.stopBroadcast();
    }

    function _deploySystem(
        address owner,
        address timelock
    ) internal returns (Deployment memory deployment) {
        deployment.diamond = new EdenDiamond(owner, timelock);
        deployment.coreFacet = new EdenCoreFacet();
        deployment.stEveFacet = new EdenStEVEFacet();
        deployment.lendingFacet = new EdenLendingFacet();
        deployment.adminFacet = new EdenAdminFacet();
        deployment.viewFacet = new EdenViewFacet();
        deployment.flashFacet = new EdenFlashFacet();
        deployment.loupeFacet = new DiamondLoupeFacet();
    }

    function _registerFacets(
        Deployment memory deployment
    ) internal {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](7);
        cuts[0] = _cut(address(deployment.coreFacet), _coreSelectors());
        cuts[1] = _cut(address(deployment.stEveFacet), _stEveSelectors());
        cuts[2] = _cut(address(deployment.lendingFacet), _lendingSelectors());
        cuts[3] = _cut(address(deployment.adminFacet), _adminSelectors());
        cuts[4] = _cut(address(deployment.viewFacet), _viewSelectors());
        cuts[5] = _cut(address(deployment.flashFacet), _flashSelectors());
        cuts[6] = _cut(address(deployment.loupeFacet), _loupeSelectors());
        IDiamondCut(address(deployment.diamond)).diamondCut(cuts, address(0), "");
    }

    function _initializeProtocol(
        EdenDiamond diamond,
        address eve,
        address treasury,
        uint256 genesisTimestamp
    ) internal {
        IEdenAdminFacet(address(diamond)).setTreasury(treasury);
        IEdenAdminFacet(address(diamond)).setTreasuryFeeBps(DEFAULT_TREASURY_FEE_BPS);
        IEdenAdminFacet(address(diamond)).setFeePotShareBps(DEFAULT_FEE_POT_SHARE_BPS);
        IEdenAdminFacet(address(diamond)).setProtocolFeeSplitBps(DEFAULT_PROTOCOL_FEE_SPLIT_BPS);

        IEdenCoreFacet.CreateBasketParams memory stEveParams = IEdenCoreFacet.CreateBasketParams({
            name: "Staked EVE",
            symbol: "stEVE",
            assets: _singleAddressArray(eve),
            bundleAmounts: _singleUint256Array(ST_EVE_BUNDLE),
            mintFeeBps: _singleUint16Array(0),
            burnFeeBps: _singleUint16Array(0),
            flashFeeBps: 0
        });
        IEdenCoreFacet(address(diamond)).createBasket(stEveParams);

        IEdenStEVEFacet(address(diamond)).configureRewards(
            genesisTimestamp,
            EPOCH_DURATION,
            HALVING_INTERVAL,
            MAX_PERIODS,
            BASE_REWARD_PER_EPOCH,
            TOTAL_EPOCHS,
            MAX_REWARD_OVERRIDE
        );

        IERC20(eve).approve(address(diamond), INITIAL_REWARD_RESERVE);
        IEdenStEVEFacet(address(diamond)).fundRewards(INITIAL_REWARD_RESERVE);
    }

    function _cut(
        address facet,
        bytes4[] memory selectors
    ) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
    }

    function _coreSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IEdenCoreFacet.createBasket.selector;
        selectors[1] = IEdenCoreFacet.mint.selector;
        selectors[2] = IEdenCoreFacet.burn.selector;
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

    function _singleAddressArray(
        address value
    ) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleUint256Array(
        uint256 value
    ) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _singleUint16Array(
        uint16 value
    ) internal pure returns (uint16[] memory values) {
        values = new uint16[](1);
        values[0] = value;
    }
}
