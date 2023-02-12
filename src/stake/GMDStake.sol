// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@oz-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import "@oz-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@oz-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@oz-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "src/util/Constant.sol";

//From https://arbiscan.io/address/0x5088a423933dbfd94af2d64ad3db3d4ab768107f?fromaddress=0x4bF7A0C21660879FdD051f5eE92Cd2936779EC57#code instead!
// originally based upon https://github.com/pancakeswap/pancake-farm/blob/master/contracts/SousChef.sol
contract GMDStake is Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 rpAmount;
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rpRewardDebt; // Reward debt. See explanation below.
            //
            // We do some fancy math here. Basically, any point in time, the amount of WFTMs
            // entitled to a user but is pending to be distributed is:
            //
            //   pending reward = (user.amount * pool.accWFTMPerShare) - user.rewardDebt
            //
            // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
            //   1. The pool's `accWFTMPerShare` (and `lastRewardBlock`) gets updated.
            //   2. User receives the pending reward sent to his/her address.
            //   3. User's `amount` gets updated.
            //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 totalRP;
        uint256 allocPoint; // How many allocation points assigned to this pool. WFTMs to distribute per block.
        uint256 lastRewardTime; // Last block time that WFTMs distribution occurs.
        uint256 accWFTMPerShare; // Accumulated WFTMs per share, times 1e12. See below.
        uint256 accRPPerShare; //RPpershare
    }

    IERC20 public constant wftm = IERC20(Constant.WFTM);

    // Dev address.
    address teamD;
    address teamD2;
    // WFTM tokens created per block.
    uint256 public wFTMPerSecond;
    uint256 public rpPerSecond;

    uint256 public totalWFTMdistributed;

    // set a max WFTM per second, which can never be higher than 1 per second
    uint256 public constant maxwFTMPerSecond = 1e18;

    uint256 public constant MaxAllocPoint = 4000;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;
    // The block time when WFTM mining starts.
    uint256 public startTime;

    bool public withdrawable;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
    }

    function openWithdraw() external onlyOwner {
        withdrawable = true;
    }

    function supplyRewards(uint256 _amount) external onlyOwner {
        totalWFTMdistributed = totalWFTMdistributed + (_amount);
        wftm.transferFrom(msg.sender, address(this), _amount);
        uint256 teamAmount = _amount * (1900) / (10000);
        uint256 teamAmount2 = _amount * (1100) / (10000);
        wftm.transfer(teamD, teamAmount);
        wftm.transfer(teamD2, teamAmount2);
    }

    function closeWithdraw() external onlyOwner {
        withdrawable = false;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Changes WFTM token reward per second, with a cap of maxWFTM per second
    // Good practice to update pools without messing up the contract
    function setwFTMPerSecond(uint256 _wFTMPerSecond) external onlyOwner {
        require(_wFTMPerSecond <= maxwFTMPerSecond, "setwFTMPerSecond: too many WFTMs!");

        // This MUST be done or pool rewards will be calculated with new WFTM per second
        // This could unfairly punish small pools that dont have frequent deposits/withdraws/harvests
        massUpdatePools();

        wFTMPerSecond = _wFTMPerSecond;
    }

    function serpPerSecond(uint256 _rpPerSecond) external onlyOwner {
        // This MUST be done or pool rewards will be calculated with new WFTM per second
        // This could unfairly punish small pools that dont have frequent deposits/withdraws/harvests
        massUpdatePools();

        rpPerSecond = _rpPerSecond;
    }

    function checkForDuplicate(IERC20 _lpToken) internal view {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            require(poolInfo[_pid].lpToken != _lpToken, "add: pool already exists!!!!");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken) external onlyOwner {
        require(_allocPoint <= MaxAllocPoint, "add: too many alloc points!!");

        checkForDuplicate(_lpToken); // ensure you cant add duplicate pools

        massUpdatePools();

        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint += totalAllocPoint + (_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardTime: lastRewardTime,
                accWFTMPerShare: 0,
                accRPPerShare: 0,
                totalRP: 0
            })
        );
    }

    // Update the given pool's WFTM allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) external onlyOwner {
        require(_allocPoint <= MaxAllocPoint, "add: too many alloc points!!");

        massUpdatePools();

        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        _from = _from > startTime ? _from : startTime;
        if (_to < startTime) {
            return 0;
        }
        return _to - _from;
    }

    // View function to see pending WFTMs on frontend.
    function pendingWFTM(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accWFTMPerShare = pool.accWFTMPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        uint256 total = lpSupply + (pool.totalRP);
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 WFTMReward = multiplier * (wFTMPerSecond) * (pool.allocPoint) / (totalAllocPoint);
            accWFTMPerShare = accWFTMPerShare + (WFTMReward * (1e12) / (total));
        }
        uint256 userPoint = user.amount + (user.rpAmount);
        return userPoint * (accWFTMPerShare) / (1e12) - (user.rewardDebt);
    }

    function pendingRP(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRPPerShare = pool.accRPPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        uint256 total = lpSupply + (pool.totalRP);
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 RPReward = multiplier * (rpPerSecond) * (pool.allocPoint) / (totalAllocPoint);
            accRPPerShare = accRPPerShare + (RPReward * (1e12) / (total));
        }
        uint256 userPoint = user.amount + (user.rpAmount);
        return userPoint * (accRPPerShare) / (1e12) - (user.rpRewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        uint256 total = lpSupply + (pool.totalRP);
        if (lpSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
        uint256 WFTMReward = multiplier * (wFTMPerSecond) * (pool.allocPoint) / (totalAllocPoint);
        uint256 RPReward = multiplier * (rpPerSecond) * (pool.allocPoint) / (totalAllocPoint);
        pool.accWFTMPerShare = pool.accWFTMPerShare + (WFTMReward * (1e12) / (total));
        pool.accRPPerShare = pool.accRPPerShare + (RPReward * (1e12) / (total));
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens to MasterChef for WFTM allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        uint256 fee = _amount * (10) / (10000);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 userPoint = user.amount + (user.rpAmount);
        uint256 pending = userPoint * (pool.accWFTMPerShare) / (1e12) - (user.rewardDebt);
        uint256 RPpending = userPoint * (pool.accRPPerShare) / (1e12) - (user.rpRewardDebt);

        user.amount = user.amount + (_amount) - (fee);
        user.rpAmount = user.rpAmount + (RPpending);

        userPoint = user.amount + (user.rpAmount);
        user.rewardDebt = userPoint * (pool.accWFTMPerShare) / (1e12);
        user.rpRewardDebt = userPoint * (pool.accRPPerShare) / (1e12);

        pool.totalRP = pool.totalRP + (RPpending);

        if (pending > 0) {
            safeWFTMTransfer(msg.sender, pending);
        }
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        pool.lpToken.safeTransfer(owner(), fee);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "withdraw: not good");
        require(withdrawable, "withdraw not opened");

        updatePool(_pid);

        uint256 userPoint = user.amount + (user.rpAmount);
        uint256 pending = userPoint * (pool.accWFTMPerShare) / (1e12) - (user.rewardDebt);

        user.amount = user.amount - (_amount);

        if (_amount > 0) {
            pool.totalRP = pool.totalRP - (user.rpAmount);
            user.rpAmount = 0;
        }
        userPoint = user.amount + (user.rpAmount);
        user.rewardDebt = userPoint * (pool.accWFTMPerShare) / (1e12);
        user.rpRewardDebt = userPoint * (pool.accRPPerShare) / (1e12);

        if (pending > 0) {
            safeWFTMTransfer(msg.sender, pending);
        }
        pool.lpToken.safeTransfer(address(msg.sender), _amount);

        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY. 30% penalty fees
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 oldUserAmount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        pool.lpToken.safeTransfer(address(msg.sender), oldUserAmount * (700) / (1000));
        pool.lpToken.safeTransfer(owner(), oldUserAmount * (300) / (1000));

        emit EmergencyWithdraw(msg.sender, _pid, oldUserAmount);
    }

    // Safe WFTM transfer function, just in case if rounding error causes pool to not have enough WFTMs.
    function safeWFTMTransfer(address _to, uint256 _amount) internal {
        uint256 WFTMBal = wftm.balanceOf(address(this));
        if (_amount > WFTMBal) {
            wftm.transfer(_to, WFTMBal);
        } else {
            wftm.transfer(_to, _amount);
        }
    }

    function updateTeam(address _team) external onlyOwner {
        teamD = _team;
    }

    function updateTeam2(address _team) external onlyOwner {
        teamD2 = _team;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
