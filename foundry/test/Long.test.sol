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
import {Long} from "@exercises/Long.sol";

contract LongTest is Test {
    IERC20 constant weth = IERC20(WETH);
    IERC20 constant usdc = IERC20(USDC);
    IOrderHandler constant orderHandler = IOrderHandler(ORDER_HANDLER);
    IReader constant reader = IReader(READER);

    TestHelper testHelper;
    Oracle oracle;
    Long long;
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
        long = new Long(address(oracle));
        deal(WETH, address(this), 1000 * 1e18);

        // Grant necessary roles
        address admin = testHelper.getRoleMember(Role.ROLE_ADMIN);
        IRoleStore roleStore = IRoleStore(ROLE_STORE);
        
        vm.startPrank(admin);
        roleStore.grantRole(EXCHANGE_ROUTER, Role.ROUTER_PLUGIN);
        roleStore.grantRole(EXCHANGE_ROUTER, Role.CONTROLLER);
        roleStore.grantRole(ORDER_HANDLER, Role.CONTROLLER);
        vm.stopPrank();

        deal(USDC, address(this), 1000 * 1e6);

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

    function testLong() public {
        uint256 ethPrice = oracle.getPrice(CHAINLINK_ETH_USD);
        uint256 executionFee = 1e18;
        uint256 wethAmount = 1e18;
        uint256 leverage = 10;
        weth.approve(address(long), wethAmount);

        bytes32 longOrderKey =
            long.createLongOrder{value: executionFee}(leverage, wethAmount);

        Order.Props memory longOrder = reader.getOrder(DATA_STORE, longOrderKey);
        assertEq(longOrder.addresses.receiver, address(long), "order receiver");
        assertEq(
            uint256(longOrder.numbers.orderType),
            uint256(Order.OrderType.MarketIncrease),
            "order type"
        );
        assertEq(longOrder.flags.isLong, true, "not long");

        // Execute long order
        skip(1);

        testHelper.mockOraclePrices({
            tokens: tokens,
            providers: providers,
            data: data,
            oracles: oracles
        });

        testHelper.set("ETH keeper before", keeper.balance);
        testHelper.set("ETH long before", address(long).balance);

        vm.prank(keeper);
        orderHandler.executeOrder(
            longOrderKey,
            OracleUtils.SetPricesParams({
                tokens: tokens,
                providers: providers,
                data: data
            })
        );

        testHelper.set("ETH keeper after", keeper.balance);
        testHelper.set("ETH long after", address(long).balance);

        assertGe(
            testHelper.get("ETH keeper after"),
            testHelper.get("ETH keeper before"),
            "Keeper execution fee"
        );
        assertGe(
            testHelper.get("ETH long after"),
            testHelper.get("ETH long before"),
            "Long execution fee refund"
        );

        bytes32 positionKey = Position.getPositionKey({
            account: address(long),
            market: GM_TOKEN_ETH_WETH_USDC,
            collateralToken: WETH,
            isLong: true
        });

        assertEq(long.getPositionKey(), positionKey, "position key");

        Position.Props memory position;

        position = reader.getPosition(DATA_STORE, positionKey);
        console.log("pos.sizeInUsd %e", position.numbers.sizeInUsd);
        console.log("pos.sizeInTokens %e", position.numbers.sizeInTokens);
        console.log(
            "pos.collateralAmount %e", position.numbers.collateralAmount
        );

        assertApproxEqRel(
            position.numbers.sizeInUsd,
            leverage * ethPrice * wethAmount * 1e4,
            1e18 * 2 / 100,
            "position size"
        );
        assertGe(
            position.numbers.collateralAmount,
            wethAmount * 99 / 100,
            "position collateral amount"
        );
        assertEq(
            position.addresses.account,
            long.getPosition(positionKey).addresses.account,
            "position"
        );

        // Test position profit and loss
        int256 pnl = long.getPositionPnlUsd(positionKey, ethPrice * 110 / 100);
        console.log("pnl %e", pnl);
        assertGt(pnl, 0, "profit <= 0");

        // Create close order
        skip(1);
        bytes32 closeOrderKey = long.createCloseOrder();

        Order.Props memory closeOrder =
            reader.getOrder(DATA_STORE, closeOrderKey);
        assertEq(closeOrder.addresses.receiver, address(long), "order receiver");
        assertEq(
            uint256(closeOrder.numbers.orderType),
            uint256(Order.OrderType.MarketDecrease),
            "order type"
        );

        // Execute close order
        skip(1);

        // NOTE: acceptablePrice in long must be < oracle price + delta price
        oracles[0].deltaPrice = 0;
        oracles[1].deltaPrice = 5;

        testHelper.mockOraclePrices({
            tokens: tokens,
            providers: providers,
            data: data,
            oracles: oracles
        });

        testHelper.set("ETH keeper before", keeper.balance);
        testHelper.set("ETH long before", address(long).balance);

        vm.prank(keeper);
        orderHandler.executeOrder(
            closeOrderKey,
            OracleUtils.SetPricesParams({
                tokens: tokens,
                providers: providers,
                data: data
            })
        );

        testHelper.set("ETH keeper after", keeper.balance);
        testHelper.set("ETH long after", address(long).balance);
        testHelper.set("WETH long", weth.balanceOf(address(long)));
        testHelper.set("USDC long", usdc.balanceOf(address(long)));

        uint256 wethBal = testHelper.get("WETH long");
        uint256 usdcBal = testHelper.get("USDC long");

        console.log("WETH %e", wethBal);
        console.log("USDC %e", usdcBal);

        assertGe(wethBal, wethAmount, "WETH balance < initial collateral");
        assertEq(usdcBal, 0, "USDC balance != 0");
        assertGe(
            testHelper.get("ETH keeper after"),
            testHelper.get("ETH keeper before"),
            "Keeper execution fee"
        );
        assertGe(
            testHelper.get("ETH long after"),
            testHelper.get("ETH long before"),
            "Close execution fee refund"
        );

        position = reader.getPosition(DATA_STORE, positionKey);
        console.log("pos.sizeInUsd %e", position.numbers.sizeInUsd);
        console.log("pos.sizeInTokens %e", position.numbers.sizeInTokens);
        console.log(
            "pos.collateralAmount %e", position.numbers.collateralAmount
        );

        assertEq(position.numbers.sizeInUsd, 0, "position size != 0");
        assertEq(
            position.numbers.collateralAmount,
            0,
            "position collateral amount != 0"
        );
    }
}
