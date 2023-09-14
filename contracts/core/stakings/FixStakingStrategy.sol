// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import { ITreasury } from "../../interfaces/ITreasury.sol";
import { IItem } from "../../interfaces/IItem.sol";
import { IStakingStrategy } from "../../interfaces/IStakingStrategy.sol";
import { IAddressBook } from "../../interfaces/IAddressBook.sol";
import "hardhat/console.sol";

contract FixStakingStrategy is IStakingStrategy, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    // ------------------------------------------------------------------------------------
    // ----- CONSTANTS --------------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    uint256 public constant REWARDS_PERIOD = 30 days;

    // ------------------------------------------------------------------------------------
    // ----- STORAGE ----------------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    address public addressBook;
    uint256 public rewardsRate;
    uint256 public lockYears;
    uint256 public yearDeprecationRate;
    mapping(address item => mapping(uint256 tokenId => uint256)) public initialTimestamp;
    mapping(address item => mapping(uint256 tokenId => uint256)) public claimedPeriodsCount;
    mapping(address item => mapping(uint256 tokenId => uint256)) public finalTimestamp;
    mapping(address item => mapping(uint256 tokenId => uint256)) public withdrawnRewards;

    // ------------------------------------------------------------------------------------
    // ----- DEPLOY & UPGRADE  ------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    function initialize(
        address _addressBook,
        uint256 _rewardsRate,
        uint256 _lockYears,
        uint256 _yearDeprecationRate
    ) public initializer {
        addressBook = _addressBook;
        rewardsRate = _rewardsRate;
        lockYears = _lockYears;
        yearDeprecationRate = _yearDeprecationRate;
    }

    function _authorizeUpgrade(address) internal view override {
        IAddressBook(addressBook).enforceIsProductOwner(msg.sender);
    }

    // ------------------------------------------------------------------------------------
    // -----  PROTOCOL ACTIONS  -----------------------------------------------------------
    // ------------------------------------------------------------------------------------

    function stake(address _itemAddress, uint256 _itemId, bytes memory) external {
        IAddressBook(addressBook).enforceIsItemContract(msg.sender);

        uint256 _initialTimestamp = block.timestamp;
        initialTimestamp[_itemAddress][_itemId] = _initialTimestamp;
        finalTimestamp[_itemAddress][_itemId] = _initialTimestamp + REWARDS_PERIOD * lockYears * 12;
    }

    // ------------------------------------------------------------------------------------
    // ----- USER ACTIONS  ----------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    function claim(
        address _itemAddress,
        uint256 _itemId,
        address _withdrawToken
    ) external nonReentrant {
        _enforceIsTokenOwner(_itemAddress, _itemId);

        (uint256 rewards, uint256 claimedPeriods) = estimateRewards(_itemAddress, _itemId);
        require(rewards > 0, "rewards!");

        claimedPeriodsCount[_itemAddress][_itemId] += claimedPeriods;
        withdrawnRewards[_itemAddress][_itemId] += rewards;

        address _treasury = IAddressBook(addressBook).treasury();
        uint256 withdrawTokenAmount = ITreasury(_treasury).usdAmountToToken(
            rewards,
            _withdrawToken
        );
        ITreasury(_treasury).withdraw(_withdrawToken, withdrawTokenAmount, msg.sender);
    }

    function sell(
        address _itemAddress,
        uint256 _itemId,
        address _withdrawToken
    ) external nonReentrant {
        _enforceIsTokenOwner(_itemAddress, _itemId);

        require(canSell(_itemAddress, _itemId), "can't sell!");

        address _treasury = IAddressBook(addressBook).treasury();
        uint256 sellAmount = estimateSell(_itemAddress, _itemId);
        uint256 withdrawTokenAmount = ITreasury(_treasury).usdAmountToToken(
            sellAmount,
            _withdrawToken
        );
        require(withdrawTokenAmount > 0, "zero amount!");

        withdrawnRewards[_itemAddress][_itemId] += sellAmount;
        IItem(_itemAddress).burn(_itemId);
        ITreasury(_treasury).withdraw(_withdrawToken, withdrawTokenAmount, msg.sender);
    }

    // ------------------------------------------------------------------------------------
    // ----- VIEW  ------------------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    function stakingType() external pure returns (string memory) {
        return "fix";
    }

    function estimateRewards(
        address _itemAddress,
        uint256 _itemId
    ) public view returns (uint256 rewards_, uint256 claimedPeriods_) {
        uint256 _initialTimestamp = initialTimestamp[_itemAddress][_itemId];
        uint256 _claimedPeriodsCount = claimedPeriodsCount[_itemAddress][_itemId];
        uint256 _finalTimestamp = finalTimestamp[_itemAddress][_itemId];

        uint256 estimatedTimestamp = block.timestamp;
        if (estimatedTimestamp > _finalTimestamp) estimatedTimestamp = _finalTimestamp;
        uint256 allExpiredPeriods = (estimatedTimestamp - _initialTimestamp) / REWARDS_PERIOD;

        claimedPeriods_ = allExpiredPeriods - _claimedPeriodsCount;
        rewards_ =
            (claimedPeriods_ * IItem(_itemAddress).tokenPrice(_itemId) * rewardsRate) /
            12 /
            10000;
    }

    function canSell(address _itemAddress, uint256 _itemId) public view returns (bool) {
        if (block.timestamp < finalTimestamp[_itemAddress][_itemId]) {
            return false;
        }
        (uint256 rewards, ) = estimateRewards(_itemAddress, _itemId);
        return rewards == 0;
    }

    function estimateSell(address _itemAddress, uint256 _itemId) public view returns (uint256) {
        uint256 tokenPrice = IItem(_itemAddress).tokenPrice(_itemId);
        uint256 deprecation = (tokenPrice * lockYears * yearDeprecationRate) / 10000;
        if (deprecation > tokenPrice) return 0;
        return tokenPrice - deprecation;
    }

    function claimTimestamp(
        address _itemAddress,
        uint256 _itemId,
        uint256 _monthsCount
    ) external view returns (uint256) {
        uint256 _finalTimestamp = finalTimestamp[_itemAddress][_itemId];
        uint256 _initialTimestamp = initialTimestamp[_itemAddress][_itemId];
        uint256 _nextClaimTimestamp = _initialTimestamp + _monthsCount * REWARDS_PERIOD;
        if (_nextClaimTimestamp > _finalTimestamp) _nextClaimTimestamp = _finalTimestamp;
        return _nextClaimTimestamp;
    }

    // ------------------------------------------------------------------------------------
    // ----- INTERNAL  --------------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    function _enforceIsTokenOwner(address _tokenAddress, uint256 _tokenId) internal view {
        require(IERC721(_tokenAddress).ownerOf(_tokenId) == msg.sender, "only token owner!");
    }
}
