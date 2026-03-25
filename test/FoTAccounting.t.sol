// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { Test } from "forge-std/Test.sol";
import { EdenDiamond } from "src/EdenDiamond.sol";
import { EdenCoreFacet } from "src/facets/EdenCoreFacet.sol";
import { EdenAdminFacet } from "src/facets/EdenAdminFacet.sol";
import { EdenBatchFacet } from "src/facets/EdenBatchFacet.sol";
import { IDiamondCut } from "src/interfaces/IDiamondCut.sol";
import { IEdenAdminFacet } from "src/interfaces/IEdenAdminFacet.sol";
import { IEdenBatchFacet } from "src/interfaces/IEdenBatchFacet.sol";
import { IEdenCoreFacet } from "src/interfaces/IEdenCoreFacet.sol";
import { IEdenLendingFacet } from "src/interfaces/IEdenLendingFacet.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";
import { LibLendingStorage } from "src/libraries/LibLendingStorage.sol";
import { LibStEVEStorage } from "src/libraries/LibStEVEStorage.sol";
import { LibTokenDelta } from "src/libraries/LibTokenDelta.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";

contract FeeOnTransferPermitToken is ERC20, ERC20Permit {
    uint256 public immutable feeBps;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 feeBps_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, _msgSender(), value);

        uint256 fee = (value * feeBps) / 10_000;
        uint256 received = value - fee;
        _transfer(from, to, received);
        if (fee > 0) {
            _burn(from, fee);
        }
        return true;
    }
}

