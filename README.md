# Gluteus Maximus (GLUTEU) Contracts

This repository contains three smart contracts that power the **Gluteus Maximus** ecosystem:

1. **GluteusMaximusToken** (`GLUTEU`) — An ERC20 token with a fixed supply of 1 billion.
2. **SenatorNFTCollection** — An ERC721 NFT collection with a maximum of 500 possible token IDs.
3. **StakingGLUTEU** — A staking contract that allows users to stake 1M `GLUTEU` to mint an NFT, featuring Chainlink VRF integration for random assignment.

> **Note**: The `GluteusMaximusToken` in this repo is a *test* version. The real token was deployed on the [Base](https://base.org/) network by Virtuals with different source code.  
>
> **Litepaper**: For a deeper dive into the Gluteus Maximus vision and mechanics, please see our [Litepaper](https://litepaper.gluteusmaximus.org/).  
>
> **GitHub Repo**: [https://github.com/theconsulgm/gluteus-maximus/tree/main](https://github.com/theconsulgm/gluteus-maximus/tree/main)

---

## Overview

- **GluteusMaximusToken (ERC20)**  
  - Symbol: `GLUTEU`  
  - Decimals: 18  
  - Fixed supply of **1,000,000,000** tokens minted to the deployer.  
  - Uses `Ownable` for ownership control (note the custom constructor that calls `Ownable(msg.sender)`).

- **SenatorNFTCollection (ERC721)**  
  - Symbol: `SNFT`  
  - Maximum supply: 500 unique token IDs (`1..500`).  
  - Minting and burning are **restricted** to the designated staking contract (`stakingContract`).  
  - Includes a configurable base URI for metadata.

- **StakingGLUTEU (Chainlink VRF Integration)**  
  - Users stake **1,000,000 `GLUTEU`** to request a random NFT ID from the remaining pool.  
  - If VRF is delayed or never arrives, the user can unstake without minting any NFT.  
  - If the pool of NFTs is exhausted, the staker is automatically refunded.  
  - After an NFT is minted, the staked `GLUTEU` can only be reclaimed by burning the NFT **after** a configurable `waitPeriod`.

---

## Key Mechanics

1. **Stake & VRF Request**  
   - `stakeAndGetNFT()` transfers **1M GLUTEU** from the user to the contract.  
   - A Chainlink VRF request is initiated to obtain a random number.

2. **Chainlink VRF Fulfillment**  
   - `fulfillRandomWords()` is called by the VRF Coordinator, storing the random result on-chain.  
   - The contract does not mint immediately to avoid potential out-of-gas scenarios.

3. **Claim or Refund**  
   - `claimNFT(requestId)` finalizes the staking process.  
   - If there are available NFT IDs, the user mints a random ID from the pool.  
   - If no IDs remain, the user is **immediately refunded** the 1M tokens.

4. **Unstake if VRF Fails**  
   - `unstakeNoNFT(requestId)` allows the user to recover staked tokens if VRF is never fulfilled.

5. **Burn NFT to Unstake**  
   - Once the NFT is minted, the user (or current NFT holder) must wait `waitPeriod` seconds.  
   - `unstakeAndBurnNFT(tokenId)` then burns the NFT and returns the 1M staked tokens, returning the token ID to the pool.

---

## Audit Information

These contracts were audited by **Verichains**. The **only recommendation** provided was graded as *informative* (very low or no risk). Specifically, Verichains advised using `safeTransfer` for the token transfers in `StakingGLUTEU.sol`, which we have **fully implemented**. After addressing this minor suggestion, Verichains gave **final approval** to these contracts.

---
