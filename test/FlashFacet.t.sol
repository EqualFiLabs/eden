// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";
import { EdenFlashFacet } from "src/facets/EdenFlashFacet.sol";
import { EdenReentrancyGuard } from "src/facets/EdenReentrancyGuard.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenFlashFacet } from "src/interfaces/IEdenFlashFacet.sol";
import { IEdenFlashReceiver } from "src/interfaces/IEdenFlashReceiver.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";

contract MockERC20 is ERC20 {
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

contract FlashHarnessFacet is EdenFlashFacet {
    function setCoreConfig(
        address treasury,
        uint16 treasuryFeeBps,
        uint16 feePotShareBps,
        uint16 protocolFeeSplitBps
    ) external {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        store.treasury = treasury;
        store.treasuryFeeBps = treasuryFeeBps;
        store.feePotShareBps = feePotShareBps;
        store.protocolFeeSplitBps = protocolFeeSplitBps;
    }

    function setBasket(
        uint256 basketId,
        address token,
        address[] calldata assets,
        uint256[] calldata bundleAmounts,
        uint16 flashFeeBps,
        bool isSteve
    ) external {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        if (basketId >= store.basketCount) {
            store.basketCount = basketId + 1;
        }
        if (isSteve) {
            store.steveBasketId = basketId;
        }

        LibEdenStorage.Basket storage basket = store.baskets[basketId];
        delete basket.assets;
        delete basket.bundleAmounts;
        delete basket.mintFeeBps;
        delete basket.burnFeeBps;
        basket.token = token;
        basket.flashFeeBps = flashFeeBps;
        basket.paused = false;

        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            basket.assets.push(assets[i]);
            basket.bundleAmounts.push(bundleAmounts[i]);
            basket.mintFeeBps.push(0);
            basket.burnFeeBps.push(0);
        }
    }

    function setVaultBalance(
        uint256 basketId,
        address asset,
        uint256 amount
    ) external {
        LibEdenStorage.layout().vaultBalances[basketId][asset] = amount;
    }

    function getFeePot(
        uint256 basketId,
        address asset
    ) external view returns (uint256) {
        return LibEdenStorage.layout().feePots[basketId][asset];
    }

    function getVaultBalance(
        uint256 basketId,
        address asset
    ) external view returns (uint256) {
        return LibEdenStorage.layout().vaultBalances[basketId][asset];
    }
}

contract MockFlashReceiver is IEdenFlashReceiver {
    enum Mode {
        RepayAll,
        ShortRepay,
        Reenter
    }

    Mode public mode;
    uint256 public reenterBasketId;
    uint256 public reenterUnits;

    uint256 public lastBasketId;
    uint256 public lastUnits;
    address[] internal lastAssets;
    uint256[] internal lastAmounts;
    uint256[] internal lastFeeAmounts;

    function setMode(
        uint8 newMode,
        uint256 basketId,
        uint256 units
    ) external {
        mode = Mode(newMode);
        reenterBasketId = basketId;
        reenterUnits = units;
    }

    function getLastLoan()
        external
        view
        returns (
            uint256 basketId,
            uint256 units,
            address[] memory assets,
            uint256[] memory amounts,
            uint256[] memory feeAmounts
        )
    {
        return (lastBasketId, lastUnits, lastAssets, lastAmounts, lastFeeAmounts);
    }

    function onEdenFlashLoan(
        uint256 basketId,
        uint256 units,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata
    ) external {
        delete lastAssets;
        delete lastAmounts;
        delete lastFeeAmounts;
        lastBasketId = basketId;
        lastUnits = units;

        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            lastAssets.push(assets[i]);
            lastAmounts.push(amounts[i]);
            lastFeeAmounts.push(feeAmounts[i]);
        }

        if (mode == Mode.Reenter) {
            IEdenFlashFacet(msg.sender).flashLoan(reenterBasketId, reenterUnits, address(this), "");
        }

        for (uint256 i = 0; i < len; i++) {
            uint256 repayAmount = amounts[i] + feeAmounts[i];
            if (mode == Mode.ShortRepay && i == 0) {
                repayAmount -= 1;
            }
            IERC20(assets[i]).transfer(msg.sender, repayAmount);
        }
    }
}

