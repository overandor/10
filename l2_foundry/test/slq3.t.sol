// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/SelfLiquidityV3.sol";

contract SLQ3Test is Test {
    SelfLiquidityV3 internal slq3;

    function setUp() public {
        slq3 = new SelfLiquidityV3("SelfLiqV3", "SLQ3", 10 ether, 5 ether, 1 ether, 1 ether);

        vm.deal(address(this), 20 ether);
        (bool success, ) = address(slq3).call{value: 10 ether}("");
        require(success, "fund contract");
    }

    function testPriceIsOneAtInit() public {
        uint256 p = slq3.priceWad();
        assertEq(p, 1e18);
    }

    function testBuyMintAndInvariants() public {
        uint256 beforeTR = slq3.totalReserve();
        uint256 pay = 1 ether;

        vm.deal(address(0xBEEF), pay);
        vm.prank(address(0xBEEF));
        uint256 minted = slq3.buy{value: pay}(1);
        assertGt(minted, 0);

        bool ok = slq3.invariantHolds();
        assertTrue(ok);
        assertEq(slq3.totalReserve(), beforeTR + pay);
    }

    receive() external payable {}
}
