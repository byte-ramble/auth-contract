// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface Vm {
    function prank(
        address
    ) external;

    function startPrank(
        address
    ) external;

    function stopPrank() external;

    function warp(
        uint256
    ) external;

    function deal(
        address who,
        uint256 newBalance
    ) external;

    function etch(
        address who,
        bytes calldata code
    ) external;

    function expectRevert(
        bytes calldata
    ) external;

    function expectRevert(
        bytes4
    ) external;
}

abstract contract TestBase {
    error AssertionFailed(string message);

    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(
        bool condition,
        string memory message
    ) internal pure {
        if (!condition) {
            revert AssertionFailed(message);
        }
    }

    function assertFalse(
        bool condition,
        string memory message
    ) internal pure {
        if (condition) {
            revert AssertionFailed(message);
        }
    }

    function assertEq(
        uint256 left,
        uint256 right,
        string memory message
    ) internal pure {
        if (left != right) {
            revert AssertionFailed(message);
        }
    }

    function assertEq(
        int256 left,
        int256 right,
        string memory message
    ) internal pure {
        if (left != right) {
            revert AssertionFailed(message);
        }
    }

    function assertEq(
        address left,
        address right,
        string memory message
    ) internal pure {
        if (left != right) {
            revert AssertionFailed(message);
        }
    }

    function assertEq(
        bool left,
        bool right,
        string memory message
    ) internal pure {
        if (left != right) {
            revert AssertionFailed(message);
        }
    }

    function assertEq(
        bytes32 left,
        bytes32 right,
        string memory message
    ) internal pure {
        if (left != right) {
            revert AssertionFailed(message);
        }
    }

    function assertGte(
        uint256 left,
        uint256 right,
        string memory message
    ) internal pure {
        if (left < right) {
            revert AssertionFailed(message);
        }
    }

    function bound(
        uint256 x,
        uint256 min,
        uint256 max
    ) internal pure returns (uint256 result) {
        if (min > max) {
            revert AssertionFailed("bound: min > max");
        }

        if (x >= min && x <= max) {
            return x;
        }

        uint256 size = max - min + 1;
        result = min + (x % size);
    }

    function pow10(
        uint8 exp
    ) internal pure returns (uint256 result) {
        result = 1;
        for (uint8 i = 0; i < exp; ++i) {
            result *= 10;
        }
    }
}
