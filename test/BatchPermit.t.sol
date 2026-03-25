// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenBatchFacet } from "src/facets/EdenBatchFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenBatchFacet } from "src/interfaces/IEdenBatchFacet.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { LibStEVEStorage } from "src/libraries/LibStEVEStorage.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";
import { StEVEToken } from "src/tokens/StEVEToken.sol";

contract PermitToken is ERC20, ERC20Permit {
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackOnTransfer;
    bool public callbackOnTransferFrom;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bool internal inCallback;

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC20Permit(name_) { }

    function mint(
        address to,
        uint256 amount
    ) external {
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

contract BatchPermitHarnessFacet is EdenBatchFacet {
    function onBasketTokenTransfer(
        address,
        address,
        uint256
    ) external pure { }

    function setCoreConfig(
        address treasury,
        uint256 treasuryFeeBps,
        uint256 feePotShareBps,
        uint256 protocolFeeSplitBps
    ) external {
        LibEdenStorage.EdenStorage storage store = LibEdenStorage.layout();
        store.treasury = treasury;
        store.treasuryFeeBps = uint16(treasuryFeeBps);
        store.feePotShareBps = uint16(feePotShareBps);
        store.protocolFeeSplitBps = uint16(protocolFeeSplitBps);
    }

    function setBasket(
        uint256 basketId,
        address token,
        address[] calldata assets,
        uint256[] calldata bundleAmounts,
        uint16[] calldata mintFeeBps,
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
        basket.paused = false;

        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            basket.assets.push(assets[i]);
            basket.bundleAmounts.push(bundleAmounts[i]);
            basket.mintFeeBps.push(mintFeeBps[i]);
            basket.burnFeeBps.push(0);
        }
    }

    function setRewardReserve(
        uint256 amount
    ) external {
        LibStEVEStorage.layout().rewardReserve = amount;
    }

    function mintReceiptUnits(
        uint256 basketId,
        address to,
        uint256 amount
    ) external {
        LibEdenStorage.Basket storage basket = LibEdenStorage.layout().baskets[basketId];
        basket.totalUnits += amount;
        BasketToken(basket.token).mintIndexUnits(to, amount);
    }

    function setVaultBalance(
        uint256 basketId,
        address asset,
        uint256 amount
    ) external {
        LibEdenStorage.layout().vaultBalances[basketId][asset] = amount;
    }

    function getVaultBalance(
        uint256 basketId,
        address asset
    ) external view returns (uint256) {
        return LibEdenStorage.layout().vaultBalances[basketId][asset];
    }

    function getRewardReserve() external view returns (uint256) {
        return LibStEVEStorage.layout().rewardReserve;
    }

    function getLoanClosed(
        uint256 loanId
    ) external view returns (bool) {
        return LibLendingStorage.layout().loanClosed[loanId];
    }
}

contract BatchPermitTest is Test {
    bytes32 internal constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );
    uint256 internal constant OWNER_PK = 0xA11;
    uint256 internal constant ALICE_PK = 0xA11CE;
    uint256 internal constant BOB_PK = 0xB0B;
    uint256 internal constant UNIT = 1e18;

    address internal owner;
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");
    address internal alice;
    address internal bob;

    EdenDiamond internal diamond;
    BatchPermitHarnessFacet internal batchFacet;
    PermitToken internal eve;
    PermitToken internal alt;
    StEVEToken internal stEveToken;
    BasketToken internal indexToken;

    function setUp() public {
        owner = vm.addr(OWNER_PK);
        alice = vm.addr(ALICE_PK);
        bob = vm.addr(BOB_PK);

        diamond = new EdenDiamond(owner, timelock);
        batchFacet = new BatchPermitHarnessFacet();
        eve = new PermitToken("EVE", "EVE");
        alt = new PermitToken("ALT", "ALT");
        stEveToken = new StEVEToken("stEVE", "stEVE", address(diamond));
        indexToken = new BasketToken("Index", "IDX", address(diamond));

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");

        BatchPermitHarnessFacet(address(diamond)).setCoreConfig(treasury, 1000, 6000, 7500);
        _setUpBaskets();
        _setUpLending();
        BatchPermitHarnessFacet(address(diamond)).setVaultBalance(1, address(eve), 200e18);
        BatchPermitHarnessFacet(address(diamond)).setVaultBalance(1, address(alt), 100e18);

        eve.mint(owner, 1_000_000e18);
        eve.mint(alice, 1_000_000e18);
        alt.mint(alice, 1_000_000e18);
        eve.mint(address(diamond), 1_000_000e18);
        alt.mint(address(diamond), 1_000_000e18);

        vm.prank(alice);
        indexToken.approve(address(diamond), type(uint256).max);

        vm.deal(alice, 10 ether);
    }

    function test_MintWithPermit_ExecutesPermitsThenMints() public {
        IEdenBatchFacet.PermitData[] memory permits = new IEdenBatchFacet.PermitData[](2);
        permits[0] = _permitData(eve, ALICE_PK, alice, address(diamond), 100e18, block.timestamp + 1 days);
        permits[1] = _permitData(alt, ALICE_PK, alice, address(diamond), 50e18, block.timestamp + 1 days);

        vm.prank(alice);
        uint256 minted = IEdenBatchFacet(address(diamond)).mintWithPermit(1, UNIT, alice, permits);

        assertEq(minted, UNIT);
        assertEq(indexToken.balanceOf(alice), UNIT);
        assertEq(BatchPermitHarnessFacet(address(diamond)).getVaultBalance(1, address(eve)), 300e18);
        assertEq(BatchPermitHarnessFacet(address(diamond)).getVaultBalance(1, address(alt)), 150e18);
        assertEq(eve.allowance(alice, address(diamond)), 0);
        assertEq(alt.allowance(alice, address(diamond)), 0);
    }

    function test_RepayWithPermit_ExecutesPermitsThenRepays() public {
        BatchPermitHarnessFacet(address(diamond)).mintReceiptUnits(1, alice, 2 * UNIT);

        vm.prank(alice);
        uint256 loanId = IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 2 days);

        IEdenBatchFacet.PermitData[] memory permits = new IEdenBatchFacet.PermitData[](2);
        permits[0] = _permitData(eve, ALICE_PK, alice, address(diamond), 100e18, block.timestamp + 1 days);
        permits[1] = _permitData(alt, ALICE_PK, alice, address(diamond), 50e18, block.timestamp + 1 days);

        vm.prank(alice);
        IEdenBatchFacet(address(diamond)).repayWithPermit(loanId, permits);

        assertTrue(BatchPermitHarnessFacet(address(diamond)).getLoanClosed(loanId));
        assertEq(indexToken.balanceOf(alice), 2 * UNIT);
        assertEq(eve.allowance(alice, address(diamond)), 0);
        assertEq(alt.allowance(alice, address(diamond)), 0);
    }

    function test_FundRewardsWithPermit_ExecutesPermitThenFunds() public {
        IEdenBatchFacet.PermitData memory permit =
            _permitData(eve, OWNER_PK, owner, address(diamond), 250e18, block.timestamp + 1 days);

        vm.prank(owner);
        IEdenBatchFacet(address(diamond)).fundRewardsWithPermit(250e18, permit);

        assertEq(BatchPermitHarnessFacet(address(diamond)).getRewardReserve(), 250e18);
        assertEq(eve.allowance(owner, address(diamond)), 0);
    }

    function test_PermitFlows_InvalidSignatureReverts() public {
        IEdenBatchFacet.PermitData[] memory permits = new IEdenBatchFacet.PermitData[](2);
        permits[0] = _permitData(eve, BOB_PK, alice, address(diamond), 100e18, block.timestamp + 1 days);
        permits[1] = _permitData(alt, ALICE_PK, alice, address(diamond), 50e18, block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert();
        IEdenBatchFacet(address(diamond)).mintWithPermit(1, UNIT, alice, permits);
    }

    function test_PermitFlows_EnforceOwnerAndSpenderConstraints() public {
        IEdenBatchFacet.PermitData[] memory badOwnerPermits = new IEdenBatchFacet.PermitData[](1);
        badOwnerPermits[0] = _permitData(eve, ALICE_PK, bob, address(diamond), 100e18, block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(EdenBatchFacet.InvalidPermitOwner.selector, bob, alice)
        );
        IEdenBatchFacet(address(diamond)).mintWithPermit(1, UNIT, alice, badOwnerPermits);

        IEdenBatchFacet.PermitData[] memory badSpenderPermits = new IEdenBatchFacet.PermitData[](1);
        badSpenderPermits[0] = _permitData(eve, ALICE_PK, alice, bob, 100e18, block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(EdenBatchFacet.InvalidPermitSpender.selector, bob, address(diamond))
        );
        IEdenBatchFacet(address(diamond)).mintWithPermit(1, UNIT, alice, badSpenderPermits);
    }

    function test_ReentrancyGuard_MintWithPermit_BlocksNestedBatchCall() public {
        IEdenBatchFacet.PermitData[] memory permits = new IEdenBatchFacet.PermitData[](2);
        permits[0] = _permitData(eve, ALICE_PK, alice, address(diamond), 100e18, block.timestamp + 1 days);
        permits[1] = _permitData(alt, ALICE_PK, alice, address(diamond), 50e18, block.timestamp + 1 days);

        IEdenBatchFacet.PermitData[] memory emptyPermits = new IEdenBatchFacet.PermitData[](0);
        eve.configureCallback(
            address(diamond),
            abi.encodeCall(IEdenBatchFacet.mintWithPermit, (1, UNIT, alice, emptyPermits)),
            false,
            true
        );

        vm.prank(alice);
        uint256 minted = IEdenBatchFacet(address(diamond)).mintWithPermit(1, UNIT, alice, permits);

        assertEq(minted, UNIT);
        assertTrue(eve.callbackAttempted());
        assertFalse(eve.callbackSucceeded());
    }

    function test_ReentrancyGuard_RepayWithPermit_BlocksNestedBatchCall() public {
        BatchPermitHarnessFacet(address(diamond)).mintReceiptUnits(1, alice, 2 * UNIT);

        vm.prank(alice);
        uint256 loanId = IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 2 days);

        IEdenBatchFacet.PermitData[] memory permits = new IEdenBatchFacet.PermitData[](2);
        permits[0] = _permitData(eve, ALICE_PK, alice, address(diamond), 100e18, block.timestamp + 1 days);
        permits[1] = _permitData(alt, ALICE_PK, alice, address(diamond), 50e18, block.timestamp + 1 days);

        IEdenBatchFacet.PermitData[] memory emptyPermits = new IEdenBatchFacet.PermitData[](0);
        eve.configureCallback(
            address(diamond),
            abi.encodeCall(IEdenBatchFacet.repayWithPermit, (loanId, emptyPermits)),
            false,
            true
        );

        vm.prank(alice);
        IEdenBatchFacet(address(diamond)).repayWithPermit(loanId, permits);

        assertTrue(BatchPermitHarnessFacet(address(diamond)).getLoanClosed(loanId));
        assertTrue(eve.callbackAttempted());
        assertFalse(eve.callbackSucceeded());
    }

    function test_ReentrancyGuard_FundRewardsWithPermit_BlocksNestedBatchCall() public {
        IEdenBatchFacet.PermitData memory permit =
            _permitData(eve, OWNER_PK, owner, address(diamond), 250e18, block.timestamp + 1 days);

        IEdenBatchFacet.PermitData[] memory emptyPermits = new IEdenBatchFacet.PermitData[](0);
        eve.configureCallback(
            address(diamond),
            abi.encodeCall(IEdenBatchFacet.mintWithPermit, (1, UNIT, owner, emptyPermits)),
            false,
            true
        );

        vm.prank(owner);
        IEdenBatchFacet(address(diamond)).fundRewardsWithPermit(250e18, permit);

        assertEq(BatchPermitHarnessFacet(address(diamond)).getRewardReserve(), 250e18);
        assertTrue(eve.callbackAttempted());
        assertFalse(eve.callbackSucceeded());
    }

    function _setUpBaskets() internal {
        address[] memory steveAssets = new address[](1);
        steveAssets[0] = address(eve);
        uint256[] memory steveBundle = new uint256[](1);
        steveBundle[0] = 1000e18;
        uint16[] memory steveFees = new uint16[](1);
        steveFees[0] = 0;
        BatchPermitHarnessFacet(address(diamond))
            .setBasket(0, address(stEveToken), steveAssets, steveBundle, steveFees, true);

        address[] memory assets = new address[](2);
        assets[0] = address(eve);
        assets[1] = address(alt);
        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 100e18;
        bundleAmounts[1] = 50e18;
        uint16[] memory fees = new uint16[](2);
        fees[0] = 0;
        fees[1] = 0;
        BatchPermitHarnessFacet(address(diamond))
            .setBasket(1, address(indexToken), assets, bundleAmounts, fees, false);
    }

    function _setUpLending() internal {
        vm.startPrank(owner);
        IEdenLendingFacet(address(diamond)).configureLending(1, 1 days, 10 days);

        uint256[] memory mins = new uint256[](2);
        mins[0] = UNIT;
        mins[1] = 2 * UNIT;
        uint256[] memory fees = new uint256[](2);
        fees[0] = 0.2 ether;
        fees[1] = 0.02 ether;
        IEdenLendingFacet(address(diamond)).configureBorrowFeeTiers(1, mins, fees);
        vm.stopPrank();
    }

    function _permitData(
        PermitToken token,
        uint256 signerPrivateKey,
        address owner_,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (IEdenBatchFacet.PermitData memory permit) {
        uint256 nonce = token.nonces(owner_);
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(token.DOMAIN_SEPARATOR(), signerPrivateKey, owner_, spender, value, nonce, deadline);
        permit = IEdenBatchFacet.PermitData({
            token: address(token),
            owner: owner_,
            spender: spender,
            value: value,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });
    }

    function _signPermit(
        bytes32 domainSeparator,
        uint256 signerPrivateKey,
        address owner_,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        return vm.sign(signerPrivateKey, digest);
    }

    function _facetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](1);

        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = IEdenBatchFacet.mintWithPermit.selector;
        selectors[1] = IEdenBatchFacet.repayWithPermit.selector;
        selectors[2] = IEdenBatchFacet.fundRewardsWithPermit.selector;
        selectors[3] = IEdenLendingFacet.borrow.selector;
        selectors[4] = IEdenLendingFacet.configureLending.selector;
        selectors[5] = IEdenLendingFacet.configureBorrowFeeTiers.selector;
        selectors[6] = IEdenBatchFacet.multicall.selector;
        selectors[7] = BatchPermitHarnessFacet.onBasketTokenTransfer.selector;
        selectors[8] = BatchPermitHarnessFacet.setCoreConfig.selector;
        selectors[9] = BatchPermitHarnessFacet.setBasket.selector;
        selectors[10] = BatchPermitHarnessFacet.setRewardReserve.selector;
        selectors[11] = BatchPermitHarnessFacet.mintReceiptUnits.selector;
        selectors[12] = BatchPermitHarnessFacet.setVaultBalance.selector;
        selectors[13] = BatchPermitHarnessFacet.getVaultBalance.selector;
        selectors[14] = BatchPermitHarnessFacet.getRewardReserve.selector;
        selectors[15] = BatchPermitHarnessFacet.getLoanClosed.selector;

        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(batchFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
    }
}
