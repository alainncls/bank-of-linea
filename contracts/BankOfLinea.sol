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

    // Transaction fees
    uint256 public constant BUY_FEE = 99; // 99% on buy transactions
    uint256 public constant SELL_FEE = 7; // 7% on sell transactions

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

    // Reflection rewards per holder
    mapping(address => uint256) private rewards;

    // Timestamp of the last distribution
    uint256 private lastDistributed;

    // List of token holders
    address[] private holders;
    mapping(address => bool) private isHolder;

    // Exempted addresses from fees
    mapping(address => bool) public exemptedFromFees;

    // Events
    event ReflectionDistributed(uint256 amount);
    event FeesUpdated(uint256 buyFee, uint256 sellFee);
    event ExclusionUpdated(address account, bool isExcluded);
    event RewardsClaimed(address account, uint256 amount);

    /**
     * @dev Constructor to initialize the token.
     * @param _marketingWallet Address of the marketing wallet.
     */
    constructor(address _marketingWallet) ERC20("BankOfLinea", "BOL") Ownable(msg.sender) {
        require(_marketingWallet != address(0), "Invalid marketing wallet address");
        _mint(msg.sender, 10_000_000 * 10 ** decimals()); // Mint initial supply to the deployer
        marketingWallet = _marketingWallet;

        // Exclude certain addresses from rewards
        excludedFromRewards[address(this)] = true; // Contract address
        excludedFromRewards[marketingWallet] = true; // Marketing wallet
    }

    /**
     * @dev Overrides the transfer function to apply tax fees.
     * @param sender The address sending tokens.
     * @param recipient The address receiving tokens.
     * @param amount The amount of tokens being transferred.
     */
    function _update(address sender, address recipient, uint256 amount) internal override {
        require(sender != address(0), "Invalid sender address");
        require(recipient != address(0), "Invalid recipient address");
        uint256 fee = 0;

        // Calculate fees based on transaction type
        if (!exemptedFromFees[sender] && !exemptedFromFees[recipient]) {
            if (recipient == address(this)) {
                fee = (amount * SELL_FEE) / 100;
            } else if (sender == address(this)) {
                fee = (amount * BUY_FEE) / 100;
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
            _update(sender, address(this), liquidity); // Liquidity allocation
            _update(sender, marketingWallet, marketing); // Marketing allocation
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
        if (!isHolder[account] && balanceOf(account) > 0) {
            holders.push(account);
            isHolder[account] = true;
        }
    }

    /**
     * @dev Removes an address from the list of holders if it has no balance.
     * @param account The address to remove.
     */
    function _removeHolder(address account) internal {
        if (isHolder[account] && balanceOf(account) == 0) {
            isHolder[account] = false;
            uint256 index = _findHolderIndex(account);
            if (index < holders.length - 1) {
                holders[index] = holders[holders.length - 1];
            }
            holders.pop();
        }
    }

    function _findHolderIndex(address account) internal view returns (uint256) {
        for (uint256 i = 0; i < holders.length; i++) {
            if (holders[i] == account) {
                return i;
            }
        }
        revert IndexOutOfBounds();
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
                if (holderBalance >= 1000) {
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
        uint256 reward = calculateReward(msg.sender);
        if (reward == 0) revert NoRewardsAvailable();
        require(address(this).balance >= reward, "Insufficient contract balance");

        rewards[msg.sender] = 0;
        payable(msg.sender).transfer(reward);
        emit RewardsClaimed(msg.sender, reward);
    }

    /**
     * @notice Calculates the reward available for a specific address.
     *         The reward is based on the holder's share of the total supply.
     *         The holder must have a minimum balance of 1000 tokens to be eligible.
     * @param account The address of the token holder.
     * @return The amount of ETH rewards available.
     */
    function calculateReward(address account) public view returns (uint256) {
        if (balanceOf(account) < 1000) return 0;
        uint256 holderShare = (balanceOf(account) * 10 ** 18) / totalSupply();
        return (totalCollected * holderShare) / 10 ** 18;
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
     * @notice Updates the buy and sell fees.
     * @param _buyFee New buy fee percentage.
     * @param _sellFee New sell fee percentage.
     */
    function updateFees(uint256 _buyFee, uint256 _sellFee) external onlyOwner {
        require(_buyFee == BUY_FEE && _sellFee == SELL_FEE, "Invalid fees");
        emit FeesUpdated(_buyFee, _sellFee);
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