contract PlainToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FoTHarnessBatchFacet is EdenBatchFacet {
    function setVaultBalance(
        uint256 basketId,
        address asset,
        uint256 amount
    ) external {
        LibEdenStorage.layout().vaultBalances[basketId][asset] = amount;
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

    function getVaultBalance(
        uint256 basketId,
        address asset
    ) external view returns (uint256) {
        return LibEdenStorage.layout().vaultBalances[basketId][asset];
    }

    function getRewardReserve() external view returns (uint256) {
        return LibStEVEStorage.layout().rewardReserve;
    }

    function getOutstandingPrincipal(
        uint256 basketId,
        address asset
    ) external view returns (uint256) {
        return LibLendingStorage.layout().outstandingPrincipal[basketId][asset];
    }

    function getLoanClosed(
        uint256 loanId
    ) external view returns (bool) {
        return LibLendingStorage.layout().loanClosed[loanId];
    }
}

contract FoTAccountingTest is Test {
    bytes32 internal constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );
    uint256 internal constant OWNER_PK = 0xA11;
    uint256 internal constant UNIT = 1e18;

    address internal owner;
    address internal timelock = makeAddr("timelock");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    EdenDiamond internal diamond;
    EdenCoreFacet internal coreFacet;
    EdenAdminFacet internal adminFacet;
    FoTHarnessBatchFacet internal batchFacet;
    FeeOnTransferPermitToken internal feeToken;
    PlainToken internal altToken;
    BasketToken internal basketOneToken;

    function setUp() public {
        owner = vm.addr(OWNER_PK);

        diamond = new EdenDiamond(owner, timelock);
        coreFacet = new EdenCoreFacet();
        adminFacet = new EdenAdminFacet();
        batchFacet = new FoTHarnessBatchFacet();
        feeToken = new FeeOnTransferPermitToken("FoT", "FOT", 1000);
        altToken = new PlainToken("ALT", "ALT");

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(_facetCuts(), address(0), "");

        vm.startPrank(owner);
        IEdenAdminFacet(address(diamond)).setTreasury(treasury);
        _createBaskets();
        IEdenLendingFacet(address(diamond)).configureLending(1, 1 days, 10 days);
        IEdenLendingFacet(address(diamond))
            .configureBorrowFeeTiers(1, _u256Array(UNIT), _u256Array(0.2 ether));
        vm.stopPrank();

        feeToken.mint(owner, 1_000_000e18);
        feeToken.mint(alice, 1_000_000e18);
        altToken.mint(alice, 1_000_000e18);

        vm.startPrank(alice);
        feeToken.approve(address(diamond), type(uint256).max);
        altToken.approve(address(diamond), type(uint256).max);
        vm.stopPrank();

        vm.deal(alice, 10 ether);
    }

    function test_FoTAccounting_CoreMint_RevertsOnShortObservedDelta() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibTokenDelta.InsufficientTokenDelta.selector, address(feeToken), 100e18, 90e18
            )
        );
        IEdenCoreFacet(address(diamond)).mint(1, UNIT, alice);

        assertEq(basketOneToken.balanceOf(alice), 0);
        assertEq(FoTHarnessBatchFacet(address(diamond)).getVaultBalance(1, address(feeToken)), 0);
        assertEq(FoTHarnessBatchFacet(address(diamond)).getVaultBalance(1, address(altToken)), 0);
    }

    function test_FoTAccounting_Repay_RevertsOnShortObservedDelta() public {
        FoTHarnessBatchFacet(address(diamond)).setVaultBalance(1, address(feeToken), 200e18);
        FoTHarnessBatchFacet(address(diamond)).setVaultBalance(1, address(altToken), 100e18);
        feeToken.mint(address(diamond), 200e18);
        altToken.mint(address(diamond), 100e18);
        FoTHarnessBatchFacet(address(diamond)).mintReceiptUnits(1, alice, 2 * UNIT);

        vm.prank(alice);
        basketOneToken.approve(address(diamond), type(uint256).max);

        vm.prank(alice);
        uint256 loanId = IEdenLendingFacet(address(diamond)).borrow{ value: 0.2 ether }(1, UNIT, 2 days);

        assertEq(
            FoTHarnessBatchFacet(address(diamond)).getOutstandingPrincipal(1, address(feeToken)),
            100e18
        );

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibTokenDelta.InsufficientTokenDelta.selector, address(feeToken), 100e18, 90e18
            )
        );
        IEdenLendingFacet(address(diamond)).repay(loanId);

        assertFalse(FoTHarnessBatchFacet(address(diamond)).getLoanClosed(loanId));
        assertEq(
            FoTHarnessBatchFacet(address(diamond)).getOutstandingPrincipal(1, address(feeToken)),
            100e18
        );
    }

    function test_FoTAccounting_FundRewards_RevertsOnShortObservedDelta() public {
        vm.startPrank(owner);
        feeToken.approve(address(diamond), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibTokenDelta.InsufficientTokenDelta.selector, address(feeToken), 100e18, 90e18
            )
        );
        IEdenStEVEFacet(address(diamond)).fundRewards(100e18);
        vm.stopPrank();

        assertEq(FoTHarnessBatchFacet(address(diamond)).getRewardReserve(), 0);
    }

    function test_FoTAccounting_BatchFundRewardsWithPermit_RevertsOnShortObservedDelta() public {
        IEdenBatchFacet.PermitData memory permit =
            _permitData(feeToken, OWNER_PK, owner, address(diamond), 100e18, block.timestamp + 1 days);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibTokenDelta.InsufficientTokenDelta.selector, address(feeToken), 100e18, 90e18
            )
        );
        IEdenBatchFacet(address(diamond)).fundRewardsWithPermit(100e18, permit);

        assertEq(FoTHarnessBatchFacet(address(diamond)).getRewardReserve(), 0);
    }

    function _createBaskets() internal {
        IEdenCoreFacet.CreateBasketParams memory stEveParams = IEdenCoreFacet.CreateBasketParams({
            name: "Staked FoT",
            symbol: "stFOT",
            assets: _addressArray(address(feeToken)),
            bundleAmounts: _u256Array(1000e18),
            mintFeeBps: _u16Array(0),
            burnFeeBps: _u16Array(0),
            flashFeeBps: 0
        });
        IEdenCoreFacet(address(diamond)).createBasket(stEveParams);

        address[] memory assets = new address[](2);
        assets[0] = address(feeToken);
        assets[1] = address(altToken);

        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 100e18;
        bundleAmounts[1] = 50e18;

        uint16[] memory zeroFees = new uint16[](2);

        IEdenCoreFacet.CreateBasketParams memory basketParams = IEdenCoreFacet.CreateBasketParams({
            name: "FoT Basket",
            symbol: "FBASK",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeBps: zeroFees,
            burnFeeBps: zeroFees,
            flashFeeBps: 0
        });

        (, address basketTokenAddress) = IEdenCoreFacet(address(diamond)).createBasket(basketParams);
        basketOneToken = BasketToken(basketTokenAddress);
    }

    function _permitData(
        FeeOnTransferPermitToken token,
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
        cuts = new IDiamondCut.FacetCut[](3);

        bytes4[] memory coreSelectors = new bytes4[](4);
        coreSelectors[0] = IEdenCoreFacet.createBasket.selector;
        coreSelectors[1] = IEdenCoreFacet.mint.selector;
        coreSelectors[2] = IEdenCoreFacet.burn.selector;
        coreSelectors[3] = IEdenCoreFacet.onBasketTokenTransfer.selector;

        bytes4[] memory adminSelectors = new bytes4[](5);
        adminSelectors[0] = IEdenAdminFacet.completeBootstrap.selector;
        adminSelectors[1] = IEdenAdminFacet.setTreasury.selector;
        adminSelectors[2] = IEdenAdminFacet.setTreasuryFeeBps.selector;
        adminSelectors[3] = IEdenAdminFacet.setFeePotShareBps.selector;
        adminSelectors[4] = IEdenAdminFacet.setProtocolFeeSplitBps.selector;

        bytes4[] memory batchSelectors = new bytes4[](14);
        batchSelectors[0] = IEdenLendingFacet.borrow.selector;
        batchSelectors[1] = IEdenLendingFacet.repay.selector;
        batchSelectors[2] = IEdenLendingFacet.configureLending.selector;
        batchSelectors[3] = IEdenLendingFacet.configureBorrowFeeTiers.selector;
        batchSelectors[4] = IEdenStEVEFacet.fundRewards.selector;
        batchSelectors[5] = IEdenBatchFacet.fundRewardsWithPermit.selector;
        batchSelectors[6] = IEdenStEVEFacet.onStEVETransfer.selector;
        batchSelectors[7] = FoTHarnessBatchFacet.setVaultBalance.selector;
        batchSelectors[8] = FoTHarnessBatchFacet.mintReceiptUnits.selector;
        batchSelectors[9] = FoTHarnessBatchFacet.getVaultBalance.selector;
        batchSelectors[10] = FoTHarnessBatchFacet.getRewardReserve.selector;
        batchSelectors[11] = FoTHarnessBatchFacet.getOutstandingPrincipal.selector;
        batchSelectors[12] = FoTHarnessBatchFacet.getLoanClosed.selector;
        batchSelectors[13] = IEdenBatchFacet.multicall.selector;

        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(coreFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: coreSelectors
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(adminFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: adminSelectors
        });
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(batchFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: batchSelectors
        });
    }

    function _u16Array(uint16 a) internal pure returns (uint16[] memory arr) {
        arr = new uint16[](1);
        arr[0] = a;
    }

    function _u256Array(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _addressArray(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}
