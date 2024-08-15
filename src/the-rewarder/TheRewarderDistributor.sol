// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;
import {Test, console} from "forge-std/Test.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

struct Distribution {
    uint256 remaining;
    uint256 nextBatchNumber;
    mapping(uint256 batchNumber => bytes32 root) roots;
    mapping(address claimer => mapping(uint256 word => uint256 bits)) claims;
}

struct Claim {
    uint256 batchNumber;
    uint256 amount;
    uint256 tokenIndex;
    bytes32[] proof;
}

/**
 * An efficient token distributor contract based on Merkle proofs and bitmaps
 */
contract TheRewarderDistributor {
    using BitMaps for BitMaps.BitMap;

    // @ audit does this work?
    address public immutable owner = msg.sender;

    // Tracks distributions for each token
    mapping(IERC20 token => Distribution) public distributions;

    error StillDistributing();
    error InvalidRoot();
    error AlreadyClaimed();
    error InvalidProof();
    error NotEnoughTokensToDistribute();

    event NewDistribution(
        IERC20 token,
        uint256 batchNumber,
        bytes32 newMerkleRoot,
        uint256 totalAmount
    );

    /**
     * GETTERS
     */
    function getRemaining(address token) external view returns (uint256) {
        return distributions[IERC20(token)].remaining;
    }

    function getNextBatchNumber(address token) external view returns (uint256) {
        return distributions[IERC20(token)].nextBatchNumber;
    }

    function getRoot(
        address token,
        uint256 batchNumber
    ) external view returns (bytes32) {
        return distributions[IERC20(token)].roots[batchNumber];
    }

    /**
     * CREATE DISTRIBUTION
     */

    function createDistribution(
        IERC20 token,
        bytes32 newRoot,
        uint256 amount
    ) external {
        if (amount == 0) revert NotEnoughTokensToDistribute();
        if (newRoot == bytes32(0)) revert InvalidRoot();
        if (distributions[token].remaining != 0) revert StillDistributing();

        // Updates the distribution data
        distributions[token].remaining = amount; // 10 DVT
        uint256 batchNumber = distributions[token].nextBatchNumber; //0
        distributions[token].roots[batchNumber] = newRoot;
        distributions[token].nextBatchNumber++;

        // Transfers tokens to the contract
        SafeTransferLib.safeTransferFrom(
            address(token),
            msg.sender,
            address(this),
            amount
        );

        emit NewDistribution(token, batchNumber, newRoot, amount);
    }

    // Allows the owner to withdraw unclaimed tokens after a distribution is complete
    // @audit - no onlyOwner modifier
    function clean(IERC20[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20 token = tokens[i];
            if (distributions[token].remaining == 0) {
                token.transfer(owner, token.balanceOf(address(this)));
            }
        }
    }

    // Allow claiming rewards of multiple tokens in a single transaction
    function claimRewards(
        // batchNumber, amount, tokenIndex, proof
        Claim[] memory inputClaims,
        IERC20[] memory inputTokens
    ) external {
        Claim memory inputClaim;
        IERC20 token;
        uint256 bitsSet; // Accumulator for claimed bits
        uint256 amount;

        for (uint256 i = 0; i < inputClaims.length; i++) {
            inputClaim = inputClaims[i];

            // Calculate the word and bit position for the claim in the bitmap
            uint256 wordPosition = inputClaim.batchNumber / 256; // 0
            uint256 bitPosition = inputClaim.batchNumber % 256; // 0

            // Check if this claim is for a different token than the previous one
            if (token != inputTokens[inputClaim.tokenIndex]) {
                // If this isn't the first token (token address is not zero)
                if (address(token) != address(0)) {
                    // Try to set the claims for the previous token
                    if (!_setClaimed(token, amount, wordPosition, bitsSet))
                        revert AlreadyClaimed();
                }

                // Update the token to the new one
                token = inputTokens[inputClaim.tokenIndex];
                // Reset bitsSet for the new token.
                // 1 << bitPosition creates a number with only the bit at bitPosition set to 1
                bitsSet = 1 << bitPosition; // set bit at given position
                // Reset the amount for the new token
                amount = inputClaim.amount;
            } else {
                // If it's the same token as before, update bitsSet and amount
                // bitsSet | (1 << bitPosition) sets the bit at bitPosition to 1, keeping other bits unchanged
                bitsSet = bitsSet | (1 << bitPosition);
                amount += inputClaim.amount;
            }

            // If this is the last claim, set the claims for the current token
            if (i == inputClaims.length - 1) {
                if (!_setClaimed(token, amount, wordPosition, bitsSet))
                    revert AlreadyClaimed();
            }

            // Create the Merkle leaf for this claim
            bytes32 leaf = keccak256(
                abi.encodePacked(msg.sender, inputClaim.amount)
            );

            // Get the Merkle root for this batch
            bytes32 root = distributions[token].roots[inputClaim.batchNumber];

            // Verify the Merkle proof
            if (!MerkleProof.verify(inputClaim.proof, root, leaf))
                revert InvalidProof();

            // Transfer the claimed tokens to the user
            inputTokens[inputClaim.tokenIndex].transfer(
                msg.sender,
                inputClaim.amount
            );
        }
    }

    function _setClaimed(
        IERC20 token,
        uint256 amount,
        uint256 wordPosition,
        uint256 newBits
    ) private returns (bool) {
        uint256 currentWord = distributions[token].claims[msg.sender][
            wordPosition
        ];
        console.log("currentWord", currentWord);
        console.log("newBits", newBits);
        if ((currentWord & newBits) != 0) return false;

        // update state
        distributions[token].claims[msg.sender][wordPosition] =
            currentWord |
            newBits;
        distributions[token].remaining -= amount;

        return true;
    }
}
