// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

struct AddTierParam {
    uint128 units;
    uint32 maxSupply;
    string uri;
}

interface IERC20HMirror is IERC721 {
	function getMintableNumberOfTokens(uint256 value) external view returns (uint256, uint256);

	function getMintableTokenIds(uint256 numTokens, uint256 value) external view returns (uint256[] memory);

	function bond(address to, uint256 tokenId) external;

	function unbond(uint256 tokenId) external;

	function addTiers(AddTierParam[] calldata tierParams) external;

	function setActiveTiers(uint16[] calldata tierIds) external;

	function removeTier(uint16 tierId) external;
}
