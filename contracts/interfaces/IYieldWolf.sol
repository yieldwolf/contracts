// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IYieldWolf {
    function operators(address addr) external returns (bool);

    function depositFee() external returns (uint256);

    function withdrawFee() external returns (uint256);

    function performanceFee() external returns (uint256);

    function performanceFeeBountyPct() external returns (uint256);

    function ruleFee() external returns (uint256);

    function ruleFeeBountyPct() external returns (uint256);

    function feeAddress() external returns (address);

    function stakedTokens(uint256 pid, address user) external view returns (uint256);
}
