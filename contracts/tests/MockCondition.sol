// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '../interfaces/IYieldWolfCondition.sol';
import '../interfaces/IYieldWolf.sol';
import '../interfaces/IYieldWolfStrategy.sol';

contract MockCondition is IYieldWolfCondition {
    bool public override isCondition = true;

    function check(
        address _strategy,
        address _user,
        uint256 _pid,
        uint256[] calldata _intInputs,
        address[] calldata _addrInputs
    ) external view override returns (bool) {
        return _intInputs[0] != 0;
    }
}
