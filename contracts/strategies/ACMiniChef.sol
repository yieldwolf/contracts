// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import './AutoCompoundStrategy.sol';

interface IFarm {
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _to
    ) external;

    function withdrawAndHarvest(
        uint256 _pid,
        uint256 _amount,
        address _to
    ) external;

    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256);

    function emergencyWithdraw(uint256 _pid, address _to) external;
}

/**
 * @title AutoCompound MiniChef
 * @notice strategy for auto-compounding on pools using a MiniChef based contract
 * @dev MiniChef is used by Sushi and ApeSwap on polygon
 * @author YieldWolf
 */
contract ACMiniChef is AutoCompoundStrategy {
    using SafeERC20 for IERC20;

    function _farmDeposit(uint256 amount) internal override {
        IERC20(stakeToken).safeIncreaseAllowance(masterChef, amount);
        IFarm(masterChef).deposit(pid, amount, address(this));
    }

    function _farmWithdraw(uint256 amount) internal override {
        IFarm(masterChef).withdrawAndHarvest(pid, amount, address(this));
    }

    function _farmEmergencyWithdraw() internal override {
        IFarm(masterChef).emergencyWithdraw(pid, address(this));
    }

    function _totalStaked() internal view override returns (uint256 amount) {
        (amount, ) = IFarm(masterChef).userInfo(pid, address(this));
    }
}
