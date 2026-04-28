// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../TopicAccessManagerUpgradeable.sol";

contract TopicAccessManagerLegacySeeder is TopicAccessManagerUpgradeable {
    function seedLegacyStableTokens(
        address legacyUsdc,
        address legacyUsdt
    ) external onlyOwner {
        assembly {
            sstore(7, legacyUsdc)
            sstore(8, legacyUsdt)
        }
    }
}
