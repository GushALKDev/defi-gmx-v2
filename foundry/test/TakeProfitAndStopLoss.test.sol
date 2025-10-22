// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import "./lib/TestHelper.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IReader} from "../src/interfaces/IReader.sol";
import {IRoleStore} from "../src/interfaces/IRoleStore.sol";
import {IOrderHandler} from "../src/interfaces/IOrderHandler.sol";
import {OracleUtils} from "../src/types/OracleUtils.sol";
import {Order} from "../src/types/Order.sol";
import {Position} from "../src/types/Position.sol";
import "../src/Constants.sol";
import {Role} from "../src/lib/Role.sol";
import {Oracle} from "../src/lib/Oracle.sol";
import {TakeProfitAndStopLoss} from "@exercises/TakeProfitAndStopLoss.sol";

contract TakeProfitAndStopLossTest is Test {
    IERC20 constant weth = IERC20(WETH);
    IERC20 constant usdc = IERC20(USDC);
    IOrderHandler constant orderHandler = IOrderHandler(ORDER_HANDLER);
    IReader constant reader = IReader(READER);

    TestHelper testHelper;
    Oracle oracle;
    TakeProfitAndStopLoss tpsl;
    address keeper;

    // Oracle params
    address[] tokens;
    address[] providers;
    bytes[] data;
    TestHelper.OracleParams[] oracles;

    function setUp() public {
        testHelper = new TestHelper();
        keeper = testHelper.getRoleMember(Role.ORDER_KEEPER);
        oracle = new Oracle();
        tpsl = new TakeProfitAndStopLoss(address(oracle));
        deal(USDC, address(this), 1000 * 1e6);

        // Grant necessary roles
        address admin = testHelper.getRoleMember(Role.ROLE_ADMIN);
        IRoleStore roleStore = IRoleStore(ROLE_STORE);
        
        vm.startPrank(admin);
        roleStore.grantRole(EXCHANGE_ROUTER, Role.ROUTER_PLUGIN);
        roleStore.grantRole(EXCHANGE_ROUTER, Role.CONTROLLER);
        roleStore.grantRole(ORDER_HANDLER, Role.CONTROLLER);
        vm.stopPrank();

        tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = WETH;

        providers = new address[](2);
        providers[0] = CHAINLINK_DATA_STREAM_PROVIDER;
        providers[1] = CHAINLINK_DATA_STREAM_PROVIDER;

        // NOTE: data kept empty for mock calls
        data = new bytes[](2);

        oracles = new TestHelper.OracleParams[](2);
        oracles[0] = TestHelper.OracleParams({
            chainlink: CHAINLINK_USDC_USD,
            multiplier: 1,
            deltaPrice: 0
        });
        oracles[1] = TestHelper.OracleParams({
            chainlink: CHAINLINK_ETH_USD,
            multiplier: 1,
            deltaPrice: 0
        });
    }

    function createLongOrder(uint256 usdcAmount)
        public
        returns (bytes32[] memory keys)
    {
        uint256 executionFee = 1e18;
        uint256 leverage = 5;
        usdc.approve(address(tpsl), usdcAmount);

        keys = tpsl.createTakeProfitAndStopLossOrders{value: executionFee}(
            leverage, usdcAmount
        );

        assertEq(keys.length, 3, "keys length");

        Order.Props memory order = reader.getOrder(DATA_STORE, keys[0]);
        assertEq(order.addresses.receiver, address(tpsl), "order receiver");
        assertEq(
            uint256(order.numbers.orderType),
            uint256(Order.OrderType.MarketIncrease),
            "order type"
        );
        assertEq(order.flags.isLong, true, "not long");

        // Execute create long position
        skip(1);

        testHelper.mockOraclePrices({
            tokens: tokens,
            providers: providers,
            data: data,
            oracles: oracles
        });

        vm.prank(keeper);
        orderHandler.executeOrder(
            keys[0],
            OracleUtils.SetPricesParams({
                tokens: tokens,
                providers: providers,
                data: data
            })
        );

        bytes32 positionKey = Position.getPositionKey({
            account: address(tpsl),
            market: GM_TOKEN_ETH_WETH_USDC,
            collateralToken: USDC,
            isLong: true
        });

        Position.Props memory position;
        position = reader.getPosition(DATA_STORE, positionKey);

        assertEq(position.addresses.account, address(tpsl), "position account");
        assertEq(
            position.addresses.market, GM_TOKEN_ETH_WETH_USDC, "position market"
        );
        assertGe(
            position.numbers.collateralAmount,
            usdcAmount * 99 / 100,
            "position collateral amount"
        );
        assertGt(position.numbers.sizeInUsd, 0, "position size USD");
    }

    function testStopLoss() public {
        uint256 usdcAmount = 1000 * 1e6;
        bytes32[] memory keys = createLongOrder(usdcAmount);

        // Execute stop loss
        skip(1);

        oracles[0].deltaPrice = 0;
        oracles[1].deltaPrice = -11;

        testHelper.mockOraclePrices({
            tokens: tokens,
            providers: providers,
            data: data,
            oracles: oracles
        });

        testHelper.set("USDC before", usdc.balanceOf(address(tpsl)));

        vm.prank(keeper);
        orderHandler.executeOrder(
            keys[1],
            OracleUtils.SetPricesParams({
                tokens: tokens,
                providers: providers,
                data: data
            })
        );

        testHelper.set("USDC after", usdc.balanceOf(address(tpsl)));
        assertGt(
            testHelper.get("USDC after"), testHelper.get("USDC before"), "USDC"
        );
    }

    function testTakeProfit() public {
        uint256 usdcAmount = 1000 * 1e6;
        bytes32[] memory keys = createLongOrder(usdcAmount);

        // Execute take profit
        skip(1);

        oracles[0].deltaPrice = 0;
        oracles[1].deltaPrice = 11;

        testHelper.mockOraclePrices({
            tokens: tokens,
            providers: providers,
            data: data,
            oracles: oracles
        });

        testHelper.set("USDC before", usdc.balanceOf(address(tpsl)));
        testHelper.set("WETH before", weth.balanceOf(address(tpsl)));
        console.log("USDC before:", testHelper.get("USDC before"));
        console.log("WETH before:", testHelper.get("WETH before"));

        vm.prank(keeper);
        orderHandler.executeOrder(
            keys[2],
            OracleUtils.SetPricesParams({
                tokens: tokens,
                providers: providers,
                data: data
            })
        );

        testHelper.set("USDC after", usdc.balanceOf(address(tpsl)));
        testHelper.set("WETH after", weth.balanceOf(address(tpsl)));
        console.log("USDC after:", testHelper.get("USDC after"));
        console.log("WETH after:", testHelper.get("WETH after"));
        
        // Check that we received funds back
        assertGt(
            testHelper.get("USDC after"), testHelper.get("USDC before"), "USDC"
        );

        // The PnL should have been swapped to USDC, so we should have profit in USDC
        // But if SwapPnlTokenToCollateralToken didn't work, we might have WETH instead
        uint256 wethReceived = testHelper.get("WETH after") - testHelper.get("WETH before");
        
        // Log for debugging
        console.log("USDC received:", testHelper.get("USDC after"));
        console.log("WETH received:", wethReceived);

        assertGt(testHelper.get("USDC after"), usdcAmount, "no profit");
    }
}
