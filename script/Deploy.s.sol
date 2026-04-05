// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/TopicAccessManagerUpgradeable.sol";

interface VmScript {
    function envAddress(
        string calldata key
    ) external view returns (address);

    function envUint(
        string calldata key
    ) external view returns (uint256);

    function startBroadcast() external;

    function stopBroadcast() external;
}

contract DeployScript {
    VmScript internal constant vm = VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (address proxy, address implementation) {
        address owner = vm.envAddress("OWNER");
        address bnbUsdOracle = vm.envAddress("BNB_USD_ORACLE");
        uint256 maxOracleDelay = vm.envUint("MAX_ORACLE_DELAY");

        vm.startBroadcast();

        TopicAccessManagerUpgradeable impl = new TopicAccessManagerUpgradeable();

        bytes memory initData =
            abi.encodeCall(TopicAccessManagerUpgradeable.initialize, (owner, bnbUsdOracle, maxOracleDelay));

        ERC1967Proxy p = new ERC1967Proxy(address(impl), initData);

        vm.stopBroadcast();

        proxy = address(p);
        implementation = address(impl);
    }
}
