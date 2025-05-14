// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {ERC20H} from "../ERC20H.sol";
import {IERC20HReleasable} from "../interfaces/IERC20HReleasable.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.openzeppelin.com/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * The default value of {decimals} is 18. To change this, you should override
 * this function so it returns a different value.
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC-20
 * applications.
 */
abstract contract ERC20HReleasable is ERC20H, IERC20HReleasable {

    error ERC20HReleasableNoTranchesToRelease();

    function setUnlockCooldown(uint96 unlockCooldown_) external virtual {
        _setUnlockCooldown(unlockCooldown_);
    }

    function release() external virtual {
        _releaseUnlockingTokens(_msgSender(), 0);
    }

    function release(uint128 tranchesToRelease) external virtual {
        if (tranchesToRelease == 0) {
            revert ERC20HReleasableNoTranchesToRelease();
        }

        _releaseUnlockingTokens(_msgSender(), tranchesToRelease);
    }
}
