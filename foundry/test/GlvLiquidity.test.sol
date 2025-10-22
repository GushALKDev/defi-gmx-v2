// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import "./lib/TestHelper.sol";
import {MarketHelper} from "./lib/MarketHelper.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IGlvHandler} from "../src/interfaces/IGlvHandler.sol";
import {IWithdrawalHandler} from "../src/interfaces/IWithdrawalHandler.sol";
import {IGlvReader} from "../src/interfaces/IGlvReader.sol";
import {IRoleStore} from "../src/interfaces/IRoleStore.sol";
import {OracleUtils} from "../src/types/OracleUtils.sol";
import {GlvDeposit} from "../src/types/GlvDeposit.sol";
import {GlvWithdrawal} from "../src/types/GlvWithdrawal.sol";
import "../src/Constants.sol";
import {Role} from "../src/lib/Role.sol";
import {GlvLiquidity} from "@exercises/GlvLiquidity.sol";

contract GlvLiquidityTest is Test {
    IERC20 constant weth = IERC20(WETH);
    IERC20 constant usdc = IERC20(USDC);
    IERC20 constant glvToken = IERC20(GLV_TOKEN_WETH_USDC);
    IGlvHandler constant glvHandler = IGlvHandler(GLV_HANDLER);
    IWithdrawalHandler constant withdrawalHandler =
        IWithdrawalHandler(WITHDRAWAL_HANDLER);
    IGlvReader constant glvReader = IGlvReader(GLV_READER);

    TestHelper testHelper;
    MarketHelper marketHelper;
    GlvLiquidity glvLiquidity;
    address keeper;

    // Oracle params
    address[] tokens;
    address[] providers;
    bytes[] data;
    TestHelper.OracleParams[] oracles;

    function setUp() public {
        testHelper = new TestHelper();
        marketHelper = new MarketHelper();

        glvLiquidity = new GlvLiquidity();
        deal(USDC, address(this), 1000 * 1e6);

        keeper = testHelper.getRoleMember(Role.ORDER_KEEPER);

        // Grant CONTROLLER and ROUTER_PLUGIN roles to gmLiquidity and routers
        address roleAdmin = testHelper.getRoleMember(Role.ROLE_ADMIN);
        vm.startPrank(roleAdmin);
        IRoleStore(ROLE_STORE).grantRole(GLV_ROUTER, Role.ROUTER_PLUGIN);
        IRoleStore(ROLE_STORE).grantRole(GLV_ROUTER, Role.CONTROLLER);
        IRoleStore(ROLE_STORE).grantRole(GLV_HANDLER, Role.CONTROLLER);
        vm.stopPrank();

        address[] memory markets = new address[](2);
        markets[0] = GM_TOKEN_ETH_WETH_USDC;
        markets[1] = GM_TOKEN_DOGE_WETH_USDC;

        testHelper.mockGlvMarkets(address(glvToken), markets);

        tokens.push(WETH);
        tokens.push(USDC);
        tokens.push(GMX_DOGE_WETH_USDC_INDEX);

        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; i++) {
            providers.push(CHAINLINK_DATA_STREAM_PROVIDER);

            MarketHelper.Info memory info = marketHelper.get(tokens[i]);

            oracles.push(
                TestHelper.OracleParams({
                    chainlink: info.oracle,
                    multiplier: tokens[i].code.length > 0
                        ? 1
                        : (10 ** info.decimals),
                    deltaPrice: 0
                })
            );
        }

        // NOTE: data kept empty for mock calls
        data = new bytes[](n);
    }

    function testGlvLiquidity() public {
        uint256 executionFee = 0.1 * 1e18;
        uint256 usdcAmount = 1000 * 1e6;
        usdc.approve(address(glvLiquidity), usdcAmount);

        uint256 minGlvAmount = 1;

        bytes32 depositKey = glvLiquidity.createGlvDeposit{value: executionFee}(
            usdcAmount, minGlvAmount
        );

        GlvDeposit.Props memory deposit =
            glvReader.getGlvDeposit(DATA_STORE, depositKey);

        assertEq(
            deposit.addresses.receiver,
            address(glvLiquidity),
            "GLV deposit receiver"
        );
        assertEq(
            deposit.addresses.market,
            GM_TOKEN_ETH_WETH_USDC,
            "GLV deposit market"
        );
        assertGt(
            deposit.numbers.initialShortTokenAmount,
            0,
            "GLV deposit initial short token amount"
        );

        // Execute deposit
        skip(1);

        testHelper.mockOraclePrices({
            tokens: tokens,
            providers: providers,
            data: data,
            oracles: oracles
        });

        testHelper.set("GLV before", glvToken.balanceOf(address(glvLiquidity)));

        vm.prank(keeper);
        glvHandler.executeGlvDeposit(
            depositKey,
            OracleUtils.SetPricesParams({
                tokens: tokens,
                providers: providers,
                data: data
            })
        );

        testHelper.set("GLV after", glvToken.balanceOf(address(glvLiquidity)));

        console.log("GLV: %e", testHelper.get("GLV after"));

        assertGt(
            testHelper.get("GLV after"), testHelper.get("GLV before"), "GLV"
        );

        // Create withdrawal order
        skip(1);

        testHelper.set("GLV before", glvToken.balanceOf(address(glvLiquidity)));

        uint256 minWethAmount = 1;
        uint256 minUsdcAmount = 1;

        bytes32 withdrawalKey = glvLiquidity.createGlvWithdrawal{
            value: executionFee
        }(minWethAmount, minUsdcAmount);

        testHelper.set("GLV after", glvToken.balanceOf(address(glvLiquidity)));

        GlvWithdrawal.Props memory withdrawal =
            glvReader.getGlvWithdrawal(DATA_STORE, withdrawalKey);
        assertEq(
            withdrawal.addresses.receiver,
            address(glvLiquidity),
            "withdrawal receiver"
        );
        assertEq(withdrawal.addresses.glv, address(glvToken), "withdrawal glv");
        assertEq(
            withdrawal.addresses.market,
            GM_TOKEN_ETH_WETH_USDC,
            "withdrawal market"
        );
        assertGt(
            withdrawal.numbers.glvTokenAmount, 0, "withdrawal glv token amount"
        );

        assertEq(testHelper.get("GLV after"), 0, "GLV glvLiquidity");

        // Execute withdrawal
        skip(1);

        testHelper.set("WETH before", weth.balanceOf(address(glvLiquidity)));
        testHelper.set("USDC before", usdc.balanceOf(address(glvLiquidity)));

        testHelper.mockOraclePrices({
            tokens: tokens,
            providers: providers,
            data: data,
            oracles: oracles
        });

        vm.prank(keeper);
        glvHandler.executeGlvWithdrawal(
            withdrawalKey,
            OracleUtils.SetPricesParams({
                tokens: tokens,
                providers: providers,
                data: data
            })
        );

        testHelper.set("WETH after", weth.balanceOf(address(glvLiquidity)));
        testHelper.set("USDC after", usdc.balanceOf(address(glvLiquidity)));

        console.log("WETH: %e", testHelper.get("WETH after"));
        console.log("USDC: %e", testHelper.get("USDC after"));

        assertGt(
            testHelper.get("WETH after"),
            testHelper.get("WETH before"),
            "WETH glvLiquidity"
        );
        assertGt(
            testHelper.get("USDC after"),
            testHelper.get("USDC before"),
            "USDC glvLiquidity"
        );
    }
}
