// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/SelfLiquidityV3.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        SelfLiquidityV3 sl3 = new SelfLiquidityV3(
            "SelfLiqV3",
            "SLQ3",
            10 ether,
            5 ether,
            1 ether,
            1 ether
        );

        (bool ok, ) = address(sl3).call{value: 10 ether}("");
        require(ok, "fund");

        vm.stopBroadcast();
    }
}
