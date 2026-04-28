// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract MockWBNBUnderpay {
    error InsufficientBalance();
    error NativeTransferFailed();

    mapping(address => uint256) public balanceOf;

    function mint(
        address to,
        uint256 amount
    ) external {
        balanceOf[to] += amount;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 fromBalance = balanceOf[msg.sender];
        if (fromBalance < amount) {
            revert InsufficientBalance();
        }

        unchecked {
            balanceOf[msg.sender] = fromBalance - amount;
        }
        balanceOf[to] += amount;

        return true;
    }

    function withdraw(
        uint256 wad
    ) external {
        uint256 fromBalance = balanceOf[msg.sender];
        if (fromBalance < wad) {
            revert InsufficientBalance();
        }

        unchecked {
            balanceOf[msg.sender] = fromBalance - wad;
        }

        (bool ok,) = payable(msg.sender).call{ value: wad / 2 }("");
        if (!ok) {
            revert NativeTransferFailed();
        }
    }

    receive() external payable { }
}
