// SPDX-License-Identifier: MIT

//// _____.___.__       .__       ._____      __      .__   _____  ////
//// \__  |   |__| ____ |  |    __| _/  \    /  \____ |  |_/ ____\ ////
////  /   |   |  |/ __ \|  |   / __ |\   \/\/   /  _ \|  |\   __\  ////
////  \____   |  \  ___/|  |__/ /_/ | \        (  <_> )  |_|  |    ////
////  / ______|__|\___  >____/\____ |  \__/\  / \____/|____/__|    ////
////  \/              \/           \/       \/                     ////

pragma solidity 0.8.9;

import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';

contract UniswapV2Resolver {
    function validateData(
        address _tokenFrom,
        address _tokenTo,
        bytes calldata _data
    ) external pure {
        (, address[] memory path) = abi.decode(_data, (address, address[]));
        require(path.length > 1, 'validateData: path must be greater than 1');
        require(path.length <= 5, 'validateData: path too large');
        require(path[0] == _tokenFrom, 'validateData: path must start with tokenFrom');
        require(path[path.length - 1] == _tokenTo, 'validateData: path must end with tokenTo');
    }

    function resolveSwapExactTokensForTokens(
        uint256 _amountIn,
        bytes calldata _data,
        address _recipient
    ) external view returns (address router, bytes memory sig) {
        address[] memory path;
        (router, path) = abi.decode(_data, (address, address[]));
        sig = abi.encodeWithSignature(
            'swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)',
            _amountIn,
            1,
            path,
            _recipient,
            block.timestamp
        );
    }

    function getAmountOut(uint256 _amountIn, bytes calldata _data) external view returns (uint256) {
        (address router, address[] memory path) = abi.decode(_data, (address, address[]));
        uint256[] memory amounts = IUniswapV2Router02(router).getAmountsOut(_amountIn, path);
        return amounts[amounts.length - 1];
    }
}
