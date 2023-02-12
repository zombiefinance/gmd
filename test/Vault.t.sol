// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/GLPPrice.sol";
import "../src/Vault.sol";
import "../src/lp/gmdLPToken.sol";
import "../src/util/Constant.sol";
import "../src/util/UUPSProxy.sol";
import "./MockWrappedFtm.sol";
import "forge-std/console.sol";


contract VaultTest is Test {
    using SafeERC20 for IERC20;

    uint160 addressCounter;

    address priceFeed;
    Vault vault;

    gmdLPToken lpWFTM;
    gmdLPToken lpETH;
    gmdLPToken lpBTC;
    gmdLPToken lpDAI;
    gmdLPToken lpUSDT;
    gmdLPToken lpUSDC;

    ERC20 esMMY;
    ERC20 rewardTracker;
    ERC20 glp;
    address glpMgr;
    address glpRouter;
    address poolGlp;

    // Maybe mirror this txn? https://ftmscan.com/tx/0x3d14c40d836b0119ad32f678d92282dbb26abe3da96600cd7e3a83ffa9f1bb3c

    function setUp() public {
        esMMY = new ERC20("Escrowed MMY", "esMMY");
        rewardTracker = new ERC20("Fee MMY", "fMMY");
        glp = new ERC20("MMY LP", "MLP"); //Fortunately we only use as a IERC20

        lpWFTM = new gmdWFTM(address(new MockWrappedFtm(address(this), 500 ether))); //Needed b/c of the deposit() method, otherwise could use ERC20Mock
        lpETH = new gmdETH(address(new ERC20Mock("Mock Ethereum", "ETH", address(this), 500 ether)));
        lpBTC = new gmdBTC(Constant.BTC);
        lpDAI = new gmdDAI(Constant.DAI);
        lpUSDT = new gmdUSDT(Constant.USDT);
        lpUSDC = new gmdUSDC(Constant.USDC);

        glpMgr = address(++addressCounter);
        vm.mockCall(
            glpMgr, abi.encodeWithSelector(GLPmanager.getAum.selector, lpWFTM.getUnderlyingToken()), abi.encode(100)
        );

        poolGlp = address(++addressCounter);
        vm.mockCall(poolGlp, abi.encodeWithSelector(GLPpool.getMinPrice.selector, true), abi.encode(10));

        priceFeed = address(++addressCounter);
        vm.mockCall(priceFeed, abi.encodeWithSelector(GLPPrice.getGLPprice.selector), abi.encode(10));
        vm.mockCall(priceFeed, abi.encodeWithSelector(GLPPrice.getPrice.selector), abi.encode(11));
        vm.mockCall(priceFeed, abi.encodeWithSelector(GLPPrice.getAum.selector), abi.encode(12));

        glpRouter = address(++addressCounter);
        
        UUPSProxy proxy = new UUPSProxy(address(new Vault()), "");
        vault = Vault(payable(address(proxy)));
        vault.initialize(
            lpWFTM.getUnderlyingToken(), address(esMMY), address(rewardTracker), glpRouter, priceFeed, poolGlp
        );

        lpWFTM.transferOwnership(address(vault));
        lpETH.transferOwnership(address(vault));
        lpBTC.transferOwnership(address(vault));
        lpDAI.transferOwnership(address(vault));
        lpUSDT.transferOwnership(address(vault));
        lpUSDC.transferOwnership(address(vault));

        vault.addPool(lpWFTM, 250, 1600);
        vault.addPool(lpETH, 250, 1600);
        vault.addPool(lpBTC, 250, 1600);
        vault.addPool(lpDAI, 500, 1600);
        vault.addPool(lpUSDT, 250, 1600);
        vault.addPool(lpUSDC, 250, 1600);
    }

    function testInitZero() public {
        for (uint256 i = 0; i < vault.getPoolLength(); i++) {
            assertEq(vault.currentPoolTotal(i), 0);
        }
    }

    /**
     * Could be in a util class somewhere
     */
    function moveFwdBlock(uint256 n) internal {
        vm.roll(block.number + n);
        vm.warp(block.timestamp + (n * 12 seconds));
    }

    function testOneStake() public {
        uint256 poolId = 1;
        gmdLPToken lpToken = lpETH;
        address user = address(++addressCounter);
        uint256 amount = 200 * 1e18;

        IERC20 collateral = IERC20(lpToken.getUnderlyingToken());
        collateral.safeTransfer(user, amount);
        // vm.mockCall(wftm, abi.encodeWithSelector(IERC20.balanceOf.selector, user), abi.encode(amount));

        uint256 balance = IERC20(collateral).balanceOf(user);
        vm.prank(user);
        vm.expectRevert("balance too low");
        vault.enter(balance + 1, poolId);

        vm.prank(user);
        vm.expectRevert("not stakable");
        vault.enter(balance, poolId);

        vault.setOpenVault(poolId, true);
        vm.prank(user);

        vm.expectRevert("cant deposit more than vault cap");
        vault.enter(balance, poolId);

        vault.setPoolCap(poolId, balance * 1e20);
        // No need for approvals for native??
        // vm.prank(user);
        // vm.expectRevert(); //each token gives an inconsistent error. USDC we get 'WERC10: request exceeds allowance', others might get '"ERC20: transfer amount exceeds allowance"'
        // vault.enter(balance, poolId);

        vm.startPrank(user);
        collateral.safeIncreaseAllowance(address(vault), balance * 1e20);
        ///Had to add some extra padding here, was lazy and did *2

        uint256 amountAfterFee = 199500000000000000000;
        vm.expectCall(address(lpToken), abi.encodeCall(lpToken.mint, (address(user), amountAfterFee)));
        vm.expectCall(address(collateral), abi.encodeCall(IERC20.transferFrom, (address(user), address(vault), amount)));
        vm.expectCall(
            address(glpRouter), abi.encodeCall(GLPRouter.mintAndStakeGlp, (lpToken.getUnderlyingToken(), amount, 0, 0))
        );

        vault.enter(balance, poolId);

        assertEq(vault.displayStakedBalance(address(user), poolId), amountAfterFee);
        assertEq(vault.currentPoolTotal(poolId), amountAfterFee);
        {
            (
                ,
                uint256 earnRateSec,
                uint256 totalStaked,
                uint256 lastUpdate,
                uint256 vaultcap,
                uint256 glpFees,
                uint256 apr,
                ,
                ,
            ) = vault.poolInfo(poolId);

            assertEq(earnRateSec, 1012176560121);
            assertEq(totalStaked, amountAfterFee);
            assertEq(lastUpdate, 1);
            assertEq(vaultcap, 20000000000000000000000000000000000000000);
            assertEq(glpFees, 250);
            assertEq(apr, 1600);

            moveFwdBlock(1);
        }

        balance = IERC20(collateral).balanceOf(user);
        uint256 lpBalance = lpToken.balanceOf(address(user));

        // vm.expectRevert("withdraw window not opened");
        // vault.leave(lpBalance, poolId);
        vm.stopPrank();

        vault.openAllWithdraw(true);

        vm.startPrank(user);
        uint256 minAmount = amountAfterFee * (100000 - vault.slippage()) / 100000;
        vm.expectCall(address(lpToken), abi.encodeCall(lpToken.burn, (address(user), amountAfterFee)));
        vm.mockCall(glpRouter, abi.encodeWithSelector(GLPRouter.unstakeAndRedeemGlp.selector), abi.encode(minAmount));
        vm.expectCall(address(collateral), abi.encodeCall(IERC20.transfer, (address(user), minAmount)));
        vault.leave(lpBalance, poolId);

        vm.stopPrank();
    }

    function testOneStakeNativeToken() public {
        uint256 poolId = 0;
        gmdLPToken lpToken = lpWFTM;
        address user = address(++addressCounter);
        uint256 amount = 200 * 1e18;

        IERC20 collateral = IERC20(lpToken.getUnderlyingToken());

        vm.deal(user, amount);

        uint256 balance = user.balance;
        // vm.prank(user);
        // vm.expectRevert("balance too low");
        // vault.enterNativeToken{value: balance + 1}(poolId);

        vm.prank(user);
        vm.expectRevert("not stakable");
        vault.enterNativeToken{value: amount}(poolId);

        vault.setOpenVault(poolId, true);
        vm.prank(user);
        vm.expectRevert("cant deposit more than vault cap");
        vault.enterNativeToken{value: amount}(poolId);
        vault.setPoolCap(poolId, balance * 1e20);

        vm.startPrank(user);
        // collateral.safeIncreaseAllowance(address(vault), balance * 1e20);

        uint256 amountAfterFee = 199500000000000000000;
        vm.expectCall(address(lpToken), abi.encodeCall(lpToken.mint, (address(user), amountAfterFee)));
        vm.expectCall(address(collateral), abi.encodeCall(IERC20DepositWithdraw.deposit, ()));
        vm.expectCall(
            address(glpRouter), abi.encodeCall(GLPRouter.mintAndStakeGlp, (lpToken.getUnderlyingToken(), amount, 0, 0))
        );

        vault.enterNativeToken{value: amount}(poolId);

        assertEq(vault.displayStakedBalance(address(user), poolId), amountAfterFee);
        assertEq(vault.currentPoolTotal(poolId), amountAfterFee);
        {
            (
                ,
                uint256 earnRateSec,
                uint256 totalStaked,
                uint256 lastUpdate,
                uint256 vaultcap,
                uint256 glpFees,
                uint256 apr,
                ,
                ,
            ) = vault.poolInfo(poolId);

            assertEq(earnRateSec, 1012176560121);
            assertEq(totalStaked, amountAfterFee);
            assertEq(lastUpdate, 1);
            assertEq(vaultcap, 20000000000000000000000000000000000000000);
            assertEq(glpFees, 250);
            assertEq(apr, 1600);

            moveFwdBlock(1);
        }

        balance = IERC20(collateral).balanceOf(user);
        uint256 lpBalance = lpToken.balanceOf(address(user));

        vm.expectRevert("withdraw window not opened");
        vault.leave(lpBalance, poolId);
        vm.stopPrank();

        vault.openAllWithdraw(true);

        vm.startPrank(user);
        uint256 minAmount = amountAfterFee * (100000 - vault.slippage()) / 100000;
        vm.expectCall(address(lpToken), abi.encodeCall(lpToken.burn, (address(user), amountAfterFee)));
        vm.mockCall(glpRouter, abi.encodeWithSelector(GLPRouter.unstakeAndRedeemGlp.selector), abi.encode(minAmount));
        vm.expectCall(address(collateral), abi.encodeCall(IERC20DepositWithdraw.withdraw, minAmount));
        vault.leaveNativeToken(lpBalance, poolId);

        vm.stopPrank();
    }

    function enterVault(
        uint256 poolId,
        igmdLPToken gmdLP,
        address user,
        uint256 amount,
        uint256 amountAfterFee,
        uint256 currentEarnRateSec,
        uint256 currentPoolTotal
    ) internal {
        uint256 balance;
        {
            IERC20 erc20 = IERC20(gmdLP.getUnderlyingToken());
            erc20.safeTransfer(user, amount);

            balance = erc20.balanceOf(user);

            vm.startPrank(user);
            erc20.safeIncreaseAllowance(address(vault), balance * 1e20);
            ///Had to add some extra padding here, was lazy and did *2
        }
        vm.expectCall(address(gmdLP), abi.encodeCall(gmdLP.mint, (address(user), amountAfterFee)));
        vm.expectCall(
            gmdLP.getUnderlyingToken(), abi.encodeCall(IERC20.transferFrom, (address(user), address(vault), amount))
        );
        vm.expectCall(
            address(glpRouter), abi.encodeCall(GLPRouter.mintAndStakeGlp, (gmdLP.getUnderlyingToken(), amount, 0, 0))
        );

        vault.enter(balance, poolId);

        assertEq(vault.displayStakedBalance(address(user), poolId), amountAfterFee);
        assertEq(vault.currentPoolTotal(poolId), currentPoolTotal);
        {
            (
                ,
                uint256 earnRateSec,
                uint256 totalStaked,
                uint256 lastUpdate,
                uint256 vaultcap,
                uint256 glpFees,
                uint256 apr,
                ,
                ,
            ) = vault.poolInfo(poolId);

            assertEq(earnRateSec, currentEarnRateSec);
            assertEq(totalStaked, currentPoolTotal);
            assertEq(lastUpdate, 1);
            assertEq(vaultcap, POOL_CAP);
            assertEq(glpFees, 250);
            assertEq(apr, 1600);

            moveFwdBlock(1);
        }

        // balance = IERC20(wftm).balanceOf(user);
        vm.stopPrank();
    }

    function exitVault(
        uint256 poolId,
        igmdLPToken gmdLP,
        address user,
        uint256 amount,
        uint256 currentEarnRateSec,
        uint256 currentPoolTotal
    ) internal {
        // console.log("Withdrawing ", amount, " for user ", user);
        vm.startPrank(user);

        uint256 minAmount = amount * (100000 - vault.slippage()) / 100000;
        vm.mockCall(glpRouter, abi.encodeWithSelector(GLPRouter.unstakeAndRedeemGlp.selector), abi.encode(minAmount));

        vm.expectCall(address(gmdLP), abi.encodeCall(gmdLP.burn, (address(user), amount)));
        vm.mockCall(glpRouter, abi.encodeWithSelector(GLPRouter.unstakeAndRedeemGlp.selector), abi.encode(minAmount));
        vm.expectCall(gmdLP.getUnderlyingToken(), abi.encodeCall(IERC20.transfer, (address(user), minAmount)));

        vault.leave(amount, poolId);

        {
            (
                ,
                uint256 earnRateSec,
                uint256 totalStaked,
                uint256 lastUpdate,
                uint256 vaultcap,
                uint256 glpFees,
                uint256 apr,
                ,
                ,
            ) = vault.poolInfo(poolId);

            assertEq(earnRateSec, currentEarnRateSec);
            assertEq(totalStaked, currentPoolTotal);
            assertEq(lastUpdate, 1);
            assertEq(vaultcap, POOL_CAP);
            assertEq(glpFees, 250);
            assertEq(apr, 1600);

            moveFwdBlock(1);
        }

        vm.stopPrank();
    }

    uint256 constant POOL_CAP = 600 ether;

    function testTwoStake() public {
        uint256 poolId = 1;
        gmdLPToken lpToken = lpETH;

        address user1 = address(++addressCounter);
        uint256 amount1 = 200 ether;

        uint256 amountAfterFee1 = 199500000000000000000;

        vault.setOpenVault(poolId, true);
        vault.setPoolCap(poolId, POOL_CAP);

        enterVault(poolId, lpToken, user1, amount1, amountAfterFee1, 1012176560121, amountAfterFee1);

        address user2 = address(++addressCounter);
        uint256 amount2 = 300 ether;
        uint256 amountAfterFee2 = 299250000000000000000;
        enterVault(poolId, lpToken, user2, amount2, amountAfterFee2, 2530441400304, amountAfterFee1 + amountAfterFee2);

        //Partial withdrawal
        vault.openAllWithdraw(true);
        uint256 lpBalance = lpToken.balanceOf(address(user1)) / 2;
        exitVault(poolId, lpToken, user1, lpBalance, 2024353120243, amountAfterFee1 + amountAfterFee2 - lpBalance);

        //another partial withdrawal
        uint256 lpBalance2 = lpToken.balanceOf(address(user1)) / 2;
        exitVault(
            poolId,
            lpToken,
            user1,
            lpBalance2,
            1771308980213,
            amountAfterFee1 + amountAfterFee2 - lpBalance - lpBalance2
        );

        // Full withdrawal
        exitVault(poolId, lpToken, user1, lpBalance2, 1518264840182, amountAfterFee2);

        //      console.log("amountAfterFee1 ", amountAfterFee1);
        //    console.log("amountAfterFee2 ", amountAfterFee2);
        //    console.log("lpBalance ", lpBalance);
        //    console.log("lpBalance2 ", lpBalance2);
        //    console.log("lpBalance3 ", lpBalance3);
    }
}
