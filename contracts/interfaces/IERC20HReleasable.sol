// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20H} from "./IERC20H.sol";

interface IERC20HReleasable is IERC20H {
	function release() external;

	function release(uint128 tranchesToRelease) external;
}
