// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockWBNB is ERC20 {
    error NativeTransferFailed();

    constructor() ERC20("Wrapped BNB", "WBNB") { }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function withdraw(
        uint256 wad
    ) external {
        _burn(msg.sender, wad);
        (bool ok,) = payable(msg.sender).call{ value: wad }("");
        if (!ok) {
            revert NativeTransferFailed();
        }
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

