// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFeeOnTransferERC20 is ERC20 {
    uint8 private immutable _customDecimals;
    uint16 private immutable _feeBps;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint16 feeBps_
    ) ERC20(name_, symbol_) {
        _customDecimals = decimals_;
        _feeBps = feeBps_;
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = (amount * _feeBps) / 10_000;
        uint256 amountAfterFee = amount - fee;

        super._update(from, to, amountAfterFee);

        if (fee != 0) {
            super._update(from, address(0), fee);
        }
    }
}
