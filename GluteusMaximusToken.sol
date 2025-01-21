// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/*
    Test token, the real one was deployed by Virtuals on BASE with different source code

*/
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GluteusMaximusToken
 * @notice ERC20 token with a fixed supply of 1 billion tokens.
 *         Symbol: GLUTEU
 *         Decimals: 18
 *
 * In older/custom Ownable implementations, we must call Ownable(msg.sender).
 */
contract GluteusMaximusToken is ERC20, Ownable {
    constructor() ERC20("Gluteus Maximus by Virtuals", "GLUTEU") Ownable(msg.sender) {
        // Mint 1,000,000,000 tokens (multiplied by 10^18 for decimals)
        _mint(msg.sender, 1_000_000_000 * 10**decimals());
    }
}
