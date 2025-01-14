// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
// The correct path for ReentrancyGuard in latest Openzeppelin contracts is
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizeStableCoin} from "./DecentralizeStableCoin.sol";

/*
 * @title DSCEngine
 * @author Patrick Collins
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    /////////////
    // Errors //
    /////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorBroken(uint256 healthFactor);
    error DSCEngine__TransferFailed();

    /////////////////////
    // State variables //
    /////////////////////
    uint256 private constant ADDITIONAL_FEED_RATIO = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collaterDeposited;
    mapping(address user => uint256 amountDscMintet) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizeStableCoin private immutable i_dsc;

    /////////////////////
    // Events //
    /////////////////////
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    /////////////
    // Modifiers //
    /////////////

    modifier needsMoreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /////////////
    // Functions //
    /////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }
        // These feeds will be the USD pairs
        // For example ETH / USD or MKR / USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizeStableCoin(dscAddress);
    }

    ////////////////////////
    // External Functions //
    ///////////////////////
    function depositCollateralAndMintDSC() external {}

    //following ChecksEffectsInteractions pattern CEI
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        external
        needsMoreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        //Here user address is msg.sender, and tokenCollateralAddress is the address of the token that the user wants to deposit
        s_collaterDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;

        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );

        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollatalForDSC() external {}

    function redeemCollateral() external {}

    function mindDsc(
        uint256 amountDscToMint
    ) external needsMoreThanZero(amountDscToMint) nonReentrant {
        //following ChecksEffectsInteractions pattern CEI
        //amountDscToMint is the amount of DSC (decentralized stable coin) that the user wants to mint
        //must have more collateral than the amount of DSC that the user wants to mint
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealhFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);

        if (!minted) {
            revert DSCEngine__TransferFailed();
        }
    }

    function burnDSC() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}

    //////////////////////////////////
    // Private & Internal Functions //
    /////////////////////////////////

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    //returns how close the user is to being liquidated
    //if goes below 1 it means the user is insolvent
    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalDSCMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);

        uint256 collaterAdjustedThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHHOLD) / LIQUIDATION_PRECISION;

        return (collaterAdjustedThreshold * PRECISION) / totalDSCMinted;

        ///if we have 1000 ETH * 50 = 50 000 / 100 = 500
        //100 ETH and 100 DSC minted
        //150 ETH * 50 = 7500 / 100 = 75 /100 DSC < 1 liquidated
    }

    function _revertIfHealhFactorIsBroken(address user) internal view {
        //check health if they have enough collateral.
        uint256 userHealthFactor = _healthFactor(user);

        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBroken(userHealthFactor);
        }
    }

    //////////////////////////////////
    // Public & External Functions //
    /////////////////////////////////

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collaterDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int price, , , ) = priceFeed.latestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_RATIO) * amount) / PRECISION;
    }
}
