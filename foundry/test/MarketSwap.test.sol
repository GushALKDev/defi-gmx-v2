// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import "./lib/TestHelper.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IOrderHandler} from "../src/interfaces/IOrderHandler.sol";
import {IReader} from "../src/interfaces/IReader.sol";
import {IRoleStore} from "../src/interfaces/IRoleStore.sol";
import {OracleUtils} from "../src/types/OracleUtils.sol";
import {Order} from "../src/types/Order.sol";
import "../src/Constants.sol";
import {Role} from "../src/lib/Role.sol";
import {MarketSwap} from "@exercises/MarketSwap.sol";

contract MarketSwapTest is Test {
    IERC20 constant weth = IERC20(WETH);
    IERC20 constant dai = IERC20(DAI);
    IOrderHandler constant orderHandler = IOrderHandler(ORDER_HANDLER);
    IReader constant reader = IReader(READER);

    TestHelper testHelper;
    MarketSwap swap;
    address keeper;

    // Oracle params
    address[] tokens;
    address[] providers;
    bytes[] data;
    TestHelper.OracleParams[] oracles;

    function setUp() public {
        testHelper = new TestHelper();
        keeper = testHelper.getRoleMember(Role.ORDER_KEEPER);

        swap = new MarketSwap();
        
        // Grant necessary roles
        address admin = testHelper.getRoleMember(Role.ROLE_ADMIN);
        IRoleStore roleStore = IRoleStore(ROLE_STORE);
        
        vm.startPrank(admin);
        roleStore.grantRole(EXCHANGE_ROUTER, Role.ROUTER_PLUGIN);
        roleStore.grantRole(EXCHANGE_ROUTER, Role.CONTROLLER);
        roleStore.grantRole(ORDER_HANDLER, Role.CONTROLLER);
        vm.stopPrank();
        
        deal(WETH, address(this), 1000 * 1e18);

        tokens = new address[](3);
        tokens[0] = DAI;
        tokens[1] = WETH;
        tokens[2] = USDC;

        providers = new address[](3);
        providers[0] = CHAINLINK_DATA_STREAM_PROVIDER;
        providers[1] = CHAINLINK_DATA_STREAM_PROVIDER;
        providers[2] = CHAINLINK_DATA_STREAM_PROVIDER;

        // NOTE: data kept empty for mock calls
        data = new bytes[](3);

        oracles = new TestHelper.OracleParams[](3);
        oracles[0] = TestHelper.OracleParams({
            chainlink: CHAINLINK_DAI_USD,
            multiplier: 1,
            deltaPrice: 0
        });
        oracles[1] = TestHelper.OracleParams({
            chainlink: CHAINLINK_ETH_USD,
            multiplier: 1,
            deltaPrice: 0
        });
        oracles[2] = TestHelper.OracleParams({
            chainlink: CHAINLINK_USDC_USD,
            multiplier: 1,
            deltaPrice: 0
        });
    }

    function testSwap() public {
        uint256 executionFee = 0.1 * 1e18;
        uint256 wethAmount = 1e18;
        weth.approve(address(swap), wethAmount);

        bytes32 key = swap.createOrder{value: executionFee}(wethAmount);

        Order.Props memory order = reader.getOrder(DATA_STORE, key);
        assertEq(order.addresses.receiver, address(swap), "order receiver");
        assertEq(
            uint256(order.numbers.orderType),
            uint256(Order.OrderType.MarketSwap),
            "order type"
        );

        Order.Props memory o = swap.getOrder(key);
        assertEq(o.addresses.receiver, address(swap), "get order receiver");

        // Execute order
        skip(1);

        testHelper.mockOraclePrices({
            tokens: tokens,
            providers: providers,
            data: data,
            oracles: oracles
        });

        testHelper.set("ETH keeper before", keeper.balance);
        testHelper.set("ETH swap before", address(swap).balance);
        testHelper.set("DAI swap before", dai.balanceOf(address(swap)));

        vm.prank(keeper);
        orderHandler.executeOrder(
            key,
            OracleUtils.SetPricesParams({
                tokens: tokens,
                providers: providers,
                data: data
            })
        );

        testHelper.set("ETH keeper after", keeper.balance);
        testHelper.set("ETH swap after", address(swap).balance);
        testHelper.set("DAI swap after", dai.balanceOf(address(swap)));

        console.log("ETH swap: %e", testHelper.get("ETH swap after"));
        console.log("DAI swap: %e", testHelper.get("DAI swap after"));

        assertGe(
            testHelper.get("ETH keeper after"),
            testHelper.get("ETH keeper before"),
            "Keeper execution fee"
        );
        assertGe(
            testHelper.get("ETH swap after"),
            testHelper.get("ETH swap before"),
            "Swap execution fee refund"
        );
        assertGe(
            testHelper.get("DAI swap after"),
            testHelper.get("DAI swap before"),
            "Swap DAI"
        );
    }
}
