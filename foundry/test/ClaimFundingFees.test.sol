// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import "./lib/TestHelper.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IDataStore} from "../src/interfaces/IDataStore.sol";
import {IRoleStore} from "../src/interfaces/IRoleStore.sol";
import {Keys} from "../src/lib/Keys.sol";
import {Role} from "../src/lib/Role.sol";
import "../src/Constants.sol";
import {ClaimFundingFees} from "@exercises/ClaimFundingFees.sol";

contract ClaimFundingFeesTest is Test {
    IERC20 constant weth = IERC20(WETH);
    IERC20 constant usdc = IERC20(USDC);
    IDataStore constant dataStore = IDataStore(DATA_STORE);

    TestHelper testHelper;
    ClaimFundingFees claimFundingFees;

    function setUp() public {
        testHelper = new TestHelper();
        claimFundingFees = new ClaimFundingFees();

        // Grant necessary roles
        address admin = testHelper.getRoleMember(Role.ROLE_ADMIN);
        IRoleStore roleStore = IRoleStore(ROLE_STORE);
        
        vm.prank(admin);
        roleStore.grantRole(EXCHANGE_ROUTER, Role.CONTROLLER);

        vm.prank(EXCHANGE_ROUTER);
        dataStore.incrementUint(
            Keys.claimableFundingAmountKey(
                GM_TOKEN_ETH_WETH_USDC, USDC, address(claimFundingFees)
            ),
            1e6
        );

        vm.prank(EXCHANGE_ROUTER);
        dataStore.incrementUint(
            Keys.claimableFundingAmountKey(
                GM_TOKEN_ETH_WETH_USDC, WETH, address(claimFundingFees)
            ),
            2e18
        );
    }

    function testClaimFundingFees() public {
        uint256 usdcFundingFees =
            claimFundingFees.getClaimableAmount(GM_TOKEN_ETH_WETH_USDC, USDC);
        uint256 wethFundingFees =
            claimFundingFees.getClaimableAmount(GM_TOKEN_ETH_WETH_USDC, WETH);

        console.log("USDC %e", usdcFundingFees);
        console.log("WETH %e", wethFundingFees);

        assertGe(usdcFundingFees, 1e6, "USDC claimable funding fee");
        assertGe(wethFundingFees, 2e18, "WETH claimable funding fee");

        claimFundingFees.claimFundingFees();

        testHelper.set("USDC", usdc.balanceOf(address(claimFundingFees)));
        testHelper.set("WETH", weth.balanceOf(address(claimFundingFees)));

        console.log("USDC %e", testHelper.get("USDC"));
        console.log("WETH %e", testHelper.get("WETH"));

        assertGe(testHelper.get("USDC"), 1e6, "USDC");
        assertGe(testHelper.get("WETH"), 2e18, "WETH");
    }
}
