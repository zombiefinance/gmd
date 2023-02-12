// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * Taken from https://github.com/jordaniza/OZ-Upgradeable-Foundry/blob/main/src/UpgradeUUPS.sol
 * 
 * Used only from deployments and testing, perhaps belongs in a different dir
 */
contract UUPSProxy is ERC1967Proxy {
    constructor(address _implementation, bytes memory _data) ERC1967Proxy(_implementation, _data) {}
}
