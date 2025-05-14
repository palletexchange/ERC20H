# ERC20H: an experimental hybrid token

ERC20H (suffix H is for Hybrid) is a new take on hybrid fungible/nonfungible tokens.

## Motivations

The token aims to solve a couple core problems with fungible tokens:
1. create better incentive-aligned sinks for ERC20s
2. help foster community nucleation through locking + bonding fungible tokens into NFTs

## Mechanics

### Fungible token lockup

Fungible token can be locked up. Locked up tokens continue to appear in the holder's wallet and shows up in their balance. However, the locked up tokens are non-transferrable (unless bonded -- see next mechanic).

### Auto-mint NFTs on lockup

When a user locks up their tokens, their locked tokens automatically tries to mint NFTs. If minted, the NFTs are bonded with the fungible token. Now, when the NFT is transferred, the bonded and locked fungible tokens will move with it.

### Flexible fungible-token-to-NFT conversion

ERC20H can be configured to support multiple fungible-token-to-NFT conversions. For example, admins can simultaneously configure Tier1NFT to be minted with 1,000,000 locked tokens and Tier2NFT to be minted with 100,000 locked tokens. Furthermore, each NFT tier can be configured with its own max supply.

### Burn NFT to release bonded fungible tokens

Once bonded to an NFT, the fungible tokens can only be retrieved by unbonding. Unbonding will burn the NFT and unlock its fungible tokens. If an NFT tier has a max supply, any NFT from that tier that is burned will be permanent.

### Optional unlock cooldown

Tokens that are locked but not bonded to an NFT may have an unlock cooldown set. Once a user begins the unlocking process, they must wait a predetermined amount of time before they can release the tokens and make them available for transfer.
