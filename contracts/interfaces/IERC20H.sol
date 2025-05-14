// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20H is IERC20 {
	function lockedBalancesOf(
		address account
	) external view returns (uint256 locked, uint256 bonded, uint256 awaitingUnlock);

	function lock(uint256 value) external;

	function unlock(uint256 value) external;

	function onERC20HBonded(address owner, uint256 value) external returns (bytes4);

	function onERC20HUnbonded(address owner, uint256 value) external returns (bytes4);

	function setMirror(address mirror) external;
}
