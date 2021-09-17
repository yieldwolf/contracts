// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IYieldWolfAction {
    function execute(
        address yieldWolf,
        address strategy,
        address user,
        uint256 pid,
        uint256[] memory intInputs,
        address[] memory addrInputs
    ) external view returns (uint256, address);

    function callback(
        address yieldWolf,
        address strategy,
        address user,
        uint256 pid,
        uint256[] memory intInputs,
        address[] memory addrInputs
    ) external;
}
