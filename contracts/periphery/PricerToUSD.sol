// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { IPricerToUSD } from "../interfaces/IPricerToUSD.sol";

contract PricerToUSD is IPricerToUSD, OwnableUpgradeable {
    int256 public currentPrice;

    event SetPrice(int256 oldPrice, int256 newPrice);

    function initialize(int256 _initialPrice) public initializer {
        __Ownable_init();
        currentPrice = _initialPrice;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        answer = currentPrice;
    }

    function setCurrentPrice(int256 _newPrice) external onlyOwner {
        require(_newPrice > 0, "PricerToUSD: price must be greater than zero!");
        int256 oldPrice = currentPrice;
        currentPrice = _newPrice;

        emit SetPrice(oldPrice, _newPrice);
    }
}
