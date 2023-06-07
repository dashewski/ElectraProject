// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import { ERC721EnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IPricerToUSD } from "./interfaces/IPricerToUSD.sol";

contract RentStaking is
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    ERC721EnumerableUpgradeable
{
    // ------------------------------------------------------------------------------------
    // ----- CONSTANTS --------------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    uint256 public constant REWARS_PERIOD = 30 days;
    uint256 public constant PERCENT_PRECISION = 10000;
    address public constant BNB_PLACEHOLDER = address(0);

    // ------------------------------------------------------------------------------------
    // ----- STORAGE ----------------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    string[] public items;
    mapping(string => uint256) public itemsPrices;

    uint256[] public lockPeriods;
    mapping(uint256 => uint256) public lockPeriodsRewardRates;

    uint256 public nextTokenId;

    address[] public supportedTokens;
    mapping(address => address) public pricers;

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
        uint256 withdrawnRewards;
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

    event Buy(address indexed recipient, uint256 indexed tokenId);
    event ClaimRewards(
        address indexed recipient,
        uint256 indexed tokenId,
        uint256 rewardsByUsd,
        uint256 rewardsByToken
    );
    event Sell(address indexed recipient, uint256 indexed tokenId);

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

        uint256 rewardsRate = lockPeriods[_lockPeriod];
        require(rewardsRate > 0, "RentStaking: lockPeriod not exists!");

        uint256 tokenAmount = getBuyPriceByToken(_itemName, _tokenForPay);

        // Trasfer token for pay
        if (_tokenForPay == BNB_PLACEHOLDER) {
            // BNB
            require(msg.value >= tokenAmount, "RentStaking: an insufficient amount bnb for pay!");
            uint256 change = msg.value - tokenAmount;
            if (change > 0) {
                (bool success, ) = msg.sender.call{ value: change }("");
                require(success, "RentStaking: failed transfer change!");
            }
        } else {
            // ERC20
            IERC20Metadata tokenForPay = IERC20Metadata(_tokenForPay);
            uint256 tokenBalanceBefore = tokenForPay.balanceOf(address(this));
            tokenForPay.transferFrom(msg.sender, address(this), tokenAmount);
            uint256 tokenBalanceAfter = tokenForPay.balanceOf(address(this));
            require(
                tokenBalanceAfter - tokenBalanceBefore == tokenAmount,
                "RentStaking: failed transfer token for pay!"
            );
        }

        tokensToOwnerWithdrawBalances[_tokenForPay] += tokenAmount;

        uint256 sellPrice = (itemPrice * 9) / 10;

        uint256 tokenId = nextTokenId++;
        _safeMint(msg.sender, tokenId);
        tokensInfo[tokenId] = TokenInfo({
            itemName: _itemName,
            lockPeriod: _lockPeriod,
            rewardsRate: rewardsRate,
            buyPrice: itemPrice,
            sellPrice: sellPrice,
            initTimestamp: block.timestamp,
            withdrawnRewards: 0
        });

        emit Buy(msg.sender, tokenId);
    }

    function claimRewards(uint256 _tokenId, address _tokenToWithdrawn) public nonReentrant {
        _enforseIsTokenOwner(_tokenId);

        uint256 rewardsByUsd = rewardsToWithdrawByUSD(_tokenId);
        require(rewardsByUsd > 0, "RentStaking: no usd rewards to withdraw!");

        uint256 rewardsByToken = rewardsToWithdrawByToken(_tokenId, _tokenToWithdrawn);
        require(rewardsByToken > 0, "RentStaking: no token rewards to withdraw!");

        require(
            tokensToUserWithdrawBalances[_tokenToWithdrawn] >= rewardsByToken,
            "RentStaking: insufficient funds!"
        );

        if (_tokenToWithdrawn == BNB_PLACEHOLDER) {
            // BNB
            (bool success, ) = msg.sender.call{ value: rewardsByToken }("");
            require(success, "RentStaking: failed transfer bnb rewards!");
        } else {
            // ERC20
            IERC20Metadata tokenToWithdrawn = IERC20Metadata(_tokenToWithdrawn);
            tokenToWithdrawn.transfer(msg.sender, rewardsByToken);
        }

        tokensToUserWithdrawBalances[_tokenToWithdrawn] -= rewardsByToken;
        tokensInfo[_tokenId].withdrawnRewards += rewardsByUsd;

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

        if (_tokenToWithdrawn == BNB_PLACEHOLDER) {
            // BNB
            (bool success, ) = msg.sender.call{ value: tokenAmountToWitdrawn }("");
            require(success, "RentStaking: failed transfer of bnb for sale!");
        } else {
            // ERC20
            IERC20Metadata tokenToWithdrawn = IERC20Metadata(_tokenToWithdrawn);
            tokenToWithdrawn.transfer(msg.sender, tokenAmountToWitdrawn);
        }

        tokensToUserWithdrawBalances[_tokenToWithdrawn] -= tokenAmountToWitdrawn;

        _burn(_tokenId);

        emit Sell(msg.sender, _tokenId);
    }

    // ------------------------------------------------------------------------------------
    // ----- VIEW STATE -------------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    function getItems() external view returns (string[] memory) {
        return items;
    }

    function getItemsWithPrice() external view returns (Item[] memory) {
        Item[] memory result = new Item[](items.length);
        uint256 l = items.length;
        for (uint256 i; i < l; i++) {
            result[i] = Item({ name: items[i], price: itemsPrices[items[i]] });
        }
        return result;
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    function getSupportedTokensWithPricers() external view returns (SupportedToken[] memory) {
        SupportedToken[] memory result = new SupportedToken[](supportedTokens.length);
        uint256 l = supportedTokens.length;
        for (uint256 i; i < l; i++) {
            result[i] = SupportedToken({
                token: supportedTokens[i],
                pricer: pricers[supportedTokens[i]]
            });
        }
        return result;
    }

    function getLockPeriods() external view returns (uint256[] memory) {
        return lockPeriods;
    }

    function getLockPeriodsWithRewardsRates() external view returns (LockPeriod[] memory) {
        LockPeriod[] memory result = new LockPeriod[](lockPeriods.length);
        uint256 l = lockPeriods.length;
        for (uint256 i; i < l; i++) {
            result[i] = LockPeriod({
                lockTime: lockPeriods[i],
                rewardsRate: lockPeriodsRewardRates[lockPeriods[i]]
            });
        }
        return result;
    }

    function getTokenPriceUSD(address _token) public view returns (uint256) {
        address pricerAddress = pricers[_token];
        require(pricerAddress != address(0), "RentStaking: token not registered!");
        IPricerToUSD pricer = IPricerToUSD(pricerAddress);
        (, int256 tokenPrice, , , ) = pricer.latestRoundData();
        uint256 price = uint256(tokenPrice);
        require(price > 0, "RentStaking: price can not be zero!");
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
        uint256 toknePriceUSD = getTokenPriceUSD(_tokenForPay);
        uint256 tokenAmount = (priceByUSD *
            10 ** IERC20Metadata(_tokenForPay).decimals() *
            toknePriceUSD) / 1e8;
        require(tokenAmount > 0, "RentStaking: token amount can not be zero!");
        return tokenAmount;
    }

    function rewardsToWithdrawByUSD(uint256 _tokenId) public view returns (uint256) {
        TokenInfo memory tokenInfo = tokensInfo[_tokenId];
        uint256 rewardsPeriodsCount = (block.timestamp - tokenInfo.initTimestamp) / REWARS_PERIOD;
        uint256 rewardForOnePeriod = (tokenInfo.buyPrice * tokenInfo.rewardsRate) /
            PERCENT_PRECISION;
        uint256 allCurrentRewards = rewardsPeriodsCount * rewardForOnePeriod;
        uint256 rewardsThatCanBeWithdrawn = allCurrentRewards - tokenInfo.withdrawnRewards;
        return rewardsThatCanBeWithdrawn;
    }

    function rewardsToWithdrawByToken(
        uint256 _tokenId,
        address _tokenToWithdrawn
    ) public view returns (uint256) {
        return
            (rewardsToWithdrawByUSD(_tokenId) *
                10 ** IERC20Metadata(_tokenToWithdrawn).decimals() *
                getTokenPriceUSD(_tokenToWithdrawn)) / 1e8;
    }

    function lockPeriodIsExpired(uint256 _tokenId) public view returns (bool) {
        TokenInfo memory tokenInfo = tokensInfo[_tokenId];
        return block.timestamp >= tokenInfo.initTimestamp + tokenInfo.lockPeriod * 365 days;
    }

    function getSellAmoutByUSD(uint256 _tokenId) public view returns (uint256) {
        return tokensInfo[_tokenId].sellPrice;
    }

    function getSellAmoutByToken(
        uint256 _tokenId,
        address _tokenToWithdrawn
    ) public view returns (uint256) {
        return
            (getSellAmoutByUSD(_tokenId) *
                10 ** IERC20Metadata(_tokenToWithdrawn).decimals() *
                getTokenPriceUSD(_tokenToWithdrawn)) / 1e8;
    }

    // ------------------------------------------------------------------------------------
    // ----- OWNER ACTIONS ----------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    function deposit(address _token, uint256 _amount) external payable onlyOwner {
        require(pricers[_token] != address(0), "RentStaking: can't deposit unsupported token!");

        if (_token == BNB_PLACEHOLDER) {
            // BNB
            require(msg.value == _amount, "RentStaking: msg.value not equal amount!");
        } else {
            // ERC20
            IERC20Metadata(_token).transferFrom(msg.sender, address(this), _amount);
        }

        tokensToUserWithdrawBalances[_token] += _amount;

        emit Deposit(_token, _amount);
    }

    function withdraw(address _token, uint256 _amount) public payable onlyOwner {
        require(tokensToOwnerWithdrawBalances[_token] >= _amount, "RentStaking: insufficient funds!");

        if (_token == BNB_PLACEHOLDER) {
            // BNB
            (bool success, ) = msg.sender.call{ value: _amount }("");
            require(success, "RentStaking: failed transfer bnb rewards!");
        } else {
            // ERC20
            IERC20Metadata(_token).transfer(msg.sender, _amount);
        }

        tokensToOwnerWithdrawBalances[_token] -= _amount;

        emit Withdraw(_token, _amount);
    }

    function addItem(string calldata _name, uint256 _price) public onlyOwner {
        require(itemsPrices[_name] == 0, "RentStaking: item already exists!");
        itemsPrices[_name] = _price;
        items.push(_name);

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
        uint256 index = _getItemIndex(_name);
        uint256 maxIndex = items.length - 1;
        for(uint256 i = index; i < maxIndex; i++) {
            items[i] = items[i + 1];
        }
        items.pop();

        emit DeleteItem(_name);
    }

    function addLockPeriod(uint256 _lockTime, uint256 _rewardsRate) public onlyOwner {
        require(lockPeriodsRewardRates[_lockTime] == 0, "RentStaking: lock period already exists!");
        lockPeriodsRewardRates[_lockTime] = _rewardsRate;
        lockPeriods.push(_lockTime);

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
        uint256 index = _getLockPeriodIndex(_lockTime);
        uint256 maxIndex = lockPeriods.length - 1;
        for(uint256 i = index; i < maxIndex; i++) {
            lockPeriods[i] = lockPeriods[i + 1];
        }
        lockPeriods.pop();

        emit DeleteLockPeriod(_lockTime);
    }

    function addToken(address _token, address _pricer) public onlyOwner {
        require(pricers[_token] == address(0), "RentStaking: token already exists!");
        _enforceUsdPriserDecimals(_pricer);
        pricers[_token] = _pricer;
        supportedTokens.push(_token);

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
        if(allBalance > 0) {
            withdraw(_token, allBalance);
        }

        // Delete pricer
        delete pricers[_token];
        // Delete from array
        uint256 index = _getTokenIndex(_token);
        uint256 maxIndex = supportedTokens.length - 1;
        for(uint256 i = index; i < maxIndex; i++) {
            supportedTokens[i] = supportedTokens[i + 1];
        }
        supportedTokens.pop();

        emit DeleteToken(_token);
    }

    // ------------------------------------------------------------------------------------
    // ----- INTERNAL METHODS -------------------------------------------------------------
    // ------------------------------------------------------------------------------------

    function _enforseIsTokenOwner(uint256 _tokenId) internal view {
        require(ownerOf(_tokenId) == msg.sender, "RentStaking: not token owner!");
    }

    function _enforceUsdPriserDecimals(address _pricer) internal view {
        require(
            IPricerToUSD(_pricer).decimals() == 8,
            "RentStaking: usd pricer must be with decimal equal to 8!"
        );
    }

    function _getItemIndex(string memory _name) internal view returns (uint256) {
        uint256 l = items.length;
        bytes32 nameHash = keccak256(abi.encodePacked(_name));
        for (uint256 i; i < l; i++) {
            if (nameHash == keccak256(abi.encodePacked(items[i]))) {
                return i;
            }
        }
        revert("RentStaking: not found item index");
    }

    function _getLockPeriodIndex(uint256 _lockTime) internal view returns (uint256) {
        uint256 l = lockPeriods.length;
        for (uint256 i; i < l; i++) {
            if (_lockTime == lockPeriods[i]) {
                return i;
            }
        }
        revert("RentStaking: not found lock period index");
    }

    function _getTokenIndex(address _token) internal view returns (uint256) {
        uint256 l = supportedTokens.length;
        for (uint256 i; i < l; i++) {
            if (_token == supportedTokens[i]) {
                return i;
            }
        }
        revert("RentStaking: not found token index");
    }
}
