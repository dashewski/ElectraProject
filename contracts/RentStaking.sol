// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import { ERC721EnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IPricerToUSD } from "./interfaces/IPricerToUSD.sol";
import { TransferLib } from "./libs/TransferLib.sol";

// import "hardhat/console.sol";

contract RentStaking is
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    ERC721EnumerableUpgradeable
{
    // ------------------------------------------------------------------------------------
    // ----- CONSTANTS --------------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    uint256 public constant REWARS_PERIOD = 30 days;
    uint256 public constant PERCENT_PRECISION = 100;
    address public constant BNB_PLACEHOLDER = address(0);

    // ------------------------------------------------------------------------------------
    // ----- STORAGE ----------------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    mapping(uint256 => string) public items;
    mapping(string => uint256) public itemsIndexes;
    uint256 public itemsLength;
    mapping(string => uint256) public itemsPrices;

    mapping(uint256 => uint256) public lockPeriods;
    mapping(uint256 => uint256) public lockPeriodsIndexes;
    uint256 public lockPeriodsLength;
    mapping(uint256 => uint256) public lockPeriodsRewardRates;

    mapping(uint256 => address) public supportedTokens;
    mapping(address => uint256) public supportedTokensIndexes;
    uint256 public supportedTokensLength;
    mapping(address => address) public pricers;

    uint256 public nextTokenId;

    mapping(uint256 => TokenInfo) public tokensInfo;

    address[] public tokensToOwnerWithdraw;
    mapping(address => uint256) public tokensToOwnerWithdrawBalances;

    address[] public tokensToUserWithdraw;
    mapping(address => uint256) public tokensToUserWithdrawBalances;

    // ------------------------------------------------------------------------------------
    // ----- STRUCTURES -------------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    struct TokenInfo {
        string itemName;
        uint256 lockPeriod;
        uint256 rewardsRate;
        uint256 buyPrice;
        uint256 sellPrice;
        uint256 initTimestamp;
        uint256 lastRewardTimestamp;
        uint256 withdrawnRewards;
        uint256 allPeriodsCount;
        uint256 claimedPeriodsCount;
        uint256 rewarsForOnePeriod;
    }

    struct Item {
        string name;
        uint256 price;
    }

    struct LockPeriod {
        uint256 lockTime;
        uint256 rewardsRate;
    }

    struct SupportedToken {
        address token;
        address pricer;
    }

    // ------------------------------------------------------------------------------------
    // ----- EVENTS -----------------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    event Buy(
        address indexed recipient,
        uint256 indexed tokenId,
        address indexed tokenForPay,
        uint256 tokenAmount
    );

    event ClaimRewards(
        address indexed recipient,
        uint256 indexed tokenId,
        uint256 rewardsByUsd,
        uint256 rewardsByToken
    );

    event Sell(address indexed recipient, uint256 indexed tokenId);

    event ReStake(address indexed recipient, uint256 indexed tokenId);

    event AddItem(string indexed name, uint256 price);
    event UpdateItemPrice(string indexed name, uint256 oldPrice, uint256 newPrice);
    event DeleteItem(string indexed name);

    event AddToken(address token, address pricer);
    event UpdateTokenPricer(address token, address oldPricer, address newPricer);
    event DeleteToken(address token);

    event AddLockPeriod(uint256 lockPeriod, uint256 rewardsRate);
    event UpdateLockPeriodRewardsRate(
        uint256 lockPeriod,
        uint256 oldRewardsRate,
        uint256 newRewardsRate
    );
    event DeleteLockPeriod(uint256 lockPeriod);

    event Deposit(address indexed token, uint256 amount);

    event Withdraw(address indexed token, uint256 amount);

    // ------------------------------------------------------------------------------------
    // ----- CONTRACT INITIALIZE ----------------------------------------------------------
    // ------------------------------------------------------------------------------------

    function initialize(
        string calldata _nftName,
        string calldata _nftSymbol,
        Item[] calldata _items,
        LockPeriod[] calldata _lockPerios,
        SupportedToken[] calldata _supportedTokens
    ) public initializer {
        // Init extends
        __ReentrancyGuard_init();
        __Ownable_init();
        __ERC721_init(_nftName, _nftSymbol);

        // Init items
        uint256 l = _items.length;
        for (uint256 i; i < l; i++) {
            addItem(_items[i].name, _items[i].price);
        }

        // Init periods
        uint256 l2 = _lockPerios.length;
        for (uint256 i; i < l2; i++) {
            addLockPeriod(_lockPerios[i].lockTime, _lockPerios[i].rewardsRate);
        }

        // Init supported tokens
        uint256 l3 = _supportedTokens.length;
        for (uint256 i; i < l3; i++) {
            addToken(_supportedTokens[i].token, _supportedTokens[i].pricer);
        }
    }

    // ------------------------------------------------------------------------------------
    // ----- USER ACTIONS -----------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    function buy(
        string calldata _itemName,
        uint256 _lockPeriod,
        address _tokenForPay
    ) external payable nonReentrant {
        uint256 itemPrice = itemsPrices[_itemName];
        require(itemPrice > 0, "RentStaking: item not exists!");

        uint256 rewardsRate = lockPeriodsRewardRates[_lockPeriod];
        require(rewardsRate > 0, "RentStaking: lockPeriod not exists!");

        uint256 tokenAmount = getBuyPriceByToken(_itemName, _tokenForPay);
        require(_getInputAmount(_tokenForPay) >= tokenAmount, "RentStaking: not enough funds!");

        // ~ 38 000 gas
        TransferLib.transferFrom(_tokenForPay, tokenAmount, msg.sender, address(this));

        tokensToOwnerWithdrawBalances[_tokenForPay] += tokenAmount;

        uint256 sellPrice = calculateSellPrice(itemPrice);

        uint256 tokenId = nextTokenId++;

        uint256 rewardForOnePeriod = (itemPrice * rewardsRate) / PERCENT_PRECISION;
        // ~ 70 000 gas
        _safeMint(msg.sender, tokenId);
        // ~ 160 000 gas
        tokensInfo[tokenId] = TokenInfo({
            itemName: _itemName,
            lockPeriod: _lockPeriod,
            rewardsRate: rewardsRate,
            buyPrice: itemPrice,
            sellPrice: sellPrice,
            initTimestamp: block.timestamp,
            lastRewardTimestamp: block.timestamp,
            withdrawnRewards: 0,
            allPeriodsCount: _lockPeriod * 12,
            claimedPeriodsCount: 0,
            rewarsForOnePeriod: rewardForOnePeriod
        });

        emit Buy(msg.sender, tokenId, _tokenForPay, tokenAmount);
    }

    function claimRewards(uint256 _tokenId, address _tokenToWithdrawn) public nonReentrant {
        _enforseIsTokenOwner(_tokenId);

        uint256 rewardsByUsd = rewardsToWithdrawByUSD(_tokenId);
        require(rewardsByUsd > 0, "RentStaking: no usd rewards to withdraw!");

        uint256 rewardsByToken = rewardsToWithdrawByToken(_tokenId, _tokenToWithdrawn);
        require(rewardsByToken > 0, "RentStaking: no token rewards to withdraw!");

        require(
            tokensToUserWithdrawBalances[_tokenToWithdrawn] >= rewardsByToken,
            "RentStaking: insufficient funds to claim!"
        );

        TransferLib.transfer(_tokenToWithdrawn, rewardsByToken, msg.sender);

        tokensToUserWithdrawBalances[_tokenToWithdrawn] -= rewardsByToken;
        tokensInfo[_tokenId].withdrawnRewards += rewardsByUsd;
        tokensInfo[_tokenId].lastRewardTimestamp =
            tokensInfo[_tokenId].initTimestamp +
            calcaluteAllRewardsPeriodsCount(_tokenId) *
            REWARS_PERIOD;

        emit ClaimRewards(msg.sender, _tokenId, rewardsByUsd, rewardsByToken);
    }

    function sell(uint256 _tokenId, address _tokenToWithdrawn) external nonReentrant {
        _enforseIsTokenOwner(_tokenId);

        require(lockPeriodIsExpired(_tokenId), "RentStaking: blocking period has not expired!");

        require(rewardsToWithdrawByUSD(_tokenId) == 0, "RentStaking: claim rewards before sell!");

        uint256 tokenAmountToWitdrawn = getSellAmoutByToken(_tokenId, _tokenToWithdrawn);

        require(tokenAmountToWitdrawn > 0, "RentStaking: not enough funds to sell!");

        require(
            tokensToUserWithdrawBalances[_tokenToWithdrawn] >= tokenAmountToWitdrawn,
            "RentStaking: insufficient funds!"
        );

        TransferLib.transfer(_tokenToWithdrawn, tokenAmountToWitdrawn, msg.sender);

        tokensToUserWithdrawBalances[_tokenToWithdrawn] -= tokenAmountToWitdrawn;

        _burn(_tokenId);

        emit Sell(msg.sender, _tokenId);
    }

    function reStake(uint256 _tokenId, uint256 _lockPeriod) external nonReentrant {
        _enforseIsTokenOwner(_tokenId);

        require(lockPeriodIsExpired(_tokenId), "RentStaking: blocking period has not expired!");

        require(rewardsToWithdrawByUSD(_tokenId) == 0, "RentStaking: claim rewards before sell!");

        uint256 rewardsRate = lockPeriods[_lockPeriod];
        require(rewardsRate > 0, "RentStaking: lockPeriod not exists!");

        TokenInfo storage tokenInfo = tokensInfo[_tokenId];

        uint256 sellPrice = calculateSellPrice(tokenInfo.sellPrice);

        tokenInfo.lockPeriod = _lockPeriod;
        tokenInfo.rewardsRate = rewardsRate;
        tokenInfo.buyPrice = tokenInfo.sellPrice;
        tokenInfo.sellPrice = sellPrice;
        tokenInfo.initTimestamp = block.timestamp;
        tokenInfo.lastRewardTimestamp = block.timestamp;
        tokenInfo.withdrawnRewards = 0;

        emit ReStake(msg.sender, _tokenId);
    }

    // ------------------------------------------------------------------------------------
    // ----- VIEW STATE -------------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    function calculateDepositAmount(
        uint256 _timestamp,
        uint256 _startTokenIndex,
        uint256 _endTokenIndex
    ) external view returns (uint256) {
        uint256 amount;
        for (uint256 i = _startTokenIndex; i < _endTokenIndex; i++) {
            uint256 tokenId = tokenByIndex(i);
            TokenInfo storage tokenInfo = tokensInfo[tokenId];

            uint256 periodsCount = (_timestamp - tokenInfo.initTimestamp) / REWARS_PERIOD;
            uint256 rewardsForOnePeriod = calculateRewarsForOnePeriodUSD(tokenId);
            uint256 rewards = periodsCount * rewardsForOnePeriod - tokenInfo.withdrawnRewards;

            amount += rewards;
            if (lockPeriodIsExpired(tokenId)) {
                amount += tokenInfo.sellPrice;
            }
        }
        return amount;
    }

    function getItems(
        uint256 _startIndex,
        uint256 _endIndex
    ) external view returns (string[] memory) {
        require(_startIndex < itemsLength, "Rent staking: start index out of bounds!");
        if (_endIndex > itemsLength) {
            _endIndex = itemsLength;
        }
        uint256 length = _endIndex - _startIndex;
        string[] memory result = new string[](length);
        uint256 index;
        for (uint256 i = _startIndex; i < _endIndex; i++) {
            result[index++] = items[i];
        }
        return result;
    }

    function getItemsWithPrice(
        uint256 _startIndex,
        uint256 _endIndex
    ) external view returns (Item[] memory) {
        require(_startIndex < itemsLength, "Rent staking: start index out of bounds!");
        if (_endIndex > itemsLength) {
            _endIndex = itemsLength;
        }
        uint256 length = _endIndex - _startIndex;
        Item[] memory result = new Item[](length);
        uint256 index;
        for (uint256 i = _startIndex; i < _endIndex; i++) {
            result[index++] = Item({ name: items[i], price: itemsPrices[items[i]] });
        }
        return result;
    }

    function getLockPeriods(
        uint256 _startIndex,
        uint256 _endIndex
    ) external view returns (uint256[] memory) {
        require(_startIndex < lockPeriodsLength, "Rent staking: start index out of bounds!");
        if (_endIndex > lockPeriodsLength) {
            _endIndex = lockPeriodsLength;
        }
        uint256 length = _endIndex - _startIndex;
        uint256[] memory result = new uint256[](length);
        uint256 index;
        for (uint256 i = _startIndex; i < _endIndex; i++) {
            result[index++] = lockPeriods[i];
        }
        return result;
    }

    function getLockPeriodsWithRewardsRates(
        uint256 _startIndex,
        uint256 _endIndex
    ) external view returns (LockPeriod[] memory) {
        require(_startIndex < lockPeriodsLength, "Rent staking: start index out of bounds!");
        if (_endIndex > lockPeriodsLength) {
            _endIndex = lockPeriodsLength;
        }
        uint256 length = _endIndex - _startIndex;
        LockPeriod[] memory result = new LockPeriod[](length);
        uint256 index;
        for (uint256 i = _startIndex; i < _endIndex; i++) {
            result[index++] = LockPeriod({
                lockTime: lockPeriods[i],
                rewardsRate: lockPeriodsRewardRates[lockPeriods[i]]
            });
        }
        return result;
    }

    function getSupportedTokens(
        uint256 _startIndex,
        uint256 _endIndex
    ) external view returns (address[] memory) {
        require(_startIndex < supportedTokensLength, "Rent staking: start index out of bounds!");
        if (_endIndex > supportedTokensLength) {
            _endIndex = supportedTokensLength;
        }
        uint256 length = _endIndex - _startIndex;
        address[] memory result = new address[](length);
        uint256 index;
        for (uint256 i = _startIndex; i < _endIndex; i++) {
            result[index++] = supportedTokens[i];
        }
        return result;
    }

    function getSupportedTokensWithPricers(
        uint256 _startIndex,
        uint256 _endIndex
    ) external view returns (SupportedToken[] memory) {
        require(_startIndex < supportedTokensLength, "Rent staking: start index out of bounds!");
        if (_endIndex > supportedTokensLength) {
            _endIndex = supportedTokensLength;
        }
        uint256 length = _endIndex - _startIndex;
        SupportedToken[] memory result = new SupportedToken[](length);
        uint256 index;
        for (uint256 i = _startIndex; i < _endIndex; i++) {
            result[index++] = SupportedToken({
                token: supportedTokens[i],
                pricer: pricers[supportedTokens[i]]
            });
        }
        return result;
    }

    function isItemExists(string calldata _itemName) external view returns (bool) {
        return itemsPrices[_itemName] != 0;
    }

    function isLockPeriodExists(uint256 _lockPeriod) external view returns (bool) {
        return lockPeriodsRewardRates[_lockPeriod] != 0;
    }

    function isSupportedToken(address _token) external view returns (bool) {
        return pricers[_token] != address(0);
    }

    function calculateSellPrice(uint256 _price) public view returns (uint256) {
        return (_price * 9) / 10;
    }

    function getTokenPriceUSD(address _token) public view returns (uint256) {
        address pricerAddress = pricers[_token];
        require(pricerAddress != address(0), "RentStaking: token not registered!");
        IPricerToUSD pricer = IPricerToUSD(pricerAddress);
        (, int256 tokenPrice, , , ) = pricer.latestRoundData();
        uint256 price = uint256(tokenPrice);
        require(price > 0, "RentStaking: price from pricer can not be zero!");
        return price;
    }

    function getBuyPriceByUSD(string calldata _itemName) public view returns (uint256) {
        uint256 itemPrice = itemsPrices[_itemName];
        require(itemPrice > 0, "RentStaking: item not exists!");
        return itemPrice;
    }

    function getBuyPriceByToken(
        string calldata _itemName,
        address _tokenForPay
    ) public view returns (uint256) {
        uint256 priceByUSD = getBuyPriceByUSD(_itemName);
        uint256 tokenAmount = usdAmountToToken(priceByUSD, _tokenForPay);
        require(tokenAmount > 0, "RentStaking: token amount can not be zero!");
        return tokenAmount;
    }

    function usdAmountToToken(uint256 _usdAmount, address _token) public view returns (uint256) {
        uint256 decimals = _token == BNB_PLACEHOLDER ? 18 : IERC20Metadata(_token).decimals();
        return (_usdAmount * 10 ** decimals * getTokenPriceUSD(_token)) / 1e8;
    }

    function calculateRewarsForOnePeriodUSD(uint256 _tokenId) public view returns (uint256) {
        TokenInfo memory tokenInfo = tokensInfo[_tokenId];
        uint256 rewardForOnePeriod = (tokenInfo.buyPrice * tokenInfo.rewardsRate) /
            PERCENT_PRECISION;
        return rewardForOnePeriod;
    }

    function calcaluteAllRewardsPeriodsCount(uint256 _tokenId) public view returns (uint256) {
        TokenInfo memory tokenInfo = tokensInfo[_tokenId];
        return (block.timestamp - tokenInfo.initTimestamp) / REWARS_PERIOD;
    }

    function calculateAllRewardsByUSD(uint256 _tokenId) public view returns (uint256) {
        return calcaluteAllRewardsPeriodsCount(_tokenId) * calculateRewarsForOnePeriodUSD(_tokenId);
    }

    function rewardsToWithdrawByUSD(uint256 _tokenId) public view returns (uint256) {
        return calculateAllRewardsByUSD(_tokenId) - tokensInfo[_tokenId].withdrawnRewards;
    }

    function rewardsToWithdrawByToken(
        uint256 _tokenId,
        address _tokenToWithdrawn
    ) public view returns (uint256) {
        return usdAmountToToken(rewardsToWithdrawByUSD(_tokenId), _tokenToWithdrawn);
    }

    function lockPeriodIsExpired(uint256 _tokenId) public view returns (bool) {
        return block.timestamp >= getExpiredTimestamp(_tokenId);
    }

    function getExpiredTimestamp(uint256 _tokenId) public view returns (uint256) {
        TokenInfo memory tokenInfo = tokensInfo[_tokenId];
        return tokenInfo.initTimestamp + tokenInfo.lockPeriod * 365 days;
    }

    function getNextRewardTimestamp(uint256 _tokenId) external view returns (uint256) {
        return tokensInfo[_tokenId].lastRewardTimestamp + REWARS_PERIOD;
    }

    function getSellAmoutByUSD(uint256 _tokenId) public view returns (uint256) {
        return tokensInfo[_tokenId].sellPrice;
    }

    function getSellAmoutByToken(
        uint256 _tokenId,
        address _tokenToWithdrawn
    ) public view returns (uint256) {
        return usdAmountToToken(getSellAmoutByUSD(_tokenId), _tokenToWithdrawn);
    }

    function hasRewards(uint256 _tokenId) public view returns (bool) {
        uint256 rewardsByUsd = rewardsToWithdrawByUSD(_tokenId);
        return rewardsByUsd > 0;
    }

    function hasRewardsByToken(
        uint256 _tokenId,
        address _tokenToWithdrawn
    ) public view returns (bool) {
        uint256 rewardsByToken = rewardsToWithdrawByToken(_tokenId, _tokenToWithdrawn);
        return rewardsByToken > 0;
    }

    function hasBalanceToClaim(
        uint256 _tokenId,
        address _tokenToWithdrawn
    ) public view returns (bool) {
        uint256 rewardsByToken = rewardsToWithdrawByToken(_tokenId, _tokenToWithdrawn);
        return tokensToUserWithdrawBalances[_tokenToWithdrawn] >= rewardsByToken;
    }

    function canClaim(uint256 _tokenId, address _tokenToWithdrawn) external view returns (bool) {
        return
            hasRewardsByToken(_tokenId, _tokenToWithdrawn) &&
            hasBalanceToClaim(_tokenId, _tokenToWithdrawn);
    }

    function hasBalanceToSell(
        uint256 _tokenId,
        address _tokenToWithdrawn
    ) public view returns (bool) {
        uint256 tokenAmountToWitdrawn = getSellAmoutByToken(_tokenId, _tokenToWithdrawn);
        return tokensToUserWithdrawBalances[_tokenToWithdrawn] >= tokenAmountToWitdrawn;
    }

    function canSell(uint256 _tokenId, address _tokenToWithdrawn) external view returns (bool) {
        return
            lockPeriodIsExpired(_tokenId) &&
            !hasRewards(_tokenId) &&
            hasBalanceToSell(_tokenId, _tokenToWithdrawn);
    }

    function canReStake(uint256 _tokenId) external view returns (bool) {
        return lockPeriodIsExpired(_tokenId) && !hasRewards(_tokenId);
    }

    // // ------------------------------------------------------------------------------------
    // // ----- OWNER ACTIONS ----------------------------------------------------------------
    // // ------------------------------------------------------------------------------------

    function deposit(address _token, uint256 _amount) external payable onlyOwner {
        require(pricers[_token] != address(0), "RentStaking: can't deposit unsupported token!");

        TransferLib.transferFrom(_token, _amount, msg.sender, address(this));

        tokensToUserWithdrawBalances[_token] += _amount;

        emit Deposit(_token, _amount);
    }

    function withdraw(address _token, uint256 _amount) public payable onlyOwner {
        require(
            tokensToOwnerWithdrawBalances[_token] >= _amount,
            "RentStaking: insufficient funds!"
        );

        TransferLib.transfer(_token, _amount, msg.sender);

        tokensToOwnerWithdrawBalances[_token] -= _amount;

        emit Withdraw(_token, _amount);
    }

    function addItem(string calldata _name, uint256 _price) public onlyOwner {
        require(itemsPrices[_name] == 0, "RentStaking: item already exists!");
        itemsPrices[_name] = _price;
        items[itemsLength] = _name;
        itemsIndexes[_name] = itemsLength;
        itemsLength++;

        emit AddItem(_name, _price);
    }

    function updateItemPrice(string calldata _name, uint256 _price) external onlyOwner {
        require(_price > 0, "RentStaking: can not set price 0, use deleteItem");
        uint256 oldItemPrice = itemsPrices[_name];
        require(oldItemPrice > 0, "RentStaking: item not exists!");
        itemsPrices[_name] = _price;

        emit UpdateItemPrice(_name, oldItemPrice, _price);
    }

    function deleteItem(string calldata _name) external onlyOwner {
        require(itemsPrices[_name] > 0, "RentStaking: item not exists!");
        delete itemsPrices[_name];

        // Delete from array
        uint256 index = itemsIndexes[_name];
        uint256 lastIndex = --itemsLength;
        if (index != lastIndex) {
            string memory lastItem = items[lastIndex];
            items[index] = lastItem;
            itemsIndexes[lastItem] = index;
        }
        delete items[lastIndex];
        delete itemsIndexes[_name];

        emit DeleteItem(_name);
    }

    function addLockPeriod(uint256 _lockTime, uint256 _rewardsRate) public onlyOwner {
        require(lockPeriodsRewardRates[_lockTime] == 0, "RentStaking: lock period already exists!");
        lockPeriodsRewardRates[_lockTime] = _rewardsRate;
        lockPeriods[lockPeriodsLength] = _lockTime;
        lockPeriodsIndexes[_lockTime] = lockPeriodsLength;
        supportedTokensLength++;

        emit AddLockPeriod(_lockTime, _rewardsRate);
    }

    function updateLockPeriodRewardsRate(
        uint256 _lockTime,
        uint256 _rewardsRate
    ) external onlyOwner {
        require(_rewardsRate > 0, "RentStaking: can not set rewards rate to 0, use deleteItem");
        uint256 oldRewardsRate = lockPeriodsRewardRates[_lockTime];
        require(oldRewardsRate > 0, "RentStaking: item not exists!");

        lockPeriodsRewardRates[_lockTime] = _rewardsRate;

        emit UpdateLockPeriodRewardsRate(_lockTime, oldRewardsRate, _rewardsRate);
    }

    function deleteLockPeriod(uint256 _lockTime) external onlyOwner {
        require(lockPeriodsRewardRates[_lockTime] > 0, "RentStaking: lock period not exists!");
        delete lockPeriodsRewardRates[_lockTime];

        // Delete from array
        uint256 index = lockPeriodsIndexes[_lockTime];
        uint256 lastIndex = --lockPeriodsLength;
        if (index != lastIndex) {
            uint256 lastLockPeriod = lockPeriods[lastIndex];
            lockPeriods[index] = lastLockPeriod;
            lockPeriodsIndexes[lastLockPeriod] = index;
        }
        delete lockPeriods[lastIndex];
        delete lockPeriodsIndexes[_lockTime];

        emit DeleteLockPeriod(_lockTime);
    }

    function addToken(address _token, address _pricer) public onlyOwner {
        require(pricers[_token] == address(0), "RentStaking: token already exists!");
        _enforceUsdPriserDecimals(_pricer);
        pricers[_token] = _pricer;        
        supportedTokens[supportedTokensLength] = _token;
        supportedTokensIndexes[_token] = lockPeriodsLength;
        supportedTokensLength++;

        emit AddToken(_token, _pricer);
    }

    function updateTokenPricer(address _token, address _pricer) external onlyOwner {
        address oldPricer = pricers[_token];
        require(oldPricer != address(0), "RentStaking: token not exists!");
        _enforceUsdPriserDecimals(_pricer);
        pricers[_token] = _pricer;

        emit UpdateTokenPricer(_token, oldPricer, _pricer);
    }

    function deleteToken(address _token) external onlyOwner {
        require(pricers[_token] != address(0), "RentStaking: token not exists!");

        // Witdraw before
        uint256 ownerBalance = tokensToOwnerWithdrawBalances[_token];
        uint256 userBalance = tokensToUserWithdrawBalances[_token];
        uint256 allBalance = ownerBalance + userBalance;
        if (allBalance > 0) {
            withdraw(_token, allBalance);
        }

        // Delete pricer
        delete pricers[_token];

        // Delete from array
        uint256 index = supportedTokensIndexes[_token];
        uint256 lastIndex = --supportedTokensLength;
        if (index != lastIndex) {
            address lastToken = supportedTokens[lastIndex];
            supportedTokens[index] = lastToken;
            supportedTokensIndexes[lastToken] = index;
        }
        delete supportedTokens[lastIndex];
        delete supportedTokensIndexes[_token];

        emit DeleteToken(_token);
    }

    // // ------------------------------------------------------------------------------------
    // // ----- INTERNAL METHODS -------------------------------------------------------------
    // // ------------------------------------------------------------------------------------

    function _enforseIsTokenOwner(uint256 _tokenId) internal view {
        require(ownerOf(_tokenId) == msg.sender, "RentStaking: not token owner!");
    }

    function _enforceUsdPriserDecimals(address _pricer) internal view {
        require(
            IPricerToUSD(_pricer).decimals() == 8,
            "RentStaking: usd pricer must be with decimal equal to 8!"
        );
    }

    function _getInputAmount(address _token) internal view returns (uint256) {
        if (_token == BNB_PLACEHOLDER) {
            return msg.value;
        } else {
            return IERC20Metadata(_token).allowance(msg.sender, address(this));
        }
    }
}
