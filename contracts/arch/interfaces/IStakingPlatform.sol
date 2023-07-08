// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

interface IStakingPlatform {
    
    struct StakingInfo {
        uint256[] itemsIds;
        uint256[] itemsAmounts;
        uint256 totalPrice;
        // uint256 availableRounds;
        address rewardsStrategy;
        uint256 initialRound;
        // uint256 claimedRounds;
        // uint256 finalRound;
        uint256 finalRound;
        uint256 lastClaimedRound;
        bool freezed;
    }

    function stakingsInfo(uint256 _stakingId) external view returns (StakingInfo memory);

    function getRound(uint256 _timestamp) external view returns (uint256);

    function roundStartTimestamp(uint256 _round) external view returns (uint256);

    function addRewardsStrategy(address _rewardsStartegy) external;

     function setItemsFactory(address _itemsFactory) external;

     function setTreasury(address _treasury) external ;
}
