// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BankOfLinea
 * @dev A deflationary ERC20 token with reflection and liquidity mechanisms.
 * Tax fees are applied on buy and sell transactions, with portions allocated for reflections, liquidity, and marketing.
 */
contract BankOfLinea is ERC20, Ownable {
    // Custom errors
    error IndexOutOfBounds();
    error DistributionNotReady();
    error ExcludedFromRewards();
    error NoRewardsAvailable();

    // Transaction fees
    uint256 public buyFee = 99; // 99% on buy transactions
    uint256 public sellFee = 7; // 7% on sell transactions

    // Fee allocation percentages
    uint256 public reflectionRate = 70; // 70% of the tax is distributed to holders
    uint256 public liquidityRate = 20; // 20% of the tax is added to liquidity
    uint256 public marketingRate = 10; // 10% of the tax is sent to the marketing wallet

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

    // Events
    event ReflectionDistributed(uint256 amount);
    event FeesUpdated(uint256 buyFee, uint256 sellFee);

    /**
     * @dev Constructor to initialize the token.
     * @param _marketingWallet Address of the marketing wallet.
     */
    constructor(address _marketingWallet) ERC20("BankOfLinea", "BOL") {
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
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        uint256 fee = 0;

        // Calculate fees based on transaction type
        if (recipient == address(this)) {
            fee = (amount * sellFee) / 100;
        } else if (sender == address(this)) {
            fee = (amount * buyFee) / 100;
        }

        uint256 transferAmount = amount - fee;

        // Distribute the fee
        if (fee > 0) {
            uint256 reflection = (fee * reflectionRate) / 100;
            uint256 liquidity = (fee * liquidityRate) / 100;
            uint256 marketing = fee - reflection - liquidity;

            // Add ETH to the respective allocations
            totalCollected += reflection;
            _transfer(sender, address(this), liquidity); // Liquidity allocation
            _transfer(sender, marketingWallet, marketing); // Marketing allocation
        }

        super._transfer(sender, recipient, transferAmount);

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
            for (uint256 i = 0; i < holders.length; i++) {
                if (holders[i] == account) {
                    holders[i] = holders[holders.length - 1];
                    holders.pop();
                    break;
                }
            }
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
     * @notice Distributes accumulated reflections to all eligible holders.
     */
    function distributeRewards() external {
        if (block.timestamp < lastDistributed + 3 hours) revert DistributionNotReady();
        uint256 amountToDistribute = (totalCollected * reflectionRate) / 100;
        totalCollected -= amountToDistribute;

        // Distribute rewards to eligible holders
        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            if (!excludedFromRewards[holder]) {
                rewards[holder] += calculateReward(holder);
            }
        }

        lastDistributed = block.timestamp;
        emit ReflectionDistributed(amountToDistribute);
    }

    /**
     * @notice Allows holders to claim their reflection rewards in ETH.
     */
    function claimRewards() external {
        if (excludedFromRewards[msg.sender]) revert ExcludedFromRewards();
        uint256 reward = calculateReward(msg.sender);
        if (reward == 0) revert NoRewardsAvailable();

        rewards[msg.sender] = 0;
        payable(msg.sender).transfer(reward);
    }

    /**
     * @notice Calculates the reward available for a specific address.
     * @param account The address of the token holder.
     * @return The amount of ETH rewards available.
     */
    function calculateReward(address account) public view returns (uint256) {
        // TODO: return 0 if balance < 1000
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
    }

    /**
     * @notice Updates the buy and sell fees.
     * @param _buyFee New buy fee percentage.
     * @param _sellFee New sell fee percentage.
     */
    function updateFees(uint256 _buyFee, uint256 _sellFee) external onlyOwner {
        buyFee = _buyFee;
        sellFee = _sellFee;
        emit FeesUpdated(_buyFee, _sellFee);
    }

    /**
     * @notice Allows the contract to receive ETH for reflection and liquidity purposes.
     */
    receive() external payable {}
}
