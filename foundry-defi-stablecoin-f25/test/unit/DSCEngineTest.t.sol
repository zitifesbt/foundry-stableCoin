// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { DeployDSC } from "../../script/DeployDSC.s.sol";
import { DSCEngine } from "../../src/DSCEngine.sol";
import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { HelperConfig } from "../../script/HelperConfig.s.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";
import { MockMoreDebtDsc } from "../mocks/MockMoreDebtDsc.sol";
import { MockFailedMintDsc } from "../mocks/MockFailedMintDsc.sol";
import { MockFailedTransferFrom } from "../mocks/MockFailedTransferFrom.sol";
import { MockFailedTransfer } from "../mocks/MockFailedTransfer.sol";
import { Test, console } from "forge-std/Test.sol";

contract DSCEngineTest is Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if
        // redeemFrom != redeemedTo, then it was liquidated

    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;
    MockV3Aggregator mockAggregator;

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 amountToMint = 100 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint8 constant DECIMALS = 8;
    int256 constant INITIAL_PRICE = 2000e8;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    address public USER = makeAddr("user");

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        mockAggregator = new MockV3Aggregator(DECIMALS, INITIAL_PRICE);
        mockAggregator.updateAnswer(2500e8);

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    //////////////////
    // Price Tests //
    //////////////////

    function testGetTokenAmountFromUsd() public view {
        // If we want $100 of WETH @ $2000/WETH, that would be 0.05 WETH
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = dsce.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30_000e18;
        uint256 usdValue = dsce.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    ///////////////////////////////////////
    // depositCollateral Tests //
    ///////////////////////////////////////
    // this test needs it's own setup
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(randToken)));
        dsce.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////
    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // mintDsc Tests //
    ///////////////////////////////////
    // this test needs it's own setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDsc mockDsc = new MockFailedMintDsc();
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(USER);
        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // burnDsc Tests //
    ///////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), amountToMint);
        dsce.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        uint256 userBalanceBeforeRedeem = dsce.getCollateralBalanceOfUser(USER, weth);
        assertEq(userBalanceBeforeRedeem, AMOUNT_COLLATERAL);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalanceAfterRedeem = dsce.getCollateralBalanceOfUser(USER, weth);
        assertEq(userBalanceAfterRedeem, 0);
        vm.stopPrank();
        console.log("amountCollateral: %s", AMOUNT_COLLATERAL);
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(dsce));
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dsce.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Remember, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDsc mockDsc = new MockMoreDebtDsc(ethUsdPriceFeed);
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        mockDsc.approve(address(mockDsce), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        console.log("User health factor: %s", userHealthFactor);
        require(userHealthFactor > 0, "Health factor is zero");
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.liquidate(weth, USER, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint) * dsce.getLiquidationBonus() / dsce.getLiquidationPrecision());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint) * dsce.getLiquidationBonus() / dsce.getLiquidationPrecision());

        uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dsce.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dsce.getAccountInformation(USER);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = dsce.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public view {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }
}
