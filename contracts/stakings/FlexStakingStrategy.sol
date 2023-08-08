// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { ERC721Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import { ITreasury } from "../interfaces/ITreasury.sol";
import { IItem } from "../interfaces/IItem.sol";
import { IStakingStrategy } from "../interfaces/IStakingStrategy.sol";
import { IAddressBook } from "../interfaces/IAddressBook.sol";
import { DateTimeLib } from "../libs/DateTimeLib.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import { GovernanceRole } from "../roles/GovernanceRole.sol";
import "hardhat/console.sol";

contract FlexStakingStrategy is
    IStakingStrategy,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    GovernanceRole
{
    address public treasury;
    address public addressBook;
    uint256 public minLockYears;
    uint256 public maxLockYears;
    uint256 public initialMonths;
    uint256 public initialRewardsRate;
    uint256 public yearDeprecationRate;

    mapping(uint256 => mapping(uint256 => uint256)) earnings;

    mapping(uint256 => mapping(uint256 => uint256)) public depositsToRemove;
    mapping(uint256 => mapping(uint256 => uint256)) public deposits;
    uint256 public lastUpdatedTimestamp;

    mapping(address => mapping(uint256 => uint256)) public initialTimestamp;
    mapping(address => mapping(uint256 => uint256)) public lastClaimTimestamp;
    mapping(address => mapping(uint256 => uint256)) public startSellTimestamp;
    mapping(address => mapping(uint256 => uint256)) public finalTimestamp;
    mapping(address => mapping(uint256 => uint256)) public remainder;

    function setEarnings(uint256 _month, uint256 _year, uint256 _earning) external {
        _enforceIsGovernance();
        earnings[_year][_month] = _earning;
    }

    function initialize(
        address _governance,
        address _treasury,
        address _addressBook,
        uint256 _minLockYears,
        uint256 _maxLockYears,
        uint256 _initialMonths,
        uint256 _initialRewardsRate,
        uint256 _yearDeprecationRate
    ) public initializer {
        governance = _governance;
        treasury = _treasury;
        addressBook = _addressBook;
        minLockYears = _minLockYears;
        maxLockYears = _maxLockYears;
        lastUpdatedTimestamp = block.timestamp;
        initialMonths = _initialMonths;
        initialRewardsRate = _initialRewardsRate;
        yearDeprecationRate = _yearDeprecationRate;
    }

    function _authorizeUpgrade(address) internal view override {
        _enforceIsGovernance();
    }

    function _enforceIsCallFromItemContract() internal view {
        require(IAddressBook(addressBook).items(msg.sender), "only item!");
    }

    function updateDeposits() public {
        uint256 _lastUpdatedTimestamp = lastUpdatedTimestamp;

        console.log("deff");
        uint256 monthToUpdate = DateTimeLib.diffMonths(_lastUpdatedTimestamp, block.timestamp);
        console.log("monthToUpdate", monthToUpdate);
        for (uint256 i; i < monthToUpdate; ++i) {
            console.log("i", i);
            (uint256 prevYear, uint256 prevMonth, ) = DateTimeLib.timestampToDate(
                _lastUpdatedTimestamp
            );
            _lastUpdatedTimestamp = DateTimeLib.addMonths(_lastUpdatedTimestamp, 1);
            (uint256 year, uint256 month, ) = DateTimeLib.timestampToDate(_lastUpdatedTimestamp);
            deposits[year][month] += deposits[prevYear][prevMonth];
            deposits[year][month] -= depositsToRemove[year][month];

            console.log("year", year);
            console.log("month", month);
            console.log(" deposits[year][month]", deposits[year][month]);
        }
        lastUpdatedTimestamp = _lastUpdatedTimestamp;
    }

    function currentPeriod() external view returns (uint256 month_, uint256 year_) {
        (year_, month_, ) = DateTimeLib.timestampToDate(block.timestamp);
    }

    function nextClaimTimestamp(
        address _itemAddress,
        uint256 _itemId,
        uint256 _monthsCount
    ) external view returns (uint256) {
        uint256 _lastClaimTimestamp = lastClaimTimestamp[_itemAddress][_itemId];
        uint256 _finalTimestamp = finalTimestamp[_itemAddress][_itemId];
        uint256 _nextClaimTimestamp = DateTimeLib.addMonths(_lastClaimTimestamp, _monthsCount);
        if (_nextClaimTimestamp > _finalTimestamp) _nextClaimTimestamp = _finalTimestamp;
        return _nextClaimTimestamp;
    }

    function stake(address _itemAddress, uint256 _itemId, bytes memory) external {
        _enforceIsCallFromItemContract();
        uint256 _initialTimestamp = block.timestamp;
        uint256 _finalTimestamp = DateTimeLib.addYears(_initialTimestamp, maxLockYears);
        initialTimestamp[_itemAddress][_itemId] = _initialTimestamp;
        lastClaimTimestamp[_itemAddress][_itemId] = _initialTimestamp;
        startSellTimestamp[_itemAddress][_itemId] = DateTimeLib.addYears(
            _initialTimestamp,
            minLockYears
        );
        finalTimestamp[_itemAddress][_itemId] = _finalTimestamp;

        uint256 earningsTimestamp = DateTimeLib.addMonths(_initialTimestamp, initialMonths);
        (uint256 earningsYear, uint256 earningsMonth, uint256 earningsDay) = DateTimeLib
            .timestampToDate(earningsTimestamp);
        (uint256 finalYear, uint256 finalMonth, ) = DateTimeLib.timestampToDate(_finalTimestamp);

        uint256 totalPrice = IItem(_itemAddress).tokenPrice(_itemId);

        uint256 daysInStartMonth = DateTimeLib.getDaysInMonth(earningsTimestamp);
        uint256 ratio = ((earningsDay - 1) * 10000) / daysInStartMonth;
        uint256 _remainder = (totalPrice * ratio) / 10000;
        remainder[_itemAddress][_itemId] = _remainder;
        deposits[earningsYear][earningsMonth] += totalPrice - _remainder;
        uint256 nextEarningsMonth = earningsMonth + 1;
        uint256 nextEarningsYear = earningsYear;
        if (nextEarningsMonth > 12) {
            nextEarningsMonth = 1;
            nextEarningsYear += 1;
        }
        deposits[nextEarningsYear][nextEarningsMonth] += _remainder;
        uint256 prevFinalMonth = finalMonth - 1;
        uint256 prevFinalsYear = finalYear;
        if (prevFinalMonth == 0) {
            prevFinalMonth = 12;
            nextEarningsYear -= 1;
        }
        depositsToRemove[prevFinalsYear][prevFinalMonth] += _remainder;
        depositsToRemove[finalYear][finalMonth] += totalPrice - _remainder;
    }

    function estimateRewards(
        address _itemAddress,
        uint256 _itemId
    ) public view returns (uint256 rewards_, uint256 expiredPeriods_) {
        console.log("aw21");
        uint256 _initialTimestamp = initialTimestamp[_itemAddress][_itemId];
        uint256 _lastClaimTimestamp = lastClaimTimestamp[_itemAddress][_itemId];
        uint256 _finalTimestamp = finalTimestamp[_itemAddress][_itemId];

        console.log("aw22");
        uint256 currentTimestamp = block.number;
        if (currentTimestamp > _finalTimestamp) currentTimestamp = _finalTimestamp;

        console.log("aw23");
        uint256 totalPrice = IItem(_itemAddress).tokenPrice(_itemId);

        console.log("aw24");
        uint256 allExpiredMonths = DateTimeLib.diffMonths(_initialTimestamp, block.timestamp);
        uint256 claimedMonths = DateTimeLib.diffMonths(_initialTimestamp, _lastClaimTimestamp);

        console.log("allExpiredMonths", allExpiredMonths);
        console.log("claimedMonths", claimedMonths);
        console.log("aw25");
        for (uint256 i = claimedMonths; i < allExpiredMonths; ++i) {
            console.log("aw26");
            console.log("i", i);
            if (i < initialMonths) {
                console.log("aw27");
                rewards_ += (totalPrice * initialRewardsRate) / 10000;

                console.log("add_rewards", (totalPrice * initialRewardsRate) / 10000);
            } else {
                console.log("aw28");
                uint256 itemsPrice = totalPrice;
                (uint256 year, uint256 month, ) = DateTimeLib.timestampToDate(
                    DateTimeLib.addMonths(_initialTimestamp, i)
                );
                if (i == initialMonths) {
                    itemsPrice = totalPrice - remainder[_itemAddress][_itemId];
                } else if (i == maxLockYears * 12 - 1) {
                    itemsPrice = remainder[_itemAddress][_itemId];
                }
                uint256 _earnings = earnings[year][month];
                if (_earnings == 0) break;

                uint256 _deposits = deposits[year][month];
                rewards_ += (itemsPrice * _earnings) / _deposits;
                // 1000 100 5000

                console.log("_earnings", _earnings);
                console.log("_deposits", _deposits);
                console.log("add_rewards", (itemsPrice * _earnings) / _deposits);
                console.log("itemsPrice", itemsPrice);
            }
            console.log("i", i);
            console.log("total_rewards", rewards_);

            ++expiredPeriods_;
        }

        console.log("aw29");
    }

    function _enforceIsTokenOwner(address _tokenAddress, uint256 _tokenId) internal view {
        require(IERC721(_tokenAddress).ownerOf(_tokenId) == msg.sender, "only token owner!");
    }

    function claim(address _itemAddress, uint256 _itemId, address _withdrawToken) external {
        console.log("aw1");
        _enforceIsTokenOwner(_itemAddress, _itemId);

        console.log("aw12");
        (uint256 rewards, uint256 expiredPeriods) = estimateRewards(_itemAddress, _itemId);
        console.log("rewards", rewards);
        console.log("expiredPeriods", expiredPeriods);
        require(rewards > 0, "rewards!");

        uint256 _lastClaimTimestamp = lastClaimTimestamp[_itemAddress][_itemId];

        lastClaimTimestamp[_itemAddress][_itemId] = DateTimeLib.addMonths(
            _lastClaimTimestamp,
            expiredPeriods
        );

        uint256 withdrawTokenAmount = ITreasury(treasury).usdAmountToToken(rewards, _withdrawToken);
        ITreasury(treasury).withdraw(_withdrawToken, withdrawTokenAmount, msg.sender);
    }

    function sell(address _itemAddress, uint256 _itemId, address _withdrawToken) external {
        _enforceIsTokenOwner(_itemAddress, _itemId);
        console.log("aw3");
        require(canSell(_itemAddress, _itemId), "can't sell!");

        console.log("aw32");
        uint256 sellAmount = estimateSell(_itemAddress, _itemId);

        console.log("aw31");
        delete initialTimestamp[_itemAddress][_itemId];
        delete lastClaimTimestamp[_itemAddress][_itemId];
        delete startSellTimestamp[_itemAddress][_itemId];
        delete finalTimestamp[_itemAddress][_itemId];

        console.log("aw33");
        uint256 withdrawTokenAmount = ITreasury(treasury).usdAmountToToken(
            sellAmount,
            _withdrawToken
        );

        console.log("aw34");
        require(withdrawTokenAmount > 0, "zero amount!");

        console.log("aw35");
        IItem(_itemAddress).burn(_itemId);
        console.log("aw36");
        ITreasury(treasury).withdraw(_withdrawToken, withdrawTokenAmount, msg.sender);
        console.log("aw37");
    }

    function canSell(address _itemAddress, uint256 _itemId) public view returns (bool) {
        uint256 _startSellTimestamp = startSellTimestamp[_itemAddress][_itemId];
        (uint256 rewards, ) = estimateRewards(_itemAddress, _itemId);
        return block.timestamp >= _startSellTimestamp && rewards == 0;
    }

    function estimateSell(address _itemAddress, uint256 _itemId) public view returns (uint256) {
        uint256 _initialTimestamp = initialTimestamp[_itemAddress][_itemId];
        uint256 _finalTimestamp = finalTimestamp[_itemAddress][_itemId];
        uint256 timestamp = block.timestamp;

console.log("timestamp", timestamp);
        if(timestamp > _finalTimestamp) timestamp = _finalTimestamp;
        uint256 allExpiredMonths = DateTimeLib.diffMonths(_initialTimestamp, timestamp);

console.log("_initialTimestamp", _initialTimestamp);
console.log("timestamp", timestamp);
console.log("allExpiredMonths", allExpiredMonths);
console.log("minLockYears * 12", minLockYears * 12);
        if(allExpiredMonths < minLockYears * 12) return 0;

        uint256 maxMonths = maxLockYears * 12;
        if(allExpiredMonths > maxMonths) allExpiredMonths = maxMonths;

        uint256 tokenPrice = IItem(_itemAddress).tokenPrice(_itemId);
        uint256 deprecation = tokenPrice * allExpiredMonths * yearDeprecationRate / 12 / 10000;

        console.log("allExpiredMonths2", allExpiredMonths);
        console.log("tokenPrice", tokenPrice);
        console.log("deprecation", deprecation);
        console.log("tokenPrice - deprecation", tokenPrice - deprecation);

        if(deprecation > tokenPrice) return 0;
        return tokenPrice - deprecation;
    }
}
