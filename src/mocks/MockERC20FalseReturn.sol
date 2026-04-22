// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract MockERC20FalseReturn {
    mapping(address => uint256) public balanceOf;

    function mint(
        address to,
        uint256 amount
    ) external {
        balanceOf[to] += amount;
    }

    function transfer(
        address,
        uint256
    ) external pure returns (bool) {
        return false;
    }
}
