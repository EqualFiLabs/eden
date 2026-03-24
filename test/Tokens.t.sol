// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Test } from "forge-std/Test.sol";
import { IEdenBasketPositionHook } from "src/interfaces/IEdenBasketPositionHook.sol";
import { IEdenTwabHook } from "src/interfaces/IEdenTwabHook.sol";
import { BasketToken } from "src/tokens/BasketToken.sol";
import { StEVEToken } from "src/tokens/StEVEToken.sol";

contract TokensTest is Test, IEdenBasketPositionHook, IEdenTwabHook {
    bytes32 internal constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );

    uint256 internal constant ALICE_PK = 0xA11CE;
    uint256 internal constant BOB_PK = 0xB0B;

    BasketToken internal basketToken;
    StEVEToken internal stEveToken;

    address internal alice;
    address internal bob;
    address internal carol;

    address internal lastHookFrom;
    address internal lastHookTo;
    uint256 internal lastHookValue;
    uint256 internal hookCallCount;

    function setUp() public {
        alice = vm.addr(ALICE_PK);
        bob = vm.addr(BOB_PK);
        carol = makeAddr("carol");

        basketToken = new BasketToken("Basket Token", "BASK", address(this));
        stEveToken = new StEVEToken("stEVE", "stEVE", address(this));
    }

    function onStEVETransfer(
        address from,
        address to,
        uint256 value
    ) external {
        require(msg.sender == address(stEveToken), "unexpected hook caller");

        lastHookFrom = from;
        lastHookTo = to;
        lastHookValue = value;
        hookCallCount += 1;
    }

    function onBasketTokenTransfer(
        address,
        address,
        uint256
    ) external view {
        require(msg.sender == address(basketToken) || msg.sender == address(stEveToken), "unexpected basket hook caller");
    }

    function test_BasketToken_ERC20Compliance() public {
        basketToken.mintIndexUnits(alice, 100e18);

        assertEq(basketToken.decimals(), 18);
        assertEq(basketToken.totalSupply(), 100e18);
        assertEq(basketToken.balanceOf(alice), 100e18);

        vm.prank(alice);
        assertTrue(basketToken.transfer(bob, 25e18));

        assertEq(basketToken.balanceOf(alice), 75e18);
        assertEq(basketToken.balanceOf(bob), 25e18);

        vm.prank(alice);
        assertTrue(basketToken.approve(bob, 30e18));
        assertEq(basketToken.allowance(alice, bob), 30e18);

        vm.prank(bob);
        assertTrue(basketToken.transferFrom(alice, carol, 20e18));

        assertEq(basketToken.balanceOf(alice), 55e18);
        assertEq(basketToken.balanceOf(carol), 20e18);
        assertEq(basketToken.allowance(alice, bob), 10e18);
    }

    function test_BasketToken_Permit() public {
        uint256 deadline = block.timestamp + 1 days;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            basketToken.DOMAIN_SEPARATOR(),
            ALICE_PK,
            alice,
            bob,
            77e18,
            basketToken.nonces(alice),
            deadline
        );

        basketToken.permit(alice, bob, 77e18, deadline, v, r, s);

        assertEq(basketToken.allowance(alice, bob), 77e18);
        assertEq(basketToken.nonces(alice), 1);
    }

    function test_BasketToken_MinterOnlyMintBurn() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketToken.OnlyMinter.selector, alice));
        basketToken.mintIndexUnits(alice, 1e18);

        basketToken.mintIndexUnits(alice, 5e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketToken.OnlyMinter.selector, alice));
        basketToken.burnIndexUnits(alice, 1e18);

        basketToken.burnIndexUnits(alice, 2e18);
        assertEq(basketToken.balanceOf(alice), 3e18);
    }

    function test_StEVEToken_CapabilitiesAndHook() public {
        stEveToken.mintIndexUnits(alice, 100e18);

        assertEq(stEveToken.decimals(), 18);
        assertEq(stEveToken.totalSupply(), 100e18);
        assertEq(stEveToken.balanceOf(alice), 100e18);
        assertEq(hookCallCount, 1);
        assertEq(lastHookFrom, address(0));
        assertEq(lastHookTo, alice);
        assertEq(lastHookValue, 100e18);
    }

    function test_StEVEToken_Permit() public {
        uint256 deadline = block.timestamp + 1 days;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            stEveToken.DOMAIN_SEPARATOR(),
            ALICE_PK,
            alice,
            bob,
            88e18,
            stEveToken.nonces(alice),
            deadline
        );

        stEveToken.permit(alice, bob, 88e18, deadline, v, r, s);

        assertEq(stEveToken.allowance(alice, bob), 88e18);
        assertEq(stEveToken.nonces(alice), 1);
    }

    function test_StEVEToken_MinterOnlyMintBurn() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketToken.OnlyMinter.selector, alice));
        stEveToken.mintIndexUnits(alice, 1e18);

        stEveToken.mintIndexUnits(alice, 10e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketToken.OnlyMinter.selector, alice));
        stEveToken.burnIndexUnits(alice, 1e18);

        stEveToken.burnIndexUnits(alice, 4e18);
        assertEq(stEveToken.balanceOf(alice), 6e18);
        assertEq(hookCallCount, 2);
        assertEq(lastHookFrom, alice);
        assertEq(lastHookTo, address(0));
        assertEq(lastHookValue, 4e18);
    }

    function test_StEVEToken_DelegationSupportAndVoteTracking() public {
        stEveToken.mintIndexUnits(alice, 100e18);
        assertEq(stEveToken.getVotes(bob), 0);

        vm.prank(alice);
        stEveToken.delegate(bob);

        assertEq(stEveToken.delegates(alice), bob);
        assertEq(stEveToken.getVotes(bob), 100e18);
        assertEq(stEveToken.numCheckpoints(bob), 1);

        vm.roll(block.number + 1);
        uint256 snapshotBlock = block.number - 1;

        vm.prank(alice);
        stEveToken.transfer(carol, 40e18);

        assertEq(stEveToken.getVotes(bob), 60e18);
        assertEq(stEveToken.balanceOf(alice), 60e18);
        assertEq(stEveToken.balanceOf(carol), 40e18);

        vm.roll(block.number + 1);
        assertEq(stEveToken.getPastVotes(bob, snapshotBlock), 100e18);
    }

    function test_StEVEToken_GovernanceTracksTokenBalancesOnly() public {
        stEveToken.mintIndexUnits(alice, 50e18);

        vm.prank(alice);
        stEveToken.delegate(alice);
        assertEq(stEveToken.getVotes(alice), 50e18);

        vm.prank(alice);
        stEveToken.transfer(bob, 15e18);

        assertEq(stEveToken.getVotes(alice), 35e18);
        assertEq(stEveToken.getVotes(bob), 0);
    }

    function test_RevertWhen_StEVETokenTransferExceedsBalance() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1e18)
        );
        stEveToken.transfer(bob, 1e18);
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
}
