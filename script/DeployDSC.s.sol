// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {DecentralizeStableCoin} from "../src/DecentralizeStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDSC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run()
        external
        returns (DecentralizeStableCoin, DSCEngine, HelperConfig)
    {
        HelperConfig config = new HelperConfig();
        (
            address wEthUsdPriceFeed,
            address wBtcUsdPriceFeed,
            address weth,
            address wbtc,
            uint256 deployerKey
        ) = config.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wEthUsdPriceFeed, wBtcUsdPriceFeed];
        vm.startBroadcast(deployerKey);
        DecentralizeStableCoin dsc = new DecentralizeStableCoin();
        DSCEngine engine = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(dsc)
        );

        dsc.transferOwnership(address(engine)); //from the ownerable inheritance, now only the engine can do anything with it
        vm.stopBroadcast();

        return (dsc, engine, config);
    }
}
