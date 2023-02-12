// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./igmdLPToken.sol";

contract gmdLPToken is ERC20, Ownable2Step, igmdLPToken {
    address public immutable underlyingToken;

    constructor(address _underlyingToken, string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        underlyingToken = _underlyingToken;
    }

    function burn(address _from, uint256 _amount) external onlyOwner {
        _burn(_from, _amount);
    }

    function mint(address recipient, uint256 _amount) external onlyOwner {
        _mint(recipient, _amount);
    }

    function getUnderlyingToken() external view returns (address) {
        return underlyingToken;
    }
}

contract gmdBTC is gmdLPToken {
    constructor(address _underlyingToken) gmdLPToken(_underlyingToken, "gmdBTC", "gmdBTC") {}
}

contract gmdDAI is gmdLPToken {
    constructor(address _underlyingToken) gmdLPToken(_underlyingToken, "gmdDAI", "gmdDAI") {}
}

contract gmdETH is gmdLPToken {
    constructor(address _underlyingToken) gmdLPToken(_underlyingToken, "gmdETH", "gmdETH") {}
}

contract gmdUSDC is gmdLPToken {
    constructor(address _underlyingToken) gmdLPToken(_underlyingToken, "gmdUSDC", "gmdUSDC") {}
}

contract gmdUSDT is gmdLPToken {
    constructor(address _underlyingToken) gmdLPToken(_underlyingToken, "gmdUSDT", "gmdUSDT") {}
}

contract gmdWFTM is gmdLPToken {
    constructor(address _underlyingToken) gmdLPToken(_underlyingToken, "gmdWFTM", "gmdWFTM") {}
}
