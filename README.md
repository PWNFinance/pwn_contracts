# PWN Finance
Smart contracts enabling p2p loans using arbitrary collateral (supporting ERC20, ERC721, ERC1155 standards).

## Architecture

### PWN (logic)
PWN is the core interface users are expected to use (also the only interactive contract allowing for premissionless external calls). 
The contract defines the workflow functionality and handles the market making. Allowing to:
- Create and revoke Deeds 
- Make, revoke or accept credit offers 
- Pay back loans
- Claim collateral or credit

### PWN Deed 
PWN Deed is an PWN contextual extension of a standard ERC1155 token. Each Deed is defined as an ERC1155 NFT. 
The PWN Deed contract allows for reading the contextual information of the Deeds (like status, expirations, etc.) 
but all of its contract features can only be called through the PWN (logic) contract. 

### PWN Vault
PWN Vault is the holder contract for the locked in collateral and paid back credit.
The contract can only be operated through the PWN (logic) contract. 
All approval of tokens utilized within the PWN context has to be done towards the PWN Vault address - 
as ultimately it's the contract accessing the tokens. 

### MultiToken library
The library defines a token asset as a struct of token identifiers. 
It wraps transfer, allowance & balance check calls of the following token standards:
- ERC20
- ERC721 
- ERC1155

Unifying the function calls used within the PWN context (not having to worry about handling those individually).


## Deployment

For deployment procedure see `./scripts/deploy-PWN-only.js`
NOTE: you will have to use your own deployment key. Simples optino is to create a following .json which is assumed
to exist for Kovan testnet deployment - in the root folder:
create `.keys/PRIVATE.json`
with the following content:
```
{
  "key1": "<insert your raw private key here>"
}
```