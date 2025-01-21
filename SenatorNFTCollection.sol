// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SenatorNFTCollection
 * @notice ERC721 collection with max 500 unique IDs (1..500).
 *         Only a specific staking contract can mint/burn.
 *
 * Author: The Consul @ Gluteus Maximus
 */
contract SenatorNFTCollection is ERC721, Ownable {
    // Maximum supply of 500 NFTs
    uint256 public constant MAX_SUPPLY = 500;

    // Tracks if a tokenId is currently minted
    mapping(uint256 => bool) public isMinted;

    // Staking contract address that can mint/burn
    address public stakingContract;

    // Base URI for metadata
    string private baseURIextended;

    /**
     * @notice Constructor for older/custom Ownable requires msg.sender
     * @param initialBaseURI The initial base URI for metadata
     */
    constructor(string memory initialBaseURI)
        ERC721("SenatorNFTCollection", "SNFT")
        Ownable(msg.sender)
    {
        baseURIextended = initialBaseURI;
    }

    /**
     * @notice Set the staking contract address, only owner can do this.
     */
    function setStakingContract(address _stakingContract) external onlyOwner {
        stakingContract = _stakingContract;
    }

    /**
     * @notice Mint a specific tokenId to `to`. Only the stakingContract can call this.
     */
    function mintWithId(address to, uint256 tokenId) external {
        require(msg.sender == stakingContract, "Not authorized to mint");
        require(tokenId >= 1 && tokenId <= MAX_SUPPLY, "Invalid tokenId");
        require(!isMinted[tokenId], "Token already minted");

        isMinted[tokenId] = true;
        _safeMint(to, tokenId);
    }

    /**
     * @notice Burn a specific tokenId. Only the stakingContract can call this.
     */
    function burnWithId(uint256 tokenId) external {
        require(msg.sender == stakingContract, "Not authorized to burn");
        // Optional: verify correct ownership
        require(ownerOf(tokenId) == tx.origin || ownerOf(tokenId) == msg.sender, "Not owner");

        isMinted[tokenId] = false;
        _burn(tokenId);
    }

    /**
     * @dev Internal function returning the base URI for all tokens
     */
    function _baseURI() internal view virtual override returns (string memory) {
        return baseURIextended;
    }

    /**
     * @notice Update the base URI, only owner.
     */
    function setBaseURI(string memory _newBaseURI) external onlyOwner {
        baseURIextended = _newBaseURI;
    }
}
