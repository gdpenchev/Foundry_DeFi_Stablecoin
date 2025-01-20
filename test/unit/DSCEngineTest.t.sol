// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizeStableCoin} from "../../src/DecentralizeStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizeStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, , ) = config
            .activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /////////////////////////
    //Constructor Testes/////
    ////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLenghtDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////
    //Price Testes/////
    ///////////////////

    function testGetUsdAmount() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUSD = 30000e18;
        uint256 actualUSD = engine.getUsdValue(weth, ethAmount);

        assertEq(expectedUSD, actualUSD);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////
    //Deposit Collateral Testes/////
    ///////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock(
            "RAN",
            "RAN",
            USER,
            AMOUNT_COLLATERAL
        );
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        engine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositCollaterAndMintDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDSC(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine
            .getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    ///////////////////////////////////////
    // Mint Tests //
    ///////////////////////////////////////

    function testMintDscRevertsIfZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDSC(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mindDsc(0);
        vm.stopPrank();
    }

    function testMintRevertsIfHealthIsBroken() public depositedCollateral {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();

        console.log(price);

        amountToMint =
            (amountCollateral *
                (uint256(price) * engine.getAdditionalFeedPrecision())) /
            engine.getPrecision();

        console.log(amountToMint);

        vm.startPrank(USER);

        uint256 expectedHealthFactor = engine.calculateHealthFactor(
            amountToMint,
            engine.getUsdValue(weth, amountCollateral)
        );

        console.log("expected", expectedHealthFactor);

        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__HealthFactorBroken.selector,
                expectedHealthFactor
            )
        );
        engine.mindDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.startPrank(USER);

        engine.mindDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // burnDsc Tests //
    ///////////////////////////////////
    function testBurnDscReversIfAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDSC(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDSC(0);
        vm.stopPrank();
    }

    function testBurnDscBurnSuccessful() public depositCollaterAndMintDsc {
        vm.startPrank(USER);
        dsc.approve(address(engine), amountToMint);
        engine.burnDSC(amountToMint);
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
        vm.stopPrank();
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    // function testRevertsIfMintedDscBreaksHealthFactor() public {
    //     (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
    //         .latestRoundData();
    //     amountToMint =
    //         (amountCollateral *
    //             (uint256(price) * engine.getAdditionalFeedPrecision())) /
    //         dsce.getPrecision();
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(dsce), amountCollateral);

    //     uint256 expectedHealthFactor = dsce.calculateHealthFactor(
    //         amountToMint,
    //         dsce.getUsdValue(weth, amountCollateral)
    //     );
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             DSCEngine.DSCEngine__BreaksHealthFactor.selector,
    //             expectedHealthFactor
    //         )
    //     );
    //     dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
    //     vm.stopPrank();
    // }

    // modifier depositedCollateralAndMintedDsc() {
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(dsce), amountCollateral);
    //     dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
    //     vm.stopPrank();
    //     _;
    // }

    // function testCanMintWithDepositedCollateral()
    //     public
    //     depositedCollateralAndMintedDsc
    // {
    //     uint256 userBalance = dsc.balanceOf(user);
    //     assertEq(userBalance, amountToMint);
    // }
}
