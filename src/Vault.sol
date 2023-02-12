// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@oz-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import "@oz-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@oz-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@oz-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./util/Constant.sol";
import "./lp/gmdLPToken.sol";
import "forge-std/console.sol";

interface GLPRouter {
    function unstakeAndRedeemGlp(address _tokenOut, uint256 _GLPAmount, uint256 _minOut, address _receiver)
        external
        returns (uint256);

    function mintAndStakeGlp(address _token, uint256 _amount, uint256 _minUsdg, uint256 _minGLP)
        external
        returns (uint256);

    function claimFees() external;

    function claimEsGmx() external;

    function stakeEsGmx(uint256 _amount) external;
}

// interface rewardRouter {
//     function claimFees() external;

//     function claimEsGmx() external;

//     function stakeEsGmx(uint256 _amount) external;
// }

interface GLPPriceFeed {
    function getGLPprice() external view returns (uint256);

    function getPrice(address _token) external view returns (uint256);
}

interface IERC20DepositWithdraw is IERC20 {
    function deposit() external payable;

    function withdraw(uint256) external;
}

contract Vault is Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public treasuryMintedGLP;
    uint256 public slippage;

    IERC20DepositWithdraw public nativeToken;

    IERC20 public esMMY;
    IERC20 public rewardTrackerGLP;

    GLPRouter public glpRouter;
    address poolGLP;
    GLPPriceFeed public priceFeed;

    uint256 public compoundPercentage;
    uint256 public lpBacking;

    struct PoolInfo {
        igmdLPToken igmdLPToken;
        uint256 earnRateSec;
        uint256 totalStaked;
        uint256 lastUpdate;
        uint256 vaultcap;
        uint256 glpFees;
        uint256 apr;
        bool stakable;
        bool withdrawable;
        bool rewardStart;
    }

    // Info of each pool.
    PoolInfo[] public poolInfo;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _nativeToken,
        address _esMMY,
        address _rewardTracker,
        address _glpRouter,
        address _priceFeed,
        address _poolGLP
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        nativeToken = IERC20DepositWithdraw(_nativeToken);
        esMMY = IERC20(_esMMY);
        rewardTrackerGLP = IERC20(_rewardTracker);
        glpRouter = GLPRouter(_glpRouter);
        priceFeed = GLPPriceFeed(_priceFeed);
        poolGLP = _poolGLP;

        compoundPercentage = 500;
        slippage = 500;
    }

    function swapGLPto(uint256 amount, address token, uint256 min_receive) private returns (uint256) {
        return glpRouter.unstakeAndRedeemGlp(token, amount, min_receive, address(this));
    }

    function swapGLPout(uint256 amount, address token, uint256 min_receive) external onlyOwner returns (uint256) {
        require(((rewardTrackerGLP.balanceOf(address(this)) - amount) >= lpBackingNeeded()), "below backing");
        return glpRouter.unstakeAndRedeemGlp(token, amount, min_receive, address(this));
    }

    function swaptoGLP(uint256 amount, address token) private returns (uint256) {
        IERC20(token).safeApprove(poolGLP, amount);
        uint256 rval = glpRouter.mintAndStakeGlp(token, amount, 0, 0);
        IERC20(token).safeApprove(address(poolGLP), 0);
        return rval;
    }

    function treasuryMint(uint256 amount, address token) public onlyOwner {
        require(IERC20(token).balanceOf(address(this)) >= amount);
        treasuryMintedGLP = treasuryMintedGLP + (swaptoGLP(amount, token));
    }

    function cycleRewardsETHandesMMY() external onlyOwner {
        glpRouter.claimEsGmx();
        glpRouter.stakeEsGmx(esMMY.balanceOf(address(this)));
        _cycleRewardsETH();
    }

    function cycleRewardsETH() external onlyOwner {
        _cycleRewardsETH();
    }

    function _cycleRewardsETH() private {
        glpRouter.claimFees();
        uint256 rewards = nativeToken.balanceOf(address(this));
        uint256 compoundAmount = rewards * (compoundPercentage) / (1000);
        swaptoGLP(compoundAmount, address(nativeToken));
        nativeToken.transfer(owner(), nativeToken.balanceOf(address(this)));
    }

    function setCompoundPercentage(uint256 _percent) external onlyOwner {
        require(_percent < 900 && _percent > 0, "not in range");
        compoundPercentage = _percent;
    }

    function setGlpFees(uint256 _pid, uint256 _percent) external onlyOwner {
        require(_percent < 1000, "not in range");
        poolInfo[_pid].glpFees = _percent;
    }

    // Unlocks the staked + gained USDC and burns xUSDC
    function updatePool(uint256 _pid) internal {
        uint256 timepass = block.timestamp - (poolInfo[_pid].lastUpdate);
        poolInfo[_pid].lastUpdate = block.timestamp;
        uint256 reward = poolInfo[_pid].earnRateSec * (timepass);
        poolInfo[_pid].totalStaked += reward;
    }

    function updatePriceFeed(GLPPriceFeed _priceFeed) external onlyOwner {
        priceFeed = _priceFeed;
    }

    function updateRouter(GLPRouter _newRouter) external onlyOwner {
        glpRouter = _newRouter;
    }

    // function updateRewardRouter(rewardRouter _newRouter) external onlyOwner {
    //     _RewardRouter = _newRouter;
    // }

    function currentPoolTotal(uint256 _pid) public view returns (uint256) {
        uint256 reward = 0;
        if (poolInfo[_pid].rewardStart) {
            uint256 timepass = block.timestamp - (poolInfo[_pid].lastUpdate);
            reward = poolInfo[_pid].earnRateSec * (timepass);
        }
        return poolInfo[_pid].totalStaked + reward;
    }

    function updatePoolRate(uint256 _pid) internal {
        poolInfo[_pid].earnRateSec = poolInfo[_pid].totalStaked * (poolInfo[_pid].apr) / (10 ** 4) / (365 days);
    }

    function setPoolCap(uint256 _pid, uint256 _vaultcap) external onlyOwner {
        poolInfo[_pid].vaultcap = _vaultcap;
    }

    function setApr(uint256 _pid, uint256 _apr) external onlyOwner {
        require(_apr > 500 && _apr < 4000, " apr not in range");
        poolInfo[_pid].apr = _apr;
        if (poolInfo[_pid].rewardStart) {
            updatePool(_pid);
        }
        updatePoolRate(_pid);
    }

    function setOpenVault(uint256 _pid, bool open) external onlyOwner {
        poolInfo[_pid].stakable = open;
    }

    function setOpenAllVault(bool open) external onlyOwner {
        for (uint256 _pid = 0; _pid < poolInfo.length; ++_pid) {
            poolInfo[_pid].stakable = open;
        }
    }

    function startReward(uint256 _pid) external onlyOwner {
        require(!poolInfo[_pid].rewardStart, "already started");
        poolInfo[_pid].rewardStart = true;
        poolInfo[_pid].lastUpdate = block.timestamp;
    }

    function pauseReward(uint256 _pid) external onlyOwner {
        require(poolInfo[_pid].rewardStart, "not started");

        updatePool(_pid);
        updatePoolRate(_pid);
        poolInfo[_pid].rewardStart = false;
        poolInfo[_pid].lastUpdate = block.timestamp;
    }

    function openWithdraw(uint256 _pid, bool open) external onlyOwner {
        poolInfo[_pid].withdrawable = open;
    }

    function openAllWithdraw(bool open) external onlyOwner {
        for (uint256 _pid = 0; _pid < poolInfo.length; ++_pid) {
            poolInfo[_pid].withdrawable = open;
        }
    }

    function setSlippage(uint256 _slippage) external onlyOwner {
        require(_slippage >= 200 && _slippage <= 1000, "not in range");
        slippage = _slippage;
    }

    function checkDuplicate(igmdLPToken _igmdLPToken) internal view returns (bool) {
        for (uint256 i = 0; i < poolInfo.length; ++i) {
            if (poolInfo[i].igmdLPToken == _igmdLPToken) {
                return false;
            }
        }
        return true;
    }

    /**
     * Precondition:  gmdLPToken::transferOwnership() must be called to ensure our gmdLPToken::acceptOwnership() call at end works
     */
    function addPool(gmdLPToken _gmdLPToken, uint256 _fees, uint256 _apr) external onlyOwner {
        require(_fees <= 1000, "out of range. Fees too high");
        require(_apr > 500 && _apr < 4000, " apr not in range");
        require(checkDuplicate(_gmdLPToken), "pool already created");

        poolInfo.push(
            PoolInfo({
                igmdLPToken: _gmdLPToken,
                totalStaked: 0,
                earnRateSec: 0,
                lastUpdate: block.timestamp,
                vaultcap: 0,
                stakable: false,
                withdrawable: false,
                rewardStart: false,
                glpFees: _fees,
                apr: _apr
            })
        );
        _gmdLPToken.acceptOwnership();
    }

    receive() external payable {}

    /**
     * Native Token (Fantom->FTM, Ethereum->ETH)
     *
     * If successful will put into wrapped native token (Fantom->WFTM, Ethereum->WETH)
     */
    function enterNativeToken(uint256 _pid) external payable nonReentrant {
        enterImpl(msg.value, _pid, true);
    }

    function enter(uint256 _amountin, uint256 _pid) public nonReentrant {
        enterImpl(_amountin, _pid, false);
    }

    function enterImpl(uint256 _amountin, uint256 _pid, bool isNativeToken) internal {
        require(_amountin > 0, "invalid amount");
        uint256 _amount = _amountin;

        igmdLPToken lpToken = poolInfo[_pid].igmdLPToken;
        IERC20 collateralToken = IERC20(lpToken.getUnderlyingToken());

        uint256 decimalMul = 18 - IERC20Metadata(address(collateralToken)).decimals();

        //decimals handlin
        _amount = _amountin * (10 ** decimalMul);

        require(_amountin <= (isNativeToken ? msg.value : collateralToken.balanceOf(msg.sender)), "balance too low");
        require(poolInfo[_pid].stakable, "not stakable");
        require((poolInfo[_pid].totalStaked + _amount) <= poolInfo[_pid].vaultcap, "cant deposit more than vault cap");

        if (poolInfo[_pid].rewardStart) {
            updatePool(_pid);
        }

        // Gets the amount of USDC locked in the contract
        uint256 totallpTokens = poolInfo[_pid].totalStaked;
        // Gets the amount of gdUSDC in existence
        uint256 totalShares = lpToken.totalSupply();

        uint256 balanceMultipier = 100000 - poolInfo[_pid].glpFees;
        uint256 amountAfterFee = _amount * (balanceMultipier) / (100000);

        // If no gdUSDC exists, mint it 1:1 to the amount put in
        if (totalShares == 0 || totallpTokens == 0) {
            lpToken.mint(msg.sender, amountAfterFee);
        }
        // Calculate and mint the amount of gdUSDC the USDC is worth. The ratio will change overtime
        else {
            uint256 what = amountAfterFee * (totalShares) / (totallpTokens);
            lpToken.mint(msg.sender, what);
        }

        poolInfo[_pid].totalStaked += amountAfterFee;

        updatePoolRate(_pid);

        if (isNativeToken) {
            nativeToken.deposit{value: msg.value}();
        } else {
            collateralToken.safeTransferFrom(msg.sender, address(this), _amountin);
        }
        swaptoGLP(_amountin, address(collateralToken));
    }

    /**
     * Native Token (Fantom->FTM, Ethereum->ETH)
     *
     *
     * If successful will convert from wrapped to native token, so user gets native token
     */
    function leaveNativeToken(uint256 _share, uint256 _pid) external nonReentrant returns (uint256) {
        return leaveImpl(_share, _pid, true);
    }

    function leave(uint256 _share, uint256 _pid) public nonReentrant returns (uint256) {
        return leaveImpl(_share, _pid, false);
    }

    function leaveImpl(uint256 _share, uint256 _pid, bool isNativeToken) internal returns (uint256) {
        igmdLPToken lpToken = poolInfo[_pid].igmdLPToken;
        IERC20 collateralToken = IERC20(lpToken.getUnderlyingToken());

        require(_share <= lpToken.balanceOf(msg.sender), "balance too low");
        require(poolInfo[_pid].withdrawable, "withdraw window not opened");

        if (poolInfo[_pid].rewardStart) {
            updatePool(_pid);
        }

        // Gets the amount of xUSDC in existence
        uint256 totalShares = lpToken.totalSupply();

        // Calculates the amount of USDC the xUSDC is worth
        uint256 amountOut = _share * (poolInfo[_pid].totalStaked) / (totalShares);
        poolInfo[_pid].totalStaked -= amountOut;
        updatePoolRate(_pid);
        lpToken.burn(msg.sender, _share);

        uint256 decimalMul = 18 - IERC20Metadata(address(collateralToken)).decimals();
        //decimals handlin
        uint256 amountSendOut = amountOut / (10 ** decimalMul) * (100000 - slippage) / (100000);
        uint256 GLPPrice = priceFeed.getGLPprice(); //* (percentage) / (100000);
        uint256 tokenPrice = priceFeed.getPrice(address(collateralToken));
        uint256 GLPOut = amountOut * (10 ** 12) * (tokenPrice) / (GLPPrice) / (10 ** 30); //amount *GLP price after decimals handled
        //see https://arbiscan.io/tx/0xfdf197b61d19cab946aa8ff51c0665004a4f649f9d8f3c964b4d76e469413bb2#eventlog we see a leave() with a RemoveLiquidity event where amount=199369933

        uint256 amountSent = swapGLPto(GLPOut, address(collateralToken), amountSendOut);

        if (isNativeToken) {
            nativeToken.withdraw(amountSendOut);
            (bool success,) = msg.sender.call{value: amountSent}("");
            require(success, "Failed to send FTM");
        } else {
            collateralToken.safeTransfer(msg.sender, amountSent);
        }
        return amountSent;
    }

    function displayStakedBalance(address _address, uint256 _pid) public view returns (uint256) {
        igmdLPToken lpToken = poolInfo[_pid].igmdLPToken;
        uint256 totalShares = lpToken.totalSupply();
        // Calculates the amount of USDC the xUSDC is worth
        uint256 amountOut = lpToken.balanceOf(_address) * (currentPoolTotal(_pid)) / (totalShares);
        return amountOut;
    }

    function GDpriceTolpToken(uint256 _pid) public view returns (uint256) {
        igmdLPToken lpToken = poolInfo[_pid].igmdLPToken;
        uint256 totalShares = lpToken.totalSupply();
        // Calculates the amount of USDC the xUSDC is worth
        uint256 amountOut = (currentPoolTotal(_pid)) * (10 ** 18) / (totalShares);
        return amountOut;
    }

    function convertDust(address _token) external onlyOwner {
        swaptoGLP(IERC20(_token).balanceOf(address(this)), _token);
    }

    //Recover treasury tokens from contract if needed

    function recoverTreasuryTokensFromGLP(address _token, uint256 GLPamount) external onlyOwner {
        //only allow to recover treasury tokens and not drain the vault
        require(((rewardTrackerGLP.balanceOf(address(this)) - GLPamount) >= lpBackingNeeded()), "below backing");
        treasuryMintedGLP = treasuryMintedGLP - (GLPamount);
        swapGLPto(GLPamount, _token, 0);
        IERC20(_token).safeTransfer(msg.sender, IERC20(_token).balanceOf(address(this)));
    }

    function recoverTreasuryTokens(address _token, uint256 _amount) external onlyOwner {
        //cant drain GLP
        require(_token != address(rewardTrackerGLP), "no GLP draining");

        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    function totalUSDvault(uint256 _pid) public view returns (uint256) {
        IERC20 collateralToken = IERC20(poolInfo[_pid].igmdLPToken.getUnderlyingToken());
        uint256 tokenPrice = priceFeed.getPrice(address(collateralToken));
        uint256 totallpTokens = currentPoolTotal(_pid);
        uint256 totalUSD = tokenPrice * (totallpTokens) / (10 ** 30);

        return totalUSD;
    }

    function totalUSDvaults() public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < poolInfo.length; ++i) {
            total = total + (totalUSDvault(i));
        }

        return total;
    }

    function lpBackingNeeded() public view returns (uint256) {
        uint256 GLPPrice = priceFeed.getGLPprice();

        return totalUSDvaults() * (10 ** 12) / (GLPPrice);
    }

    function GLPinVault() public view returns (uint256) {
        return rewardTrackerGLP.balanceOf(address(this));
    }

    function getPoolLength() public view returns (uint256) {
        return poolInfo.length;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
