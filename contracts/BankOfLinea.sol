// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BankOfLinea
 * @dev A deflationary ERC20 token with reflection and liquidity mechanisms.
 * Tax fees are applied on buy and sell transactions, with portions allocated for reflections, liquidity, and marketing.
 */
contract BankOfLinea is ERC20, Ownable, ReentrancyGuard {
    // Custom errors
    error IndexOutOfBounds();
    error DistributionNotReady();
    error ExcludedFromRewards();
    error NoRewardsAvailable();
    error InvalidAddress();
    error InsufficientBalance();
    error TimelockNotExpired();
    error ETHTransferFailed();

    // Transaction fees
    uint256 public buyFee = 99; // 99% on buy transactions
    uint256 public sellFee = 7; // 7% on sell transactions

    // Fee allocation percentages
    uint256 public constant REFLECTION_RATE = 70; // 70% of the tax is distributed to holders
    uint256 public constant LIQUIDITY_RATE = 20; // 20% of the tax is added to liquidity
    uint256 public constant MARKETING_RATE = 10; // 10% of the tax is sent to the marketing wallet

    // Marketing wallet address
    address public marketingWallet;

    // Total ETH collected for reflections
    uint256 public totalCollected;

    // Excluded addresses from reflection rewards
    mapping(address => bool) public excludedFromRewards;

    // Exempted addresses from fees
    mapping(address => bool) public exemptedFromFees;

    // Reflection rewards per holder
    mapping(address => uint256) private rewards;

    // Timestamp of the last distribution
    uint256 private lastDistributed;

    // List of token holders
    address[] private holders;
    mapping(address => uint256) private holderIndex; // store index + 1 (0 means absent)

    // Events
    event ReflectionDistributed(uint256 amount);
    event FeesUpdated(uint256 buyFee, uint256 sellFee);
    event ExclusionUpdated(address account, bool isExcluded);
    event RewardsClaimed(address account, uint256 amount);
    event FeeChangeProposed(uint256 newBuyFee, uint256 newSellFee, uint256 timestamp);

    // Internal flag to prevent fee application during internal transfers
    bool private inFeeTransfer;

    /**
     * @dev Constructor to initialize the token.
     * @param _marketingWallet Address of the marketing wallet.
     */
    constructor(address _marketingWallet) ERC20("BankOfLinea", "BOL") Ownable(msg.sender) {
        if (_marketingWallet == address(0)) revert InvalidAddress();

        marketingWallet = _marketingWallet;

        // Exclude certain addresses from rewards
        excludedFromRewards[address(this)] = true; // Contract address
        excludedFromRewards[marketingWallet] = true; // Marketing wallet

        _mint(_marketingWallet, 10_000_000 * 10 ** decimals()); // Mint initial supply to the marketing wallet
    }

    /**
     * @dev Internal function to handle transfers without applying fees.
     * @param sender The address sending tokens.
     * @param recipient The address receiving tokens.
     * @param amount The amount of tokens being transferred.
     */
    function _internalTransfer(address sender, address recipient, uint256 amount) internal {
        inFeeTransfer = true;
        _update(sender, recipient, amount);
        inFeeTransfer = false;
    }

    /**
     * @dev Overrides the transfer function to apply tax fees.
     * @param sender The address sending tokens.
     * @param recipient The address receiving tokens.
     * @param amount The amount of tokens being transferred.
     */
    function _update(address sender, address recipient, uint256 amount) internal override {
        if (recipient == address(0)) revert InvalidAddress();

        uint256 fee = 0;

        // Calculate fees based on transaction type
        if (!inFeeTransfer && !exemptedFromFees[sender] && !exemptedFromFees[recipient]) {
            if (recipient == address(this)) {
                fee = (amount * sellFee) / 100;
            } else if (sender == address(this)) {
                fee = (amount * buyFee) / 100;
            }
        }

        uint256 transferAmount = amount - fee;

        // Distribute the fee
        if (fee > 0) {
            uint256 reflection = (fee * REFLECTION_RATE) / 100;
            uint256 liquidity = (fee * LIQUIDITY_RATE) / 100;
            uint256 marketing = fee - reflection - liquidity;

            // Add ETH to the respective allocations
            totalCollected += reflection;
            _internalTransfer(sender, address(this), liquidity); // Liquidity allocation
            _internalTransfer(sender, marketingWallet, marketing); // Marketing allocation
        }

        super._update(sender, recipient, transferAmount);

        // Manage holder list
        _addHolder(recipient);
        _removeHolder(sender);
    }

    /**
     * @dev Adds an address to the list of holders if it has a balance.
     * @param account The address to add.
     */
    function _addHolder(address account) internal {
        if (holderIndex[account] == 0 && balanceOf(account) > 0) {
            holderIndex[account] = holders.length + 1; // index+1 to avoid zero
            holders.push(account);
        }
    }

    /**
     * @dev Removes an address from the list of holders if it has no balance.
     * @param account The address to remove.
     */
    function _removeHolder(address account) internal {
        if (holderIndex[account] != 0 && balanceOf(account) == 0) {
            uint256 index = holderIndex[account];
            uint256 lastIndex = holders.length;
            address lastHolder = holders[lastIndex - 1];
            // Replace the element to remove with the last one
            holders[index - 1] = lastHolder;
            holderIndex[lastHolder] = index;
            holders.pop();
            holderIndex[account] = 0;
        }
    }

    /**
     * @notice Retrieves the address of a holder at a specific index.
     * @param index The index of the holder.
     * @return The address of the holder.
     */
    function holderAt(uint256 index) public view returns (address) {
        if (index >= holders.length) revert IndexOutOfBounds();
        return holders[index];
    }

    /**
     * @notice Returns the total number of holders.
     * @return The number of holders.
     */
    function holderCount() public view returns (uint256) {
        return holders.length;
    }

    /**
     * @notice Distributes accumulated reflections to a batch of holders.
     * @param startIndex The starting index of the holders to distribute to.
     * @param endIndex The ending index of the holders to distribute to.
     */
    function distributeRewardsBatch(uint256 startIndex, uint256 endIndex) external {
        if (block.timestamp < lastDistributed + 3 hours) revert DistributionNotReady();
        uint256 amountToDistribute = totalCollected;
        totalCollected = 0;

        uint256 totalSupplyCached = totalSupply();
        for (uint256 i = startIndex; i < endIndex && i < holders.length; i++) {
            address holder = holders[i];
            if (!excludedFromRewards[holder]) {
                uint256 holderBalance = balanceOf(holder);
                if (holderBalance >= 1000 * 10 ** decimals()) {
                    uint256 holderShare = (holderBalance * 10 ** 18) / totalSupplyCached;
                    rewards[holder] += (amountToDistribute * holderShare) / 10 ** 18;
                }
            }
        }

        lastDistributed = block.timestamp;
        emit ReflectionDistributed(amountToDistribute);
    }

    /**
     * @notice Allows holders to claim their reflection rewards in ETH.
     */
    function claimRewards() external nonReentrant {
        if (excludedFromRewards[msg.sender]) revert ExcludedFromRewards();
        uint256 reward = rewards[msg.sender];
        if (reward == 0) revert NoRewardsAvailable();
        if (address(this).balance < reward) revert InsufficientBalance();

        rewards[msg.sender] = 0;
        (bool success, ) = payable(msg.sender).call{value: reward}("");
        if (!success) revert ETHTransferFailed();
        emit RewardsClaimed(msg.sender, reward);
    }

    /**
     * @notice Sets whether an address is excluded from reflection rewards.
     * @param account The address to exclude or include.
     * @param excluded Whether the address should be excluded.
     */
    function setExcludedFromRewards(address account, bool excluded) external onlyOwner {
        excludedFromRewards[account] = excluded;
        emit ExclusionUpdated(account, excluded);
    }

    /**
     * @notice Proposes a new fee configuration with a 7-day timelock.
     * @param _newBuyFee New buy fee percentage.
     * @param _newSellFee New sell fee percentage.
     */
    struct FeeChange {
        uint256 newBuyFee;
        uint256 newSellFee;
        uint256 timestamp; // time of proposal
    }

    FeeChange public pendingFeeChange;

    function proposeFeeChange(uint256 _newBuyFee, uint256 _newSellFee) external onlyOwner {
        pendingFeeChange = FeeChange({newBuyFee: _newBuyFee, newSellFee: _newSellFee, timestamp: block.timestamp});
        emit FeeChangeProposed(_newBuyFee, _newSellFee, block.timestamp);
    }

    function applyFeeChange() external onlyOwner {
        if (block.timestamp < pendingFeeChange.timestamp + 7 days) revert TimelockNotExpired();
        buyFee = pendingFeeChange.newBuyFee;
        sellFee = pendingFeeChange.newSellFee;
        delete pendingFeeChange;
        emit FeesUpdated(buyFee, sellFee);
    }

    /**
     * @notice Sets whether an address is exempted from fees.
     * @param account The address to exempt or include.
     * @param exempted Whether the address should be exempted.
     */
    function setExemptedFromFees(address account, bool exempted) external onlyOwner {
        exemptedFromFees[account] = exempted;
    }

    /**
     * @notice Allows the contract to receive ETH for reflection and liquidity purposes.
     */
    receive() external payable {}
}