contract FlashFacetTest is Test {
    uint256 internal constant UNIT = 1e18;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");

    EdenDiamond internal diamond;
    FlashHarnessFacet internal flashFacet;
    MockERC20 internal eve;
    MockERC20 internal alt;
    BasketToken internal steveToken;
    BasketToken internal basketToken;
    MockFlashReceiver internal receiver;

    function setUp() public {
        diamond = new EdenDiamond(owner, timelock);
        flashFacet = new FlashHarnessFacet();
        eve = new MockERC20("EVE", "EVE");
        alt = new MockERC20("ALT", "ALT");
        steveToken = new BasketToken("stEVE", "stEVE", address(diamond));
        basketToken = new BasketToken("Basket", "BASK", address(diamond));
        receiver = new MockFlashReceiver();

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");

        vm.prank(owner);
        FlashHarnessFacet(address(diamond)).setCoreConfig(treasury, 1000, 6000, 7500);

        address[] memory steveAssets = new address[](1);
        steveAssets[0] = address(eve);
        uint256[] memory steveBundle = new uint256[](1);
        steveBundle[0] = 1000e18;

        address[] memory basketAssets = new address[](2);
        basketAssets[0] = address(eve);
        basketAssets[1] = address(alt);
        uint256[] memory basketBundle = new uint256[](2);
        basketBundle[0] = 100e18;
        basketBundle[1] = 50e18;

        FlashHarnessFacet(address(diamond))
            .setBasket(0, address(steveToken), steveAssets, steveBundle, 0, true);
        FlashHarnessFacet(address(diamond))
            .setBasket(1, address(basketToken), basketAssets, basketBundle, 500, false);

        eve.mint(address(diamond), 400e18);
        alt.mint(address(diamond), 200e18);
        FlashHarnessFacet(address(diamond)).setVaultBalance(1, address(eve), 400e18);
        FlashHarnessFacet(address(diamond)).setVaultBalance(1, address(alt), 200e18);

        eve.mint(address(receiver), 100e18);
        alt.mint(address(receiver), 100e18);
    }

    function test_FlashLoan_TransfersCorrectAmountsAndCalculatesFees() public {
        IEdenFlashFacet(address(diamond)).flashLoan(1, UNIT, address(receiver), "");

        (
            uint256 basketId,
            uint256 units,
            address[] memory assets,
            uint256[] memory amounts,
            uint256[] memory feeAmounts
        ) = receiver.getLastLoan();

        assertEq(basketId, 1);
        assertEq(units, UNIT);
        assertEq(assets.length, 2);
        assertEq(assets[0], address(eve));
        assertEq(assets[1], address(alt));
        assertEq(amounts[0], 100e18);
        assertEq(amounts[1], 50e18);
        assertEq(feeAmounts[0], 5e18);
        assertEq(feeAmounts[1], 2.5e18);
    }

    function test_FlashLoan_RevertsWhenNotFullyRepaid() public {
        receiver.setMode(1, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                EdenFlashFacet.IncompleteFlashRepayment.selector,
                address(eve),
                uint256(405e18),
                uint256(405e18 - 1)
            )
        );
        IEdenFlashFacet(address(diamond)).flashLoan(1, UNIT, address(receiver), "");
    }

    function test_FlashLoan_DistributesFeesThroughWaterfall() public {
        IEdenFlashFacet(address(diamond)).flashLoan(1, UNIT, address(receiver), "");

        assertEq(eve.balanceOf(treasury), 0.5e18);
        assertEq(alt.balanceOf(treasury), 0.25e18);

        assertEq(FlashHarnessFacet(address(diamond)).getFeePot(1, address(eve)), 3.15e18);
        assertEq(FlashHarnessFacet(address(diamond)).getFeePot(1, address(alt)), 1.575e18);
        assertEq(FlashHarnessFacet(address(diamond)).getFeePot(0, address(eve)), 1.35e18);
        assertEq(FlashHarnessFacet(address(diamond)).getFeePot(0, address(alt)), 0.675e18);

        assertEq(FlashHarnessFacet(address(diamond)).getVaultBalance(1, address(eve)), 400e18);
        assertEq(FlashHarnessFacet(address(diamond)).getVaultBalance(1, address(alt)), 200e18);
    }

    function test_FlashLoan_ReentrantCallbackReverts() public {
        receiver.setMode(2, 1, UNIT);

        vm.expectRevert(EdenReentrancyGuard.Reentrancy.selector);
        IEdenFlashFacet(address(diamond)).flashLoan(1, UNIT, address(receiver), "");
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = IEdenFlashFacet.flashLoan.selector;
        selectors[1] = FlashHarnessFacet.setCoreConfig.selector;
        selectors[2] = FlashHarnessFacet.setBasket.selector;
        selectors[3] = FlashHarnessFacet.setVaultBalance.selector;
        selectors[4] = FlashHarnessFacet.getFeePot.selector;

        bytes4[] memory extras = new bytes4[](1);
        extras[0] = FlashHarnessFacet.getVaultBalance.selector;

        bytes4[] memory allSelectors = new bytes4[](selectors.length + extras.length);
        for (uint256 i = 0; i < selectors.length; i++) {
            allSelectors[i] = selectors[i];
        }
        allSelectors[selectors.length] = extras[0];

        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(flashFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: allSelectors
        });
    }
}
