// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.13;

// import "forge-std/Test.sol";
// import "../src/GLPPrice.sol";
// import "../src/util/Constant.sol";

// // https://ftmscan.com/address/0xa6d7d0e650aa40ffa42d845a354c12c2bc0ab15f#readContract
// contract GLPPriceTest is Test {
//     GLPPrice public price;

//     function setUp() public {
//         uint256 fork = vm.createFork(vm.envString("RPC_URL"));
//         vm.selectFork(fork);
//         vm.rollFork(54_805_017);

//         price = new GLPPrice(Constant.GLP, Constant.GLP_POOL_MGR, Constant.GLP_POOL_ADD);
//     }

//     function testPriceLookup() public {
//         assertEq(price.getAum(), 7251174912567262309066132172937575271);
//         assertEq(price.getGLPprice(), 7150740912565);
//         assertEq(
//             price.getPrice(Constant.BTC),
//             23106150000000000000000000000000000
//         );
//         assertEq(
//             price.getPrice(Constant.ETH),
//             1589260000000000000000000000000000
//         );
//         assertEq(
//             price.getPrice(Constant.USDC),
//             1000000000000000000000000000000
//         );
//         assertEq(price.getPrice(Constant.DAI), 1000000000000000000000000000000);
//         assertEq(
//             price.getPrice(Constant.USDT),
//             1000000000000000000000000000000
//         );
//         assertEq(price.getPrice(Constant.WFTM), 545000000000000000000000000000);
//     }
// }
