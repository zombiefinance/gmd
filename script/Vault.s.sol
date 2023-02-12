// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "src/Vault.sol";
import "src/GLPPrice.sol";
import "src/GMD.sol";
import "src/stake/esGMD.sol";
import "src/stake/GMDStake.sol";
import "src/lp/gmdLPToken.sol";
import "src/util/Constant.sol";
import "src/util/UUPSProxy.sol";

contract VaultScript is Script {
    UUPSProxy vaultProxy;
    UUPSProxy stakeProxy;

    GLPPrice priceFeed;
    GMD gmd;
    esGMD esgmd;
    GMDStake stake;

    gmdLPToken _gmdWFTM;
    gmdLPToken _gmdETH;
    gmdLPToken _gmdBTC;
    gmdLPToken _gmdDAI;
    gmdLPToken _gmdUSDT;
    gmdLPToken _gmdUSDC;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        priceFeed = new GLPPrice(Constant.GLP, Constant.GLP_POOL_MGR, Constant.GLP_POOL_ADD );
        gmd = new GMD();
        esgmd = new esGMD();
        esgmd.setGMD(address(gmd));
        stakeProxy = new UUPSProxy(address(new GMDStake()), "");
        stake = GMDStake(address(stakeProxy));
        stake.initialize();

        //All txns between arbi deployer and staking contract: https://arbiscan.io/txs?fromaddress=0x4bF7A0C21660879FdD051f5eE92Cd2936779EC57&address=0x5088a423933dbfd94af2d64ad3db3d4ab768107f
        stake.add(1000, gmd);
        stake.add(125, esgmd);

        vaultProxy = new UUPSProxy(address(new Vault()), "");
        Vault vault = Vault(payable(address(vaultProxy)));
        vault.initialize(
            Constant.WFTM,
            Constant.ES_MMY,
            Constant.REWARD_TRACKER_GLP,
            Constant.GLP_ROUTER,
            address(priceFeed),
            Constant.GLP_POOL_MGR
        );

        _gmdWFTM = new gmdWFTM(Constant.WFTM);
        _gmdETH = new gmdETH(Constant.ETH);
        _gmdBTC = new gmdBTC(Constant.BTC);
        _gmdDAI = new gmdDAI(Constant.DAI);
        _gmdUSDT = new gmdUSDT(Constant.USDT);
        _gmdUSDC = new gmdUSDC(Constant.USDC);

        _gmdWFTM.transferOwnership(address(vault));
        _gmdETH.transferOwnership(address(vault));
        _gmdBTC.transferOwnership(address(vault));
        _gmdDAI.transferOwnership(address(vault));
        _gmdUSDT.transferOwnership(address(vault));
        _gmdUSDC.transferOwnership(address(vault));

        vault.addPool(_gmdWFTM, 250, 1600);
        vault.addPool(_gmdETH, 250, 1600);
        vault.addPool(_gmdBTC, 250, 1600);
        vault.addPool(_gmdDAI, 500, 1600);
        vault.addPool(_gmdUSDT, 250, 1600);
        vault.addPool(_gmdUSDC, 250, 1600);

        //vault.setapr() // see https://arbiscan.io/tx/0xebdcc9ce3374d60bbbb149598daf6a6ad8f36b95b83d3378bc8803cfbd3bb121
        vault.setOpenAllVault(true);

        // vault.setPoolCap(_pid, _vaultcap);  set on each one
        vault.openAllWithdraw(true);

        //Should this be manual??
        //vault.startReward(_pid);
        //vault.setPoolCap(_pid, _amount)
        //vault.setOpenVault()

        vm.stopBroadcast();
    }
}
