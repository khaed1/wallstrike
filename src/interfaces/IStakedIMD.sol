// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The subset of sIMD (StakedIMD, a Solady ERC4626 over IMD) that Wallstrike uses.
/// @dev Mainnet: 0x9efa934d9fad4ae28c998a40195646b965a97247. Owner renounced, not paused, 24 decimals.
/// One-block hold: any mint stamps the receiver, whose withdraw/redeem then reverts in that block, and a
/// transfer passes the sender's stamp to the receiver. Transfers themselves are never blocked, so
/// Wallstrike only ever moves sIMD by transfer and never redeems it.
interface IStakedIMD is IERC20 {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function lastDepositBlock(address account) external view returns (uint256);
}
