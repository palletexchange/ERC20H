// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC721/ERC721.sol)

pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {ERC721Utils} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Utils.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC165, ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20H} from "./interfaces/IERC20H.sol";
import {AddTierParam, IERC20HMirror} from "./interfaces/IERC20HMirror.sol";

/**
 * @dev Implementation of https://eips.ethereum.org/EIPS/eip-721[ERC-721] Non-Fungible Token Standard, including
 * the Metadata extension, but not including the Enumerable extension, which is available separately as
 * {ERC721Enumerable}.
 */
abstract contract ERC20HMirror is Context, Ownable, ERC165, IERC721, IERC721Metadata, IERC721Errors, IERC20HMirror {
    using Strings for uint256;

    struct TokenInfo {
        address owner;
        uint16 tierId;
    }

    struct TierInfo {
        bytes32 uriHash;
        uint32 nextTokenIdSuffix;
        uint32 maxSupply;
        uint32 totalSupply;
        uint128 units;
        uint16 tierId;
        bool active;
    }

    // ERC20 contract
    address public immutable hybrid;

    // Token name
    string private _name;

    // Token symbol
    string private _symbol;

    uint64 private _totalSupply;

    uint16 private _nextTierId;

    mapping(uint256 tokenId => TokenInfo) private _tokens;

    mapping(address owner => uint256) private _balances;

    mapping(uint256 tokenId => address) private _tokenApprovals;

    mapping(address owner => mapping(address operator => bool)) private _operatorApprovals;

    mapping(uint16 tierId => TierInfo) private _tiers;

    mapping(bytes32 uriHash => string) private _uris;

    uint16[] private _activeTiers;

    error ERC20HMirrorTierHasNoUnits();

    error ERC20HMirrorTierHasZeroSupply();

    error ERC20HMirrorTierDoesNotExist(uint16 tierId);

    error ERC20HMirrorActiveTiersMustBeInDescendingOrder();

    error ERC20HMirrorDuplicateActiveTier(uint16 tierId);

    error ERC20HMirrorCannotDeleteTierWithTokens(uint16 tierId, uint32 totalSupply);

    error ERC20HMirrorInvalidTokenId(uint256 tokenId);

    error ERC20HMirrorExceedsMaxSupplyForTier(uint16 tierId, uint256 tokenId);

    error ERC20HMirrorInvalidTokenIdForTier(uint16 tierId, uint256 tokenId);

    error ERC20HMirrorHybridContractNotLinked();

    error ERC20HMirrorFailedToReleaseBondedTokens(uint256 tokenId);

    error ERC20HMirrorFailedToBondTokens(uint256 tokenId);

    error ERC20HMirrorFailedToTransferBondedTokens(uint256 tokenId, address from, address to);

    error ERC20HMirrorAccessOnlyForHybrid();

    /**
     * @dev Gate bidding functionality if bids are not enabled
     */
    modifier hybridOnly() {
        if (!_msgSenderIsHybrid()) {
            revert ERC20HMirrorAccessOnlyForHybrid();
        }

        _;
    }

    /**
     * @dev Initializes the contract by setting a `name` and a `symbol` to the token collection.
     */
    constructor(address initialOwner_, address hybrid_) Ownable(initialOwner_) {
        if (hybrid_ == address(0)) {
            revert ERC20HMirrorHybridContractNotLinked();
        }
        hybrid = hybrid_;

        IERC20Metadata h = IERC20Metadata(hybrid_);
        _name = h.name();
        _symbol = h.symbol();
    }

    function addTiers(AddTierParam[] calldata tierParams) external virtual onlyOwner {
        _addTiers(tierParams);
    }

    function removeTier(uint16 tierId) external virtual onlyOwner {
        _removeTier(tierId);
    }

    function setActiveTiers(uint16[] calldata tierIds) external virtual onlyOwner {
        _clearActiveTiers();
        _setActiveTiers(tierIds);
    }

    function bond(address to, uint256 tokenId) external virtual hybridOnly {
        _safeMint(to, tokenId);
    }

    function unbond(uint256 tokenId) external virtual {
        _requireOwned(tokenId);

        _updateAndReleaseAndUnlock(tokenId, _msgSender());
    }

    function getActiveTiers() external view virtual returns (uint16[] memory) {
        return _activeTiers;
    }

    function getMintableNumberOfTokens(uint256 backing) external view virtual returns (uint256, uint256) {
        (uint256 mintableNumTokens, uint256 amtNeededToBond) = _getMintableNumberOfTokens(backing);
        return (mintableNumTokens, amtNeededToBond);
    }

    function getMintableTokenIds(uint256 numTokens, uint256 backing) external view virtual returns (uint256[] memory) {
        return _getMintableTokenIds(numTokens, backing);
    }

    function totalSupply() public view virtual returns (uint256) {
        return uint256(_totalSupply);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                          IERC721                           */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IERC721
    function balanceOf(address owner) public view virtual returns (uint256) {
        if (owner == address(0)) {
            revert ERC721InvalidOwner(address(0));
        }
        return _balances[owner];
    }

    /// @inheritdoc IERC721
    function ownerOf(uint256 tokenId) public view virtual returns (address) {
        return _requireOwned(tokenId);
    }

    /// @inheritdoc IERC721Metadata
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /// @inheritdoc IERC721Metadata
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /// @inheritdoc IERC721Metadata
    function tokenURI(uint256 tokenId) public view virtual returns (string memory) {
        _requireOwned(tokenId);
        uint16 tokenTierId = _getTierIdForToken(tokenId);
        bytes32 uriHash = _getTierUnsafe(tokenTierId).uriHash;
        string memory uri = _getUri(uriHash);

        // Token uris are only keyed on the final 32 bits of the token id. So we
        // convert to uint32 in order to clear out any leading bits.
        return bytes(uri).length > 0 ? string.concat(uri, uint256(uint32(tokenId)).toString()) : "";
    }

    /// @inheritdoc IERC721
    function approve(address to, uint256 tokenId) public virtual {
        _approve(to, tokenId, _msgSender());
    }

    /// @inheritdoc IERC721
    function getApproved(uint256 tokenId) public view virtual returns (address) {
        _requireOwned(tokenId);

        return _getApproved(tokenId);
    }

    /// @inheritdoc IERC721
    function setApprovalForAll(address operator, bool approved) public virtual {
        _setApprovalForAll(_msgSender(), operator, approved);
    }

    /// @inheritdoc IERC721
    function isApprovedForAll(address owner, address operator) public view virtual returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    /// @inheritdoc IERC721
    function transferFrom(address from, address to, uint256 tokenId) public virtual {
        if (to == address(0)) {
            revert ERC721InvalidReceiver(address(0));
        }
        // Setting an "auth" arguments enables the `_isAuthorized` check which verifies that the token exists
        // (from != 0). Therefore, it is not needed to verify that the return value is not 0 here.
        address previousOwner = _updateAndTransfer(to, tokenId, _msgSender());
        if (previousOwner != from) {
            revert ERC721IncorrectOwner(from, tokenId, previousOwner);
        }
    }

    /// @inheritdoc IERC721
    function safeTransferFrom(address from, address to, uint256 tokenId) public {
        safeTransferFrom(from, to, tokenId, "");
    }

    /// @inheritdoc IERC721
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public virtual {
        transferFrom(from, to, tokenId);
        ERC721Utils.checkOnERC721Received(_msgSender(), from, to, tokenId, data);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                         ERC721 INTERNALS                           */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /**
     * @dev Returns the owner of the `tokenId`. Does NOT revert if token doesn't exist
     *
     * IMPORTANT: Any overrides to this function that add ownership of tokens not tracked by the
     * core ERC-721 logic MUST be matched with the use of {_increaseBalance} to keep balances
     * consistent with ownership. The invariant to preserve is that for any address `a` the value returned by
     * `balanceOf(a)` must be equal to the number of tokens such that `_ownerOf(tokenId)` is `a`.
     */
    function _ownerOf(uint256 tokenId) internal view virtual returns (address) {
        return _tokens[tokenId].owner;
    }

    /**
     * @dev Returns the approved address for `tokenId`. Returns 0 if `tokenId` is not minted.
     */
    function _getApproved(uint256 tokenId) internal view virtual returns (address) {
        return _tokenApprovals[tokenId];
    }

    /**
     * @dev Returns whether `spender` is allowed to manage `owner`'s tokens, or `tokenId` in
     * particular (ignoring whether it is owned by `owner`).
     *
     * WARNING: This function assumes that `owner` is the actual owner of `tokenId` and does not verify this
     * assumption.
     */
    function _isAuthorized(address owner, address spender, uint256 tokenId) internal view virtual returns (bool) {
        return
            spender != address(0) &&
            (owner == spender || isApprovedForAll(owner, spender) || _getApproved(tokenId) == spender);
    }

    /**
     * @dev Checks if `spender` can operate on `tokenId`, assuming the provided `owner` is the actual owner.
     * Reverts if:
     * - `spender` does not have approval from `owner` for `tokenId`.
     * - `spender` does not have approval to manage all of `owner`'s assets.
     *
     * WARNING: This function assumes that `owner` is the actual owner of `tokenId` and does not verify this
     * assumption.
     */
    function _checkAuthorized(address owner, address spender, uint256 tokenId) internal view virtual {
        if (!_isAuthorized(owner, spender, tokenId)) {
            if (owner == address(0)) {
                revert ERC721NonexistentToken(tokenId);
            } else {
                revert ERC721InsufficientApproval(spender, tokenId);
            }
        }
    }

    /**
     * @dev Unsafe write access to the balances, used by extensions that "mint" tokens using an {ownerOf} override.
     *
     * NOTE: the value is limited to type(uint128).max. This protect against _balance overflow. It is unrealistic that
     * a uint256 would ever overflow from increments when these increments are bounded to uint128 values.
     *
     * WARNING: Increasing an account's balance using this function tends to be paired with an override of the
     * {_ownerOf} function to resolve the ownership of the corresponding tokens so that balances and ownership
     * remain consistent with one another.
     */
    function _increaseBalance(address account, uint128 value) internal virtual {
        unchecked {
            _balances[account] += value;
        }
    }

    /**
     * @dev Transfers `tokenId` from its current owner to `to`, or alternatively mints (or burns) if the current owner
     * (or `to`) is the zero address. Returns the owner of the `tokenId` before the update.
     *
     * The `auth` argument is optional. If the value passed is non 0, then this function will check that
     * `auth` is either the owner of the token, or approved to operate on the token (by the owner).
     *
     * Emits a {Transfer} event.
     *
     * NOTE: If overriding this function in a way that tracks balances, see also {_increaseBalance}.
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual returns (address) {
        TokenInfo storage info = _tokens[tokenId];
        address from = info.owner;

        // Perform (optional) operator check
        if (auth != address(0)) {
            _checkAuthorized(from, auth, tokenId);
        }

        // Execute the update
        if (from != address(0)) {
            // Clear approval. No need to re-authorize or emit the Approval event
            _approve(address(0), tokenId, address(0), false);

            unchecked {
                _balances[from] -= 1;
            }
        } else {
            // Mint. check that tokenId is valid, and set the corresponding tier id
            uint16 tierId = _checkTokenIdIsValid(tokenId);
            info.tierId = tierId;

            TierInfo storage tier = _getTierUnsafe(tierId);

            // Update counters
            tier.nextTokenIdSuffix += 1;
            tier.totalSupply += 1;
            unchecked {
                // type(_totalSupply).max > type(tier.totalSupply).max * type(_nextTierId).max
                _totalSupply += 1;
            }
        }

        if (to != address(0)) {
            unchecked {
                _balances[to] += 1;
            }
        } else {
            unchecked {
                _tiers[info.tierId].totalSupply -= 1;
                _totalSupply -= 1;
            }
        }

        info.owner = to;

        emit Transfer(from, to, tokenId);

        return from;
    }

    /**
     * @dev Mints `tokenId` and transfers it to `to`.
     *
     * WARNING: Usage of this method is discouraged, use {_safeMint} whenever possible
     *
     * Requirements:
     *
     * - `tokenId` must not exist.
     * - `to` cannot be the zero address.
     *
     * Emits a {Transfer} event.
     */
    function _mint(address to, uint256 tokenId) internal {
        if (to == address(0)) {
            revert ERC721InvalidReceiver(address(0));
        }
        _mintAndBond(to, tokenId, address(0));
    }

    /**
     * @dev Mints `tokenId`, transfers it to `to` and checks for `to` acceptance.
     *
     * Requirements:
     *
     * - `tokenId` must not exist.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function _safeMint(address to, uint256 tokenId) internal {
        _safeMint(to, tokenId, "");
    }

    /**
     * @dev Same as {xref-ERC721-_safeMint-address-uint256-}[`_safeMint`], with an additional `data` parameter which is
     * forwarded in {IERC721Receiver-onERC721Received} to contract recipients.
     */
    function _safeMint(address to, uint256 tokenId, bytes memory data) internal virtual {
        _mint(to, tokenId);
        ERC721Utils.checkOnERC721Received(_msgSender(), address(0), to, tokenId, data);
    }

    /**
     * @dev Destroys `tokenId`.
     * The approval is cleared when the token is burned.
     * This is an internal function that does not check if the sender is authorized to operate on the token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     *
     * Emits a {Transfer} event.
     */
    function _burn(uint256 tokenId) internal {
        address previousOwner = _updateAndTransfer(address(0), tokenId, address(0));
        if (previousOwner == address(0)) {
            revert ERC721NonexistentToken(tokenId);
        }
    }

    /**
     * @dev Transfers `tokenId` from `from` to `to`.
     *  As opposed to {transferFrom}, this imposes no restrictions on msg.sender.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     *
     * Emits a {Transfer} event.
     */
    function _transfer(address from, address to, uint256 tokenId) internal {
        if (to == address(0)) {
            revert ERC721InvalidReceiver(address(0));
        }
        address previousOwner = _updateAndTransfer(to, tokenId, address(0));
        if (previousOwner == address(0)) {
            revert ERC721NonexistentToken(tokenId);
        } else if (previousOwner != from) {
            revert ERC721IncorrectOwner(from, tokenId, previousOwner);
        }
    }

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`, checking that contract recipients
     * are aware of the ERC-721 standard to prevent tokens from being forever locked.
     *
     * `data` is additional data, it has no specified format and it is sent in call to `to`.
     *
     * This internal function is like {safeTransferFrom} in the sense that it invokes
     * {IERC721Receiver-onERC721Received} on the receiver, and can be used to e.g.
     * implement alternative mechanisms to perform token transfer, such as signature-based.
     *
     * Requirements:
     *
     * - `tokenId` token must exist and be owned by `from`.
     * - `to` cannot be the zero address.
     * - `from` cannot be the zero address.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function _safeTransfer(address from, address to, uint256 tokenId) internal {
        _safeTransfer(from, to, tokenId, "");
    }

    /**
     * @dev Same as {xref-ERC721-_safeTransfer-address-address-uint256-}[`_safeTransfer`], with an additional `data` parameter which is
     * forwarded in {IERC721Receiver-onERC721Received} to contract recipients.
     */
    function _safeTransfer(address from, address to, uint256 tokenId, bytes memory data) internal virtual {
        _transfer(from, to, tokenId);
        ERC721Utils.checkOnERC721Received(_msgSender(), from, to, tokenId, data);
    }

    /**
     * @dev Approve `to` to operate on `tokenId`
     *
     * The `auth` argument is optional. If the value passed is non 0, then this function will check that `auth` is
     * either the owner of the token, or approved to operate on all tokens held by this owner.
     *
     * Emits an {Approval} event.
     *
     * Overrides to this logic should be done to the variant with an additional `bool emitEvent` argument.
     */
    function _approve(address to, uint256 tokenId, address auth) internal {
        _approve(to, tokenId, auth, true);
    }

    /**
     * @dev Variant of `_approve` with an optional flag to enable or disable the {Approval} event. The event is not
     * emitted in the context of transfers.
     */
    function _approve(address to, uint256 tokenId, address auth, bool emitEvent) internal virtual {
        // Avoid reading the owner unless necessary
        if (emitEvent || auth != address(0)) {
            address owner = _requireOwned(tokenId);

            // We do not use _isAuthorized because single-token approvals should not be able to call approve
            if (auth != address(0) && owner != auth && !isApprovedForAll(owner, auth)) {
                revert ERC721InvalidApprover(auth);
            }

            if (emitEvent) {
                emit Approval(owner, to, tokenId);
            }
        }

        _tokenApprovals[tokenId] = to;
    }

    /**
     * @dev Approve `operator` to operate on all of `owner` tokens
     *
     * Requirements:
     * - operator can't be the address zero.
     *
     * Emits an {ApprovalForAll} event.
     */
    function _setApprovalForAll(address owner, address operator, bool approved) internal virtual {
        if (operator == address(0)) {
            revert ERC721InvalidOperator(operator);
        }
        _operatorApprovals[owner][operator] = approved;
        emit ApprovalForAll(owner, operator, approved);
    }

    /**
     * @dev Reverts if the `tokenId` doesn't have a current owner (it hasn't been minted, or it has been burned).
     * Returns the owner.
     *
     * Overrides to ownership logic should be done to {_ownerOf}.
     */
    function _requireOwned(uint256 tokenId) internal view returns (address) {
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) {
            revert ERC721NonexistentToken(tokenId);
        }
        return owner;
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                      ERC20HMIRROR INTERNALS                        */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    function _addTiers(AddTierParam[] calldata tierParams) internal virtual {
        require(tierParams.length <= type(uint16).max, 'Too many tiers');
        uint16 numParams = uint16(tierParams.length);
        require(numParams > 0, 'No tiers to add');

        uint16 endTierId = _nextTierId + uint16(tierParams.length); // catches overflows
        uint16 curTierId = _nextTierId;

        for (uint16 i = 0; i < numParams;) {
            AddTierParam calldata param = tierParams[i];
            bytes32 uriHash = keccak256(bytes(param.uri));

            uint16 tierId;
            unchecked {
                tierId = curTierId + i;
                i += 1;
            }

            if (param.units == 0) {
                revert ERC20HMirrorTierHasNoUnits();
            }
            if (param.maxSupply == 0) {
                revert ERC20HMirrorTierHasZeroSupply();
            }

            _tiers[tierId] = TierInfo(
                uriHash, // uriHash (bytes32)
                0, // nextTokenIdSuffix (uint32)
                param.maxSupply, // maxSupply (uint32)
                0, // totalSupply (uint32)
                param.units, // units (uint128)
                tierId, // tierId (uint16)
                false
            );
            _uris[uriHash] = param.uri;
        }

        _nextTierId = endTierId;
    }

    function _removeTier(uint16 tierId) internal virtual {
        uint32 maxSupply = _tiers[tierId].maxSupply;
        // tier only exists if has maxSupply > 0
        if (maxSupply == 0) {
            revert ERC20HMirrorTierDoesNotExist(tierId);
        }

        uint32 tierSupply = _tiers[tierId].totalSupply;
        // tier cannot be removed if there are already tokens minted in it
        if (tierSupply > 0) {
            revert ERC20HMirrorCannotDeleteTierWithTokens(tierId, tierSupply);
        }

        delete _tiers[tierId];
    }

    function _clearActiveTiers() internal virtual {
        for (uint256 i = 0; i < _activeTiers.length;) {
            _tiers[_activeTiers[i]].active = false;

            unchecked { i += 1; }
        }

        delete _activeTiers;
    }

    function _setActiveTiers(uint16[] calldata tierIds) internal virtual {
        uint128 cur = type(uint128).max;

        // validate tierIds:
        // 1) tier ids are for real tiers
        // 2) tier ids are sorted by their units, descending
        for (uint256 i = 0; i < tierIds.length;) {
            TierInfo storage ti = _getTierUnsafe(tierIds[i]);

            uint128 units = ti.units;

            if (units == 0) {
                revert ERC20HMirrorTierDoesNotExist(tierIds[i]);
            } else if (units > cur) {
                revert ERC20HMirrorActiveTiersMustBeInDescendingOrder();
            } else if (ti.active) {
                revert ERC20HMirrorDuplicateActiveTier(tierIds[i]);
            }

            ti.active = true;
            cur = units;

            unchecked { i += 1; }
        }

        _activeTiers = tierIds;
    }

    function _updateAndReleaseAndUnlock(uint256 tokenId, address auth) internal virtual returns (address, uint256) {
        // number of tokens represented by tokenId)
        uint256 bondedUnits = _getUnitsForTier(_getTierIdForToken(tokenId));

        // must burn to release tokens
        address from = _update(address(0), tokenId, auth);

        IERC20H(hybrid).onERC20HUnbonded(from, bondedUnits);

        return (from, bondedUnits);
    }

    function _mintAndBond(address to, uint256 tokenId, address auth) internal virtual returns (address) {
        address previousOwner = _update(to, tokenId, auth);

        if (previousOwner != address(0)) {
            revert ERC721InvalidSender(address(0));
        }

        // number of tokens represented by tokenId
        uint256 bondedUnits = _getUnitsForTier(_getTierIdForToken(tokenId));

        IERC20H(hybrid).onERC20HBonded(to, bondedUnits);

        return previousOwner;
    }

    function _updateAndTransfer(address to, uint256 tokenId, address auth) internal virtual returns (address) {
        // number of tokens represented by tokenId)
        uint256 bondedUnits = _getUnitsForTier(_getTierIdForToken(tokenId));

        address from = _update(to, tokenId, auth);

        if (!IERC20H(hybrid).transferFrom(from, to, bondedUnits)) {
            revert ERC20HMirrorFailedToTransferBondedTokens(tokenId, from, to);
        }

        return from;
    }

    function _getMintableNumberOfTokens(uint256 backing) internal view virtual returns (uint256, uint256) {
        uint256 numActiveTiers = _activeTiers.length;
        uint256 cur;
        uint256 numTokens;
        uint256 remaining = backing;

        while (cur < numActiveTiers && backing > 0) {
            uint16 tierId;
            unchecked { tierId = _activeTiers[cur]; }

            TierInfo storage tierInfo = _getTierUnsafe(tierId);

            uint256 tierUnits = uint256(tierInfo.units);

            if (remaining < tierUnits) {
                unchecked { cur += 1; }
                continue; // move on to the next tier
            }

            uint256 remainingSupply;
            uint256 multiple;
            unchecked {
                remainingSupply = uint256(tierInfo.maxSupply - tierInfo.totalSupply);
                multiple = remaining / tierUnits;
            }
            if (multiple > remainingSupply) {
                multiple = remainingSupply;
            }

            // there are tokens that can be minted from this tier
            if (multiple > 0) {
                unchecked {
                    remaining -= multiple * tierUnits;
                    // backing decreases per iteration. sum of quotients <= sum of dividends
                    numTokens += multiple;
                }
            }

            unchecked { cur += 1; }
        }

        return (numTokens, backing - remaining);
    }

    function _getMintableTokenIds(
        uint256 numTokens,
        uint256 backing
    ) internal view virtual returns (uint256[] memory) {
        uint256[] memory tokenIds = new uint256[](numTokens);
        uint256 numActiveTiers = _activeTiers.length;
        uint256 cur;
        uint256 tokensAdded;
        uint256 remaining = backing;

        while (cur < numActiveTiers && backing > 0 && tokensAdded < numTokens) {
            uint16 tierId;
            unchecked { tierId = _activeTiers[cur]; }

            TierInfo storage tierInfo = _getTierUnsafe(tierId);

            uint256 tierUnits = uint256(tierInfo.units);

            if (remaining < tierUnits) {
                unchecked { cur += 1; }
                continue; // move on to the next tier
            }

            uint256 remainingSupply;
            uint256 multiple;
            unchecked {
                remainingSupply = uint256(tierInfo.maxSupply - tierInfo.totalSupply);
                multiple = remaining / tierUnits;
            }
            if (multiple > remainingSupply) {
                multiple = remainingSupply;
            }

            // there are tokens that can be minted from this tier
            if (multiple > 0) {
                uint256 tokenIdSuffix = uint256(tierInfo.nextTokenIdSuffix);
                uint256 multiplesAdded;

                while (multiplesAdded < multiple && tokensAdded < numTokens) {
                    uint256 nextTokenIdSuffix;
                    unchecked {
                        nextTokenIdSuffix = multiplesAdded + tokenIdSuffix;
                    }

                    uint256 tokenId = _getTokenId(tierId, uint32(nextTokenIdSuffix));

                    unchecked {
                        tokenIds[tokensAdded] = tokenId;
                        multiplesAdded += 1;
                        tokensAdded += 1;
                    }
                }

                unchecked {
                    remaining -= multiplesAdded * tierUnits;
                }
            }

            unchecked { cur += 1; }
        }

        // if there are any unused slots in the array, clean them up
        if (tokensAdded > 0 && tokensAdded < numTokens) {
            uint256 unusedSlots;
            unchecked {
                unusedSlots = numTokens - tokensAdded;
            }
            assembly {
                mstore(tokenIds, sub(mload(tokenIds), unusedSlots))
            }
        }

        return tokenIds;
    }

    function _checkTokenIdIsValid(uint256 tokenId) internal view virtual returns (uint16) {
        // token id is composed of <uint16><uint32>
        if (tokenId >> 48 > 0) {
            // Means there is data beyond the final 48 bits. This is not expected
            revert ERC20HMirrorInvalidTokenId(tokenId);
        }

        uint32 tokenIdSuffix = uint32(tokenId); // keeps only the final 32 bits
        uint16 tierId = uint16(tokenId >> 32);
        TierInfo storage t = _getTierUnsafe(tierId);

        if (t.maxSupply <= tokenIdSuffix) {
            revert ERC20HMirrorExceedsMaxSupplyForTier(tierId, tokenId);
        }

        if (tokenIdSuffix != t.nextTokenIdSuffix) {
            revert ERC20HMirrorInvalidTokenIdForTier(tierId, tokenId);
        }

        return tierId;
    }

    function _getTierIdForToken(uint256 tokenId) internal view virtual returns (uint16) {
        return _tokens[tokenId].tierId;
    }

    function _getUnitsForTier(uint16 tierId) internal view virtual returns (uint256) {
        return uint256(_getTierUnsafe(tierId).units);
    }

    function _getTierUnsafe(uint16 tierId) internal view virtual returns (TierInfo storage) {
        return _tiers[tierId];
    }

    function _getUri(bytes32 uriHash) internal view virtual returns (string memory) {
        return _uris[uriHash];
    }

    function _msgSenderIsHybrid() internal view virtual returns (bool) {
        return _msgSender() == hybrid;
    }

    function _getTokenId(uint16 tierId, uint32 tokenIdSuffix) internal pure virtual returns (uint256) {
        return (uint256(tierId) << 32) | uint256(tokenIdSuffix);
    }
}
