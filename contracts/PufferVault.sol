// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import { IPufferVault } from "./interface/IPufferVault.sol";
import { IStETH } from "./interface/Lido/IStETH.sol";
import { ILidoWithdrawalQueue } from "./interface/Lido/ILidoWithdrawalQueue.sol";
import { IEigenLayer } from "./interface/EigenLayer/IEigenLayer.sol";
import { IStrategy } from "./interface/EigenLayer/IStrategy.sol";
import { PufferVaultStorage } from "./PufferVaultStorage.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";

/**
 * @title PufferVault
 * @author Puffer Finance
 * @custom:security-contact security@puffer.fi
 */
contract PufferVault is
    IPufferVault,
    IERC721Receiver,
    PufferVaultStorage,
    ERC20PermitUpgradeable,
    OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable
{
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IStETH;
    using SafeERC20 for IERC20;

    struct EigenPoint {
        uint256 assets;
        uint256 point;
        uint256 lastTime;
    }

    /**
     * @dev EigenLayer stETH strategy
     */
    IStrategy internal immutable _EIGEN_STETH_STRATEGY;
    /**
     * @dev EigenLayer Strategy Manager
     */
    IEigenLayer internal immutable _EIGEN_STRATEGY_MANAGER;
    /**
     * @dev stETH contract
     */
    IStETH internal immutable _ST_ETH;
    /**
     * @dev Lido Withdrawal Queue
     */
    ILidoWithdrawalQueue internal immutable _LIDO_WITHDRAWAL_QUEUE;

    mapping(address => EigenPoint) public eigenPoint;

    address public immutable rewardToken;
    uint256 public duration;
    uint256 public rewardPerTokenStored;
    uint256 public rewardRate;
    uint256 public finishAt;
    uint256 public updatedAt;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public userUpdatedAt;

    event AddReward(address indexed token, uint256 amount, uint256 newShareIndex);
    event Claim(address indexed token, address indexed account, uint256 amount);
    event Deposit(address caller, address receiver, uint256 assets, uint256 shares);

    constructor(
        IStETH stETH,
        ILidoWithdrawalQueue lidoWithdrawalQueue,
        IStrategy stETHStrategy,
        IEigenLayer eigenStrategyManager,
        address _rewardToken
    ) payable {
        _ST_ETH = stETH;
        _LIDO_WITHDRAWAL_QUEUE = lidoWithdrawalQueue;
        _EIGEN_STETH_STRATEGY = stETHStrategy;
        _EIGEN_STRATEGY_MANAGER = eigenStrategyManager;
        rewardToken = _rewardToken;
        _disableInitializers();
    }

    function initialize() external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        PausableUpgradeable.__Pausable_init();

        __ERC20Permit_init("edETH");
        __ERC20_init("edETH", "edETH");

        duration = 30 days;
    }

    /**
     * @dev Restricted in this context is like `whenNotPaused` modifier from Pausable.sol
     */
    function deposit(uint256 assets, address receiver) external virtual returns (uint256 shares) {
        uint256 _totalSupply = totalSupply();
        shares = assets;
        if (_totalSupply > 0) {
            shares = shares * _totalSupply / totalAssets();
        }

        _deposit(receiver, assets, shares);
    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(address receiver, uint256 assets, uint256 shares) internal virtual {
        _ST_ETH.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        accEigenPoint(receiver, assets, true);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Claims ETH withdrawals from Lido
     * @param requestIds An array of request IDs for the withdrawals
     */
    function claimWithdrawalsFromLido(uint256[] calldata requestIds) external virtual {
        VaultStorage storage $ = _getPufferVaultStorage();

        // Tell our receive() that we are doing a Lido claim
        $.isLidoWithdrawal = true;

        for (uint256 i = 0; i < requestIds.length; ++i) {
            bool isValidWithdrawal = $.lidoWithdrawals.remove(requestIds[i]);
            if (!isValidWithdrawal) {
                revert InvalidWithdrawal();
            }

            // slither-disable-next-line calls-loop
            _LIDO_WITHDRAWAL_QUEUE.claimWithdrawal(requestIds[i]);
        }

        // Reset back the value
        $.isLidoWithdrawal = false;
        emit ClaimedWithdrawals(requestIds);
    }

    /**
     * @notice Not allowed
     */
    function redeem(uint256, address, address) public virtual returns (uint256) {
        revert WithdrawalsAreDisabled();
    }

    /**
     * @notice Not allowed
     */
    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256) {
        revert WithdrawalsAreDisabled();
    }

    /**
     * @dev See {IERC4626-totalAssets}.
     * Eventually, stETH will not be part of this vault anymore, and the Vault(pufETH) will represent shares of total ETH holdings
     * Because stETH is a rebasing token, its ratio with ETH is 1:1
     * Because of that our ETH holdings backing the system are:
     * stETH balance of this vault + stETH balance locked in EigenLayer + stETH balance that is the process of withdrawal from Lido
     * + ETH balance of this vault
     */
    function totalAssets() public view virtual returns (uint256) {
        return _ST_ETH.balanceOf(address(this)) + getELBackingEthAmount();
    }

    /**
     * @notice Returns the ETH amount that is backing this vault locked in EigenLayer stETH strategy
     */
    function getELBackingEthAmount() public view virtual returns (uint256 ethAmount) {
        VaultStorage storage $ = _getPufferVaultStorage();
        // When we initiate withdrawal from EigenLayer, the shares are deducted from the `lockedAmount`
        // In that case the locked amount goes to 0 and the pendingWithdrawalAmount increases
        uint256 lockedAmount = _EIGEN_STETH_STRATEGY.userUnderlying(address(this));
        uint256 pendingWithdrawalAmount =
            _EIGEN_STETH_STRATEGY.sharesToUnderlyingView($.eigenLayerPendingWithdrawalSharesAmount);
        return lockedAmount + pendingWithdrawalAmount;
    }

    /**
     * @notice Deposits stETH into `stETH EigenLayer strategy`
     * Restricted access
     * @param amount the amount of stETH to deposit
     */
    function depositToEigenLayer(uint256 amount) external virtual onlyOwner {
        _ST_ETH.safeIncreaseAllowance(address(_EIGEN_STRATEGY_MANAGER), amount);
        _EIGEN_STRATEGY_MANAGER.depositIntoStrategy({ strategy: _EIGEN_STETH_STRATEGY, token: _ST_ETH, amount: amount });
    }

    /**
     * @notice Initiates stETH withdrawals from EigenLayer
     * Restricted access
     * @param sharesToWithdraw An amount of EigenLayer shares that we want to queue
     */
    function initiateStETHWithdrawalFromEigenLayer(uint256 sharesToWithdraw) external virtual onlyOwner {
        VaultStorage storage $ = _getPufferVaultStorage();

        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(_EIGEN_STETH_STRATEGY);

        uint256[] memory shares = new uint256[](1);
        shares[0] = sharesToWithdraw;

        // Account for the shares
        $.eigenLayerPendingWithdrawalSharesAmount += sharesToWithdraw;

        bytes32 withdrawalRoot = _EIGEN_STRATEGY_MANAGER.queueWithdrawal({
            strategyIndexes: new uint256[](1), // [0]
            strategies: strategies,
            shares: shares,
            withdrawer: address(this),
            undelegateIfPossible: true
        });

        $.eigenLayerWithdrawals.add(withdrawalRoot);
    }

    /**
     * @notice Claims stETH withdrawals from EigenLayer
     * Restricted access
     * @param queuedWithdrawal The queued withdrawal details
     * @param tokens The tokens to be withdrawn
     * @param middlewareTimesIndex The index of middleware times
     */
    function claimWithdrawalFromEigenLayer(
        IEigenLayer.QueuedWithdrawal calldata queuedWithdrawal,
        IERC20[] calldata tokens,
        uint256 middlewareTimesIndex
    ) external virtual {
        VaultStorage storage $ = _getPufferVaultStorage();

        bytes32 withdrawalRoot = _EIGEN_STRATEGY_MANAGER.calculateWithdrawalRoot(queuedWithdrawal);
        bool isValidWithdrawal = $.eigenLayerWithdrawals.remove(withdrawalRoot);
        if (!isValidWithdrawal) {
            revert InvalidWithdrawal();
        }

        $.eigenLayerPendingWithdrawalSharesAmount -= queuedWithdrawal.shares[0];

        _EIGEN_STRATEGY_MANAGER.completeQueuedWithdrawal({
            queuedWithdrawal: queuedWithdrawal,
            tokens: tokens,
            middlewareTimesIndex: middlewareTimesIndex,
            receiveAsTokens: true
        });
    }

    /**
     * @notice Required by the ERC721 Standard
     */
    function onERC721Received(address, address, uint256, bytes calldata) external virtual returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @notice Returns the number of decimals used to get its user representation.
     */
    function decimals() public pure override(ERC20Upgradeable) returns (uint8) {
        return 18;
    }

    function accEigenPoint(address receiver, uint256 assets, bool isDeposit) internal {
        // 1 pufETH * 24 = 24 point
        // 1 point * 1e18 / 1 hours = 277777777777777
        EigenPoint storage point = eigenPoint[receiver];
        if(point.lastTime == 0){
            point.assets = assets;
            point.lastTime = block.timestamp;
            return;
        }
        // Enlarge by 18x
        point.point += point.assets * (block.timestamp - point.lastTime) * 1e18 / 1 hours;
        if(isDeposit){
            point.assets += assets;
        }else{
            point.assets -= assets;
        }
        point.lastTime = block.timestamp;
    }

    function pendingEigenPoint(address receiver) external view returns (uint256) {
        EigenPoint storage point = eigenPoint[receiver];
        return point.point + point.assets * (block.timestamp - point.lastTime) * 1e18 / 1 hours;
    }

    function pricePerShare() public view virtual returns (uint256) {
        return totalAssets() * 1e18 / totalSupply();
    }

    // ***************************************************************************************

    modifier updateReward(address _account) {
        rewardPerTokenStored = rewardPerToken();
        updatedAt = lastTimeRewardApplicable();

        if (_account != address(0)) {
            rewards[_account] = earned(_account);
            userRewardPerTokenPaid[_account] = rewardPerTokenStored;
            userUpdatedAt[_account] = block.timestamp;
        }

        _;
    }

    function _updateReward(address _account) updateReward(_account) internal { }

    function notifyRewardAmount(uint256 _amount)
        external onlyOwner
        updateReward(address(0))
    {
        require(_amount > 0, "amount = 0");
        if (block.timestamp >= finishAt) {
            rewardRate = _amount / duration;
        } else {
            uint256 remainingRewards = (finishAt - block.timestamp) * rewardRate;
            rewardRate = (_amount + remainingRewards) / duration;
        }
        require(rewardRate > 0, 'reward rate = 0');

        finishAt = block.timestamp + duration;
        updatedAt = block.timestamp;

        emit AddReward(rewardToken, _amount, rewardRate);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 /* amount */
    ) internal override {
        if (from != address(0)) {
            _updateReward(from);
        }
        if (to != address(0)) {
            _updateReward(to);
        }
    }

    function claim() external updateReward(msg.sender) returns (uint256 amount) {
        amount = rewards[msg.sender];
        if (amount > 0) {
            rewards[msg.sender] = 0;
            IERC20(rewardToken).safeTransfer(msg.sender, amount);
            emit Claim(rewardToken, msg.sender, amount);
        }
    }

    function earned(address _account) public view returns (uint256) {
        return ((balanceOf(_account) * (rewardPerToken() - userRewardPerTokenPaid[_account])) / 1e36) + rewards[_account];
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            (rewardRate * (lastTimeRewardApplicable() - updatedAt) * 1e36) /
            totalSupply();
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return _min(finishAt, block.timestamp);
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x <= y ? x : y;
    }

    // ***************************************************************************************
}
