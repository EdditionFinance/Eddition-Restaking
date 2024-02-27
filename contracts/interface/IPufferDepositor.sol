// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PufferDepositor
 * @author Puffer Finance
 * @custom:security-contact security@puffer.fi
 */
interface IPufferDepositor {
    /**
     * @dev Error indicating that the token is not allowed.
     */
    error TokenNotAllowed(address token);
    /**
     * @dev Error indicating that the 1inch swap has failed.
     * @param token The address of the token being swapped.
     * @param amount The amount of the token being swapped.
     */
    error SwapFailed(address token, uint256 amount);

    /**
     * @dev Event indicating that the token is allowed.
     */
    event TokenAllowed(IERC20 token);
    /**
     * @dev Event indicating that the token is disallowed.
     */
    event TokenDisallowed(IERC20 token);

    /**
     * @dev Struct representing a permit for a specific action.
     */
    struct Permit {
        uint256 deadline;
        uint256 amount;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /**
     * @notice Deposits wrapped stETH (wstETH) into the Puffer Vault
     * @param permitData The permit data containing the approval information
     * @return pufETHAmount The amount of pufETH received from the deposit
     */
    function depositWstETHPermit(IPufferDepositor.Permit calldata permitData) external returns (uint256 pufETHAmount);

    /**
     * @notice Deposits stETH into the Puffer Vault using Permit
     * @param permitData The permit data containing the approval information
     * @return pufETHAmount The amount of pufETH received from the deposit
     */
    function depositStETHPermit(IPufferDepositor.Permit calldata permitData) external returns (uint256 pufETHAmount);
}
