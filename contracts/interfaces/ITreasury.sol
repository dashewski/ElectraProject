// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

interface ITreasury {
    function enforceIsSupportedToken(address _token) external view;

    function usdAmountToToken(uint256 _usdAmount, address _token) external view returns (uint256);

    function withdraw(address _token, uint256 _amount, address _recipient) external;

    function USD_DECIMALS() external view returns(uint256);
}
