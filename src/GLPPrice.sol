// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./util/Constant.sol";

interface GLPpool {
    function getMinPrice(address _token) external view returns (uint256);
    function getMaxPrice(address _token) external view returns (uint256);
}

interface GLPmanager {
    function getAum(bool maximise) external view returns (uint256);
}

contract GLPPrice {
    IERC20 public glp;
    GLPmanager public glpMgr;
    GLPpool pool;

    constructor(address _glp, address _glpManagr, address _glpPool) {
        glp = IERC20(_glp);
        glpMgr = GLPmanager(_glpManagr);
        pool = GLPpool(_glpPool);
    }

    function getGLPprice() public view returns (uint256) {
        uint256 total_supply = glp.totalSupply();
        uint256 aum = glpMgr.getAum(true);
        return aum * (100000) / (total_supply) / (100000);
    }

    function getPrice(address _token) public view returns (uint256) {
        return pool.getMinPrice(_token);
    }

    function getAum() public view returns (uint256) {
        return glpMgr.getAum(true);
    }
}
