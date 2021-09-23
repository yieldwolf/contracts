// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '../interfaces/IYieldWolfAction.sol';

contract MockAction is IYieldWolfAction {
    bool public override isAction = true;
    bool public callbackCalled = false;

    function execute(
        address _yieldWolf,
        address _strategy,
        address _user,
        uint256 _pid,
        uint256[] calldata _intInputs,
        address[] calldata _addrInputs
    ) external view override returns (uint256, address) {
        return (_intInputs[0], _user);
    }

    function callback(
        address yieldWolf,
        address strategy,
        address user,
        uint256 pid,
        uint256[] calldata intInputs,
        address[] calldata addrInputs
    ) external override {
        callbackCalled = true;
    }
}
