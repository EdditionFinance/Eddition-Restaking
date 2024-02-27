// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import { IStETH } from "./interface/Lido/IStETH.sol";
import { IWstETH } from "./interface/Lido/IWstETH.sol";
import { PufferVault } from "./PufferVault.sol";
import { PufferDepositorStorage } from "./PufferDepositorStorage.sol";
import { ISushiRouter } from "./interface/Other/ISushiRouter.sol";
import { IPufferDepositor } from "./interface/IPufferDepositor.sol";

/**
 * @title PufferDepositor
 * @author Puffer Finance
 * @custom:security-contact security@puffer.fi
 */

contract PufferDepositor is IPufferDepositor, PufferDepositorStorage, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IWstETH;
    using SafeERC20 for IStETH;

    IStETH internal immutable _ST_ETH;
    IWstETH internal immutable _WST_ETH;

    /**
     * @dev The Puffer Vault contract address
     */
    PufferVault public immutable PUFFER_VAULT;

    constructor(PufferVault pufferVault, IStETH stETH, IWstETH wstETH) payable {
        PUFFER_VAULT = pufferVault;
        _ST_ETH = stETH;
        _WST_ETH = wstETH;
        _disableInitializers();
    }

    function initialize() external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        PausableUpgradeable.__Pausable_init();

        _ST_ETH.safeIncreaseAllowance(address(PUFFER_VAULT), type(uint256).max);
    }

    /**
     * @inheritdoc IPufferDepositor
     */
    function depositWstETHPermit(IPufferDepositor.Permit calldata permitData)
        external
        nonReentrant
        returns (uint256 pufETHAmount)
    {
        try ERC20Permit(address(_WST_ETH)).permit({
            owner: msg.sender,
            spender: address(this),
            value: permitData.amount,
            deadline: permitData.deadline,
            v: permitData.v,
            s: permitData.s,
            r: permitData.r
        }) { } catch { }

        _WST_ETH.safeTransferFrom(msg.sender, address(this), permitData.amount);
        uint256 stETHAmount = _ST_ETH.balanceOf(address(this));
        _WST_ETH.unwrap(permitData.amount);
        stETHAmount = _ST_ETH.balanceOf(address(this)) - stETHAmount;
        return PUFFER_VAULT.deposit(stETHAmount, msg.sender);
    }

    function depositWstETH(uint256 amount)
        external
        nonReentrant
        returns (uint256 pufETHAmount)
    {
        _WST_ETH.safeTransferFrom(msg.sender, address(this), amount);
        uint256 stETHAmount = _ST_ETH.balanceOf(address(this));
        _WST_ETH.unwrap(amount);
        stETHAmount = _ST_ETH.balanceOf(address(this)) - stETHAmount;
        return PUFFER_VAULT.deposit(stETHAmount, msg.sender);
    }

    /**
     * @inheritdoc IPufferDepositor
     */
    function depositStETHPermit(IPufferDepositor.Permit calldata permitData)
        external
        nonReentrant
        returns (uint256 pufETHAmount)
    {
        try ERC20Permit(address(_ST_ETH)).permit({
            owner: msg.sender,
            spender: address(this),
            value: permitData.amount,
            deadline: permitData.deadline,
            v: permitData.v,
            s: permitData.s,
            r: permitData.r
        }) { } catch { }

        _ST_ETH.safeTransferFrom(msg.sender, address(this), permitData.amount);
        return PUFFER_VAULT.deposit(permitData.amount, msg.sender);
    }

    function depositStETH(uint256 amount)
        external
        nonReentrant
        returns (uint256 pufETHAmount)
    {
        _ST_ETH.safeTransferFrom(msg.sender, address(this), amount);
        return PUFFER_VAULT.deposit(amount, msg.sender);
    }

    function depositETH() external payable nonReentrant returns (uint256 pufETHAmount){
        uint256 stETHAmount = _ST_ETH.balanceOf(address(this));
        _ST_ETH.submit{value: msg.value}(address(this));
        stETHAmount = _ST_ETH.balanceOf(address(this)) - stETHAmount;
        return PUFFER_VAULT.deposit(stETHAmount, msg.sender);
    }

    receive() external payable virtual {
        uint256 stETHAmount = _ST_ETH.balanceOf(address(this));
        _ST_ETH.submit{value: msg.value}(address(this));
        stETHAmount = _ST_ETH.balanceOf(address(this)) - stETHAmount;
        PUFFER_VAULT.deposit(stETHAmount, msg.sender);
    }
}
