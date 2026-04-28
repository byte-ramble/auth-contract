// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../TopicAccessManagerUpgradeable.sol";

contract TopicAccessManagerUpgradeableV2 is TopicAccessManagerUpgradeable {
    uint256 private _v2Flag;

    function setV2Flag(
        uint256 value
    ) external onlyOwner {
        _v2Flag = value;
    }

    function v2Flag() external view returns (uint256) {
        return _v2Flag;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
