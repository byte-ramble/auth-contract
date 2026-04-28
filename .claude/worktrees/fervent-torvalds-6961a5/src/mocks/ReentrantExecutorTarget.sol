// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPrivilegedCaller {
    function executePrivilegedCall(
        address target,
        uint256 value,
        bytes calldata data
    ) external returns (bool success, bytes memory returnData);
}

contract ReentrantExecutorTarget {
    function reenter(
        address manager,
        address target,
        bytes calldata data
    ) external {
        IPrivilegedCaller(manager).executePrivilegedCall(target, 0, data);
    }
}
