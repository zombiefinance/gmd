// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "src/util/Constant.sol";

// From https://arbiscan.io/address/0x49E050dF648E9477c7545fE1779B940f879B787A#code
contract esGMD is ERC20("esGMD", "esGMD"), Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 totalVested;
        uint256 lastInteractionTime;
        uint256 VestPeriod;
    }

    mapping(address => UserInfo) public userInfo;

    uint256 public vestingPeriod = 365 days;
    IERC20 public gmd;

    function setGMD(address _gmd) external onlyOwner {
        gmd = IERC20(_gmd);
    }

    function burn(uint256 _amount) external {
        _burn(msg.sender, _amount);
    }

    function claimableTokens(address _address) external view returns (uint256) {
        uint256 timePass = block.timestamp - (userInfo[_address].lastInteractionTime);
        uint256 claimable;
        if (timePass >= userInfo[msg.sender].VestPeriod) {
            claimable = userInfo[_address].totalVested;
        } else {
            claimable = userInfo[_address].totalVested * (timePass) / (userInfo[_address].VestPeriod);
        }
        return claimable;
    }

    function vest(uint256 _amount) external nonReentrant {
        require(this.balanceOf(msg.sender) >= _amount, "esGMD balance too low");
        uint256 _amountin = _amount;
        uint256 amountOut = _amountin;

        userInfo[msg.sender].totalVested = userInfo[msg.sender].totalVested + (amountOut);
        userInfo[msg.sender].lastInteractionTime = block.timestamp;
        userInfo[msg.sender].VestPeriod = vestingPeriod;

        _burn(msg.sender, _amount);
    }

    function lock(uint256 _amount) external nonReentrant {
        require(gmd.balanceOf(msg.sender) >= _amount, "GMD balance too low");
        uint256 amountOut = _amount;
        _mint(msg.sender, amountOut);
        gmd.safeTransferFrom(msg.sender, address(this), _amount);
    }

    function claim() external nonReentrant {
        require(userInfo[msg.sender].totalVested > 0, "no mint");
        uint256 timePass = block.timestamp - (userInfo[msg.sender].lastInteractionTime);
        uint256 claimable;
        if (timePass >= userInfo[msg.sender].VestPeriod) {
            claimable = userInfo[msg.sender].totalVested;
            userInfo[msg.sender].VestPeriod = 0;
        } else {
            claimable = userInfo[msg.sender].totalVested * (timePass) / (userInfo[msg.sender].VestPeriod);
            userInfo[msg.sender].VestPeriod = userInfo[msg.sender].VestPeriod - (timePass);
        }
        userInfo[msg.sender].totalVested = userInfo[msg.sender].totalVested - (claimable);
        userInfo[msg.sender].lastInteractionTime = block.timestamp;

        gmd.transfer(msg.sender, claimable);
    }

    function remainingVestedTime() external view returns (uint256) {
        uint256 timePass = block.timestamp - (userInfo[msg.sender].lastInteractionTime);
        if (timePass >= userInfo[msg.sender].VestPeriod) {
            return 0;
        } else {
            return userInfo[msg.sender].VestPeriod - (timePass);
        }
    }
}
