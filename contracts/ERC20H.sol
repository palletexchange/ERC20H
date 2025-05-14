// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20H} from "./interfaces/IERC20H.sol";
import {IERC20HMirror} from "./interfaces/IERC20HMirror.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

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
abstract contract ERC20H is Context, Ownable, IERC20, IERC20Metadata, IERC20Errors, IERC20H {
    using Strings for uint256;

    struct UnlockingTokens {
        uint256 amount;
        uint256 releaseBlock;
        uint128 prevIndex;
        uint128 nextIndex;
    }

    struct AddressBalances {
        uint256 total;
        uint256 locked;
        uint256 bonded;
        uint256 unlocking;

        uint128 indexOfLatest;
        uint128 numIndexes;
        mapping(uint128 index => UnlockingTokens) unlockingTokens;
    }

    struct UnlockingTokensDebug {
        uint128 indexOfLatest;
        uint128 numIndexes;
        uint256 amount;
        uint256 releaseBlock;
        uint128 prevIndex;
        uint128 nextIndex;
    }

    // debug only
    function debugUnlockingTokens(address owner, uint128 index) external view returns (UnlockingTokensDebug memory) {
        AddressBalances storage balances = _balances[owner];
        UnlockingTokens memory t = balances.unlockingTokens[index];
        return UnlockingTokensDebug(
            balances.indexOfLatest,
            balances.numIndexes,
            t.amount,
            t.releaseBlock,
            t.prevIndex,
            t.nextIndex
        );
    }

    // bytes4(keccak256("onERC20HBonded(address,uint256)"))
    bytes4 internal constant _SELECTOR_ON_BONDED = 0x6d2a0e8d;

    // bytes4(keccak256("onERC20HUnbonded(address,uint256)"))
    bytes4 internal constant _SELECTOR_ON_UNBONDED = 0x00cf4070;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    address private _mirror;

    uint96 private _unlockCooldown;

    mapping(address account => AddressBalances) private _balances;

    mapping(address account => mapping(address spender => uint256)) private _allowances;

    /**
     * @dev Emitted when `value` tokens are locked up by `owner`.
     *
     * Note that `value` may be zero.
     */
    event Locked(address indexed owner, uint256 indexed value);

    /**
     * @dev Emitted when `value` tokens are unlocked by `owner`.
     *
     * Note that `value` may be zero.
     */
    event Unlocked(address indexed owner, uint256 indexed value);

    /**
     * @dev Indicates `owner` does not have enough unlocked balance for locking up.
     * @param owner Address whose tokens are being locked.
     * @param balance Current unlocked balance for the interacting account.
     * @param needed Minimum amount required to perform the operation.
     */
    error ERC20HInsufficientUnlockedBalance(address owner, uint256 balance, uint256 needed);

    /**
     * @dev Indicates `owner` does not have enough locked balance for unlocking.
     * @param owner Address whose tokens are being unlocked.
     * @param balance Current locked balance for the interacting account.
     * @param needed Minimum amount required to perform the operation.
     */
    error ERC20HInsufficientLockedBalance(address owner, uint256 balance, uint256 needed);

    /**
     * @dev Indicates `owner` does not have enough locked balance for unlocking.
     * @param owner Address whose tokens are being unlocked.
     * @param balance Current locked balance for the interacting account.
     * @param needed Minimum amount required to perform the operation.
     */
    error ERC20HInsufficientBondedBalance(address owner, uint256 balance, uint256 needed);

    /**
     * @dev Indicates `owner` does not have enough locked balance for unlocking.
     * @param owner Address whose tokens are being unlocked.
     * @param balance Current locked balance for the interacting account.
     * @param needed Minimum amount required to perform the operation.
     */
    error ERC20HInsufficientUnbondedBalance(address owner, uint256 balance, uint256 needed);

    /**
     * @dev Indicates `owner` does not have enough locked balance for unlocking.
     * @param owner Address whose tokens are being unlocked.
     * @param balance Current locked balance for the interacting account.
     * @param needed Minimum amount required to perform the operation.
     */
    error ERC20HCannotLockNegativeBalance(address owner, uint256 balance, uint256 needed);

    error ERC20HAccessOnlyForMirror();

    error ERC20HAlreadySetMirror(address mirror);

    error ERC20HMissingBondedAccounting();

    error ERC20HIncorrectAmountBonded(uint256 expected, uint256 actual);

    /**
     * @dev Only callable by mirror
     */
    modifier mirrorOnly() {
        if (_msgSender() != _mirror) {
            revert ERC20HAccessOnlyForMirror();
        }

        _;
    }

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * Both values are immutable: they can only be set once during construction.
     */
    constructor(address initialOwner_, string memory name_, string memory symbol_) Ownable(initialOwner_) {
        _name = name_;
        _symbol = symbol_;
    }

    function setMirror(address mirror_) external virtual onlyOwner {
        _setMirror(mirror_);
    }

    function onERC20HBonded(address owner, uint256 value) external virtual mirrorOnly returns (bytes4) {
        _bond(owner, value);

        return _SELECTOR_ON_BONDED;
    }

    function onERC20HUnbonded(address owner, uint256 value) external virtual mirrorOnly returns (bytes4) {
        _unbondAndUnlock(owner, value);

        return _SELECTOR_ON_UNBONDED;
    }

    function lock(uint256 value) external virtual {
        (uint256 locked, uint256 bonded, uint256 awaitingUnlock) = lockedBalancesOf(_msgSender());
        uint256 total = balanceOf(_msgSender());

        uint256 unlocked;
        uint256 freeLocked;
        unchecked {
            unlocked = total - locked;
            freeLocked = locked - bonded - awaitingUnlock;
        }

        if (unlocked < value) {
            revert ERC20HInsufficientUnlockedBalance(_msgSender(), unlocked, value);
        }

        _lockAndMint(_msgSender(), value + freeLocked);
    }

    function unlock(uint256 value) external virtual {
        _unlock(_msgSender(), value);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                          IERC20                            */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the default value returned by this function, unless
     * it's overridden.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /// @inheritdoc IERC20
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /// @inheritdoc IERC20
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account].total;
    }

    function lockedBalancesOf(
        address account
    ) public view virtual returns (uint256 locked, uint256 bonded, uint256 awaitingUnlock) {
        AddressBalances storage b = _balances[account];

        locked = b.locked;
        bonded = b.bonded;
        awaitingUnlock = b.unlocking;
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `value`.
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `value` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Skips emitting an {Approval} event indicating an allowance update. This is not
     * required by the ERC. See {xref-ERC20-_approve-address-address-uint256-bool-}[_approve].
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `value`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `value`.
     */
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                          ERC20 INTERNALS                           */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal virtual {
        address caller = _msgSender();

        AddressBalances storage fromBalances = _balances[from];
        AddressBalances storage toBalances = _balances[to];

        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            _totalSupply += value;
        } else {
            // check total balance
            uint256 fromBalance = fromBalances.total;
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }

            // Mirror contract will act only on the bonded balance. We will need to check
            // and decrement balances when msg.sender is the mirror, and a separate flow
            // for when it is not.
            if (caller == _mirror) {
                // msgSender is mirror. so we need to make sure there is enough bonded balance
                uint256 fromBondedBalance = fromBalances.bonded;
                if (fromBondedBalance < value) {
                    revert ERC20HInsufficientBondedBalance(from, fromBondedBalance, value);
                }

                unchecked {
                    // Overflow not possible: value <= fromBalance <= totalSupply.
                    fromBalances.total = fromBalance - value;
                    // Overflow not possible: value <= fromBondedBalance <= fromLockedBalance
                    fromBalances.locked -= value;
                    // Overflow not possible: value <= fromBondedBalance
                    fromBalances.bonded = fromBondedBalance - value;
                }
            } else {
                // check locked balance
                uint256 fromUnlockedBalance = fromBalance - fromBalances.locked;
                if (fromUnlockedBalance < value) {
                    revert ERC20HInsufficientUnlockedBalance(from, fromUnlockedBalance, value);
                }

                unchecked {
                    // Overflow not possible: value <= fromBalance <= totalSupply.
                    fromBalances.total = fromBalance - value;
                }
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                _totalSupply -= value;
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                toBalances.total += value;
            }

            // Mirror contract will act on the locked balance only. Increment locked balance
            // if msg.sender is the mirror contract.
            if (caller == _mirror) {
                toBalances.locked += value;
                toBalances.bonded += value;
            }
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Creates a `value` amount of tokens and assigns them to `account`, by transferring it from address(0).
     * Relies on the `_update` mechanism
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * Relies on the `_update` mechanism.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead
     */
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }

    /**
     * @dev Sets `value` as the allowance of `spender` over the `owner`'s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     *
     * Overrides to this logic should be done to the variant with an additional `bool emitEvent` argument.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /**
     * @dev Variant of {_approve} with an optional flag to enable or disable the {Approval} event.
     *
     * By default (when calling {_approve}) the flag is set to true. On the other hand, approval changes made by
     * `_spendAllowance` during the `transferFrom` operation set the flag to false. This saves gas by not emitting any
     * `Approval` event during `transferFrom` operations.
     *
     * Anyone who wishes to continue emitting `Approval` events on the`transferFrom` operation can force the flag to
     * true using the following override:
     *
     * ```solidity
     * function _approve(address owner, address spender, uint256 value, bool) internal virtual override {
     *     super._approve(owner, spender, value, true);
     * }
     * ```
     *
     * Requirements are the same as {_approve}.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Updates `owner`'s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        if (_msgSender() != _mirror) {
            uint256 currentAllowance = allowance(owner, spender);
            if (currentAllowance < type(uint256).max) {
                if (currentAllowance < value) {
                    revert ERC20InsufficientAllowance(spender, currentAllowance, value);
                }
                unchecked {
                    _approve(owner, spender, currentAllowance - value, false);
                }
            }
        }
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                         ERC20H INTERNALS                           */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    function _setMirror(address mirror_) internal virtual {
        if (_mirror != address(0)) {
            revert ERC20HAlreadySetMirror(_mirror);
        }
        _mirror = mirror_;
    }

    function _setUnlockCooldown(uint96 unlockCooldown_) internal virtual {
        _unlockCooldown = unlockCooldown_;
    }

    /**
     * @dev Updates `owner`'s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _lockAndMint(address owner, uint256 value) internal virtual {
        _lock(owner, value);

        uint256 bondedAmtStart = _balances[owner].bonded;

        IERC20HMirror iMirror = IERC20HMirror(_mirror);

        (uint256 mintableTokens, uint256 toBond) = iMirror.getMintableNumberOfTokens(value);
        uint256[] memory tokenIdsToMint = iMirror.getMintableTokenIds(mintableTokens, toBond);

        for (uint256 i = 0; i < tokenIdsToMint.length;) {
            uint256 tokenId;
            unchecked {
                tokenId = tokenIdsToMint[i];
                i += 1;
            }

            iMirror.bond(owner, tokenId);
        }

        uint256 bondedAmtEnd = _balances[owner].bonded;
        uint256 bondedAmtExpected = bondedAmtStart + toBond;
        if (bondedAmtEnd != bondedAmtExpected) {
            revert ERC20HIncorrectAmountBonded(bondedAmtExpected, bondedAmtEnd);
        }
    }

    /**
     * @dev Updates `owner`'s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _lock(address owner, uint256 value) internal virtual {
        AddressBalances storage balances = _balances[owner];

        uint256 ownerBalance = balances.total;
        if (ownerBalance < value) {
            revert ERC20InsufficientBalance(owner, ownerBalance, value);
        }

        // make sure there are even enough tokens to lock up
        uint256 bondedOrUnlockingBalance = balances.bonded + balances.unlocking;
        uint256 ownerUnbondedBalance = ownerBalance - bondedOrUnlockingBalance;
        if (ownerUnbondedBalance < value) {
            revert ERC20HInsufficientUnbondedBalance(owner, ownerUnbondedBalance, value);
        }

        // check that the new lock total is at least as much as how much is currently locked
        uint256 unbondedLockedBalance = balances.locked - bondedOrUnlockingBalance;
        if (value < unbondedLockedBalance) {
            revert ERC20HCannotLockNegativeBalance(owner, unbondedLockedBalance, value);
        }

        unchecked {
            balances.locked = value + bondedOrUnlockingBalance;
        }
    }

    /**
     * @dev Updates `owner`'s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _unlock(address owner, uint256 value) internal virtual {
        AddressBalances storage balances = _balances[owner];

        uint256 ownerLockedBalance = balances.locked - balances.unlocking;
        if (ownerLockedBalance < value) {
            revert ERC20HInsufficientLockedBalance(owner, ownerLockedBalance, value);
        }

        uint256 ownerUnbondedBalance = ownerLockedBalance - balances.bonded;
        if (ownerUnbondedBalance < value) {
            revert ERC20HInsufficientUnbondedBalance(owner, ownerUnbondedBalance, value);
        }

        if (_unlockCooldown > 0) {
            uint128 nextIndex = balances.numIndexes;
            uint128 indexOfLatest = balances.indexOfLatest;
            balances.unlockingTokens[nextIndex] = UnlockingTokens(
                value, // amount
                block.number + uint256(_unlockCooldown), // releaseBlock
                indexOfLatest, // prevIndex
                0 // nextIndex
            );
            if (nextIndex > 0) {
                // if there are previous records, we should point the latest record to
                // the next index
                balances.unlockingTokens[indexOfLatest].nextIndex = nextIndex;
            }
            balances.indexOfLatest = nextIndex;
            balances.numIndexes = nextIndex + 1;
            balances.unlocking += value;
        } else {
            // no cooldown. unlock the funds immediately
            unchecked {
                balances.locked -= value;
            }
        }

        // require(value >= 1000, string.concat('Debug: ', uint256(balances.indexOfLatest).toString()));
    }

    /**
     * @dev Updates `owner`'s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _releaseUnlockingTokens(address owner, uint128 numToRelease) internal virtual {
        AddressBalances storage balances = _balances[owner];

        if (balances.numIndexes == 0) {
            return; // all unlocking tokens have been released. nothing to do
        }

        if (numToRelease == 0) {
            // if `numToRelease` is 0, then we assume user wishes to release all tranches.
            _releaseUnlockingTokensRecursive(owner, type(uint128).max);
        } else {
            _releaseUnlockingTokensRecursive(owner, numToRelease);
        }
    }

    function _releaseUnlockingTokensRecursive(address owner, uint128 numToRelease) internal virtual {
        AddressBalances storage balances = _balances[owner];

        if (balances.numIndexes == 0) {
            return; // no more tokens awaiting unlock
        }

        UnlockingTokens storage t = balances.unlockingTokens[0];
        // require(numToRelease > 952, string.concat('Debug: trancheAmount=', uint256(t.amount).toString()));
        if (t.releaseBlock > block.number) {
            // If the releaseBlock is greater than the current block, then
            // there are no more token ready to be released and we can
            // terminate now.
            return;
        }

        uint256 amt = t.amount;
        uint128 nextIndex = t.nextIndex;
        uint128 greatestIndex;
        unchecked {
            balances.locked -= amt;
            balances.unlocking -= amt;
            greatestIndex = balances.numIndexes - 1;
            balances.numIndexes = greatestIndex;
        }

        if (nextIndex > 0) {
            // `nextIndex` greater than zero means there are other records linked.

            // Move nextIndex record to index 0
            UnlockingTokens memory nextT = balances.unlockingTokens[nextIndex];
            nextT.prevIndex = 0;
            balances.unlockingTokens[nextT.nextIndex].prevIndex = 0;
            balances.unlockingTokens[0] = nextT;

            // If greatest indexed item was not just moved, move the greatest indexed item to
            // nextIndex. We will point its previous-item record to the new index.
            if (greatestIndex != nextIndex) {
                UnlockingTokens memory greatestT = balances.unlockingTokens[greatestIndex];
                balances.unlockingTokens[greatestT.prevIndex].nextIndex = nextIndex;
                // If greatest indexed item is not the last item, then we should update its
                // next-item record to point to the new index
                if (greatestT.nextIndex != 0) {
                    balances.unlockingTokens[greatestT.nextIndex].prevIndex = nextIndex;
                }
                balances.unlockingTokens[nextIndex] = greatestT;
            }

            // Update indexOfLatest if it just got moved
            if (greatestIndex == balances.indexOfLatest) {
                if (greatestIndex == nextIndex) {
                    balances.indexOfLatest = 0; // it got moved to index 0
                } else {
                    balances.indexOfLatest = nextIndex;
                }
            }
        }

        // Cleanup `greatestIndex`
        delete balances.unlockingTokens[greatestIndex];

        if (numToRelease <= 1) {
            return; // already released all tokens as requested
        }
        unchecked { numToRelease -= 1; }
        _releaseUnlockingTokensRecursive(owner, numToRelease);
    }

    function _bond(address owner, uint256 value) internal virtual {
        AddressBalances storage balances = _balances[owner];

        uint256 bonded = balances.bonded + value;
        uint256 availableToBond;
        unchecked {
            availableToBond = balances.locked - balances.unlocking;    
        }

        if (bonded > availableToBond) {
            revert ERC20HInsufficientUnbondedBalance(owner, availableToBond, bonded);
        }

        balances.bonded = bonded;
    }

    /**
     * @dev Updates `owner`'s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _unbond(address owner, uint256 value) internal virtual {
        AddressBalances storage balances = _balances[owner];

        uint256 ownerBoundedBalance = balances.bonded;
        if (ownerBoundedBalance < value) {
            revert ERC20HInsufficientBondedBalance(owner, ownerBoundedBalance, value);
        }

        unchecked {
            balances.bonded -= value;
        }
    }

    /**
     * @dev Updates `owner`'s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _unbondAndUnlock(address owner, uint256 value) internal virtual {
        AddressBalances storage balances = _balances[owner];

        uint256 ownerBoundedBalance = balances.bonded;
        if (ownerBoundedBalance < value) {
            revert ERC20HInsufficientBondedBalance(owner, ownerBoundedBalance, value);
        }

        unchecked {
            balances.bonded -= value;
            // automatically unlock immediately the unbonded tokens
            balances.locked -= value;
        }
    }
}
