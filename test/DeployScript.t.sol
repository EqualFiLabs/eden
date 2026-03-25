// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";
import { DeployEden } from "script/DeployEden.s.sol";
import { IDiamondLoupe } from "src/interfaces/IDiamondLoupe.sol";
import { IEdenStEVEFacet } from "src/interfaces/IEdenStEVEFacet.sol";
import { IEdenViewFacet } from "src/interfaces/IEdenViewFacet.sol";
import { LibEdenStorage } from "src/libraries/LibEdenStorage.sol";

contract ScriptMockERC20 is ERC20 {
    constructor() ERC20("EVE", "EVE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployScriptTest is Test {
    function test_DeployScript_WiresDiamondAndInitializesSteve() public {
        DeployEden deployer = new DeployEden();
        ScriptMockERC20 eve = new ScriptMockERC20();

        uint256 privateKey = 0xA11CE;
        address broadcaster = vm.addr(privateKey);
        eve.mint(broadcaster, 2_000_000_000e18);

        vm.setEnv("PRIVATE_KEY", vm.toString(privateKey));
        vm.setEnv("EDEN_OWNER", vm.toString(broadcaster));
        vm.setEnv("EDEN_TIMELOCK", vm.toString(broadcaster));
        vm.setEnv("EDEN_TREASURY", vm.toString(broadcaster));
        vm.setEnv("EDEN_EVE_TOKEN", vm.toString(address(eve)));
        vm.setEnv("EDEN_GENESIS_TIMESTAMP", vm.toString(block.timestamp));

        DeployEden.Deployment memory deployment = deployer.run();

        assertEq(IDiamondLoupe(address(deployment.diamond)).facetAddresses().length, 7);
        assertEq(IEdenStEVEFacet(address(deployment.diamond)).rewardReserveBalance(), 2_000_000_000e18);
        assertEq(IEdenStEVEFacet(address(deployment.diamond)).currentEpoch(), 0);

        LibEdenStorage.Basket memory basket = IEdenViewFacet(address(deployment.diamond)).getBasket(0);

        assertEq(basket.assets.length, 1);
        assertEq(basket.assets[0], address(eve));
        assertEq(basket.bundleAmounts[0], 1000e18);
        assertTrue(basket.token != address(0));
    }
}
