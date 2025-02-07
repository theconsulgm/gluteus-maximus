// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
   ----------------------------------------------------------------------------
   Authored by The Consul @ Gluteus Maximus

   COMPLETE FLOW WITH 1-HOUR UNSTAKE NO-NFT COOLDOWN:

   1) stakeAndGetNFT():
      - The user stakes 1 million GLUTEU and requests 1 random word from Chainlink VRF.
      - We store a "StakeRequest" in `stakes[requestId]`.
      - We also append `requestId` to `userRequests[user]` so the user can keep track of
        all their requests.

   2) fulfillRandomWords():
      - The Chainlink VRF callback sets `randomWord` and `randomReady=true` in `stakes[requestId]`.
      - We do NOT mint here (to avoid potential out-of-gas or revert issues).

   3) claimNFT(requestId):
      - If the pool (`availableIds`) has at least 1 ID left, we mint the assigned ID to the user.
      - If the pool is exhausted (0 IDs left), we automatically refund the user's 1 million GLUTEU
        in this same call (so they aren't permanently locked).

   4) unstakeNoNFT(requestId):
      - Allowed **only** if `randomReady=false` (meaning the VRF callback never arrived).
      - Additionally, we require **at least 1 hour** to have passed since `stakeAndGetNFT` was called
        (`block.timestamp >= stakedAt + MIN_NO_NFT_WAIT`).
      - If these conditions are met, we refund the 1 million GLUTEU without minting an NFT.
      - This solves the scenario where VRF fails, but also prevents immediate "front-running"
        if the user doesn't like the random result in the mempool.

   5) unstakeAndBurnNFT(tokenId):
      - After waiting `waitPeriod` seconds from the NFT's mint time, **whoever** owns the NFT
        (it is transferrable) can burn it to reclaim 1 million GLUTEU.
      - The tokenId then reenters the pool (`availableIds`).

   SOLUTIONS TO SECURITY & EDGE CASES:
   - No permanent lock if VRF fails (`unstakeNoNFT`).
   - No leftover withdrawal function that might drain user stakes.
   - If the pool is full at the time of claim, user is auto-refunded.
   - The user cannot "reroll" once VRF is assigned because `unstakeNoNFT` is disallowed if `randomReady=true`.
   - We add a **1-hour** (3600 seconds) minimum wait before calling `unstakeNoNFT` to stop MEV watchers
     from front-running the VRF call if they see an undesired random result.

   ----------------------------------------------------------------------------
*/

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./SenatorNFTCollection.sol";

/**
 * @title StakingGLUTEU
 * @notice Non-upgradeable contract to stake 1M GLUTEU for 1 random Senator NFT
 *         using a two-phase approach and edge-case handling if the pool is exhausted,
 *         plus a 1-hour cooldown before unstakeNoNFT can be called.
 *
 * Author: The Consul @ Gluteus Maximus
 */
contract StakingGLUTEU is VRFConsumerBaseV2Plus, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ================== VRF CONFIG ==================

    /// @notice VRF v2.5 subscription ID
    uint256 public s_subscriptionId;

    /// @notice The Chainlink VRF gas lane (keyHash)
    bytes32 public keyHash;

    /// @notice How many block confirmations VRF should wait
    uint16 public requestConfirmations;

    /// @notice Gas limit for fulfillRandomWords callback
    uint32 public callbackGasLimit;

    // ================== TOKEN + NFT ==================

    /// @notice 1 million staked per NFT
    IERC20 public immutable gluteuToken;

    /// @notice The Senator NFT Collection (max 500 IDs)
    SenatorNFTCollection public immutable nftContract;

    // ================== STAKING + WAIT PERIOD ==================

    /// @notice Each Senator costs 1,000,000 GLUTEU
    uint256 public constant STAKE_AMOUNT = 1_000_000 * 10**18;

    /// @notice Seconds to wait before a minted NFT can be burned
    uint256 public waitPeriod;

    /**
     * @notice The user must wait this many seconds (1 hour) 
     *         before they can call unstakeNoNFT if VRF hasn't arrived.
     *         This prevents immediate MEV-based "reroll" attempts.
     */
    uint256 public constant MIN_NO_NFT_WAIT = 3600;

    // ================== ID POOL ==================

    /// @notice The pool of currently available IDs [1..500]
    uint256[] private availableIds;

    // ================== STAKE REQUEST DATA ==================

    /**
     * @notice Each VRF request => one StakeRequest
     *         - staker: user who called stakeAndGetNFT
     *         - stakedAt: block.timestamp of that call
     *         - stakeActive: user hasn't unstaked or minted
     *         - randomReady: VRF arrived
     *         - claimed: user minted the NFT
     *         - randomWord: the random assigned
     */
    struct StakeRequest {
        address staker;
        uint256 stakedAt;
        bool stakeActive;
        bool randomReady;
        bool claimed;
        uint256 randomWord;
    }

    /// @notice requestId => StakeRequest
    mapping(uint256 => StakeRequest) public stakes;

    /**
     * @notice mintedTimestamp[tokenId] = block.timestamp
     *         so the holder can burn after waitPeriod
     */
    mapping(uint256 => uint256) public mintedTimestamp;

    /**
     * @notice userRequests[user] => array of all requestIds from that user
     */
    mapping(address => uint256[]) private userRequests;

    // ================== EVENTS ==================

    event StakeAndGetNFTCalled(address indexed user, uint256 timestamp);
    event VRFRequested(uint256 indexed requestId, address indexed user);
    event VRFCallbackSuccess(uint256 indexed requestId, address indexed user, uint256 randomWord);
    event ClaimNFT(address indexed user, uint256 indexed requestId, uint256 tokenId);
    event PoolExhaustedRefund(address indexed user, uint256 indexed requestId);
    event UnstakeNoNFT(address indexed user, uint256 indexed requestId);
    event SenatorBurned(address indexed holder, uint256 indexed tokenId);

    // ================== CONSTRUCTOR ==================

    /**
     * @param _subscriptionId VRF subscription ID
     * @param _gluteuToken    GLUTEU token address
     * @param _nftContract    SenatorNFTCollection address
     * @param _vrfCoordinator VRF v2.5 coordinator
     * @param _keyHash        chainlink gas lane
     * @param _requestConfirmations how many confirmations
     * @param _callbackGasLimit callback gas
     * @param _waitPeriod     lock time in seconds for minted NFT
     */
    constructor(
        uint256 _subscriptionId,
        address _gluteuToken,
        address _nftContract,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint16 _requestConfirmations,
        uint32 _callbackGasLimit,
        uint256 _waitPeriod
    )
        VRFConsumerBaseV2Plus(_vrfCoordinator)
    {
        s_subscriptionId = _subscriptionId;
        gluteuToken = IERC20(_gluteuToken);
        nftContract = SenatorNFTCollection(_nftContract);

        keyHash = _keyHash;
        requestConfirmations = _requestConfirmations;
        callbackGasLimit = _callbackGasLimit;
        waitPeriod = _waitPeriod;

        // Fill pool of 500 IDs
        for (uint256 i = 1; i <= 500; i++) {
            availableIds.push(i);
        }
    }

    // ===================================================
    //   1) STAKE & REQUEST VRF
    // ===================================================
    /**
     * @notice User stakes 1M GLUTEU and requests randomness.
     *         If VRF fails, they can unstakeNoNFT (only after 1 hour).
     *         We also store the requestId in userRequests[user] for tracking.
     */
    function stakeAndGetNFT() external nonReentrant returns (uint256 requestId) {
        // Transfer 1M from user
        gluteuToken.safeTransferFrom(msg.sender, address(this), STAKE_AMOUNT);
        require(availableIds.length > 0, "No more IDs available");

        emit StakeAndGetNFTCalled(msg.sender, block.timestamp);

        // Build VRF request
        VRFV2PlusClient.RandomWordsRequest memory vrfReq = VRFV2PlusClient.RandomWordsRequest({
            keyHash: keyHash,
            subId: s_subscriptionId,
            requestConfirmations: requestConfirmations,
            callbackGasLimit: callbackGasLimit,
            numWords: 1,
            // If paying in LINK => nativePayment=false, if paying in native => true
            extraArgs: VRFV2PlusClient._argsToBytes(
                VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
            )
        });

        requestId = s_vrfCoordinator.requestRandomWords(vrfReq);

        stakes[requestId] = StakeRequest({
            staker: msg.sender,
            stakedAt: block.timestamp,
            stakeActive: true,
            randomReady: false,
            claimed: false,
            randomWord: 0
        });

        // Track requestId for user
        userRequests[msg.sender].push(requestId);

        emit VRFRequested(requestId, msg.sender);
        return requestId;
    }

    // ===================================================
    //   2) VRF CALLBACK (STORE RANDOM)
    // ===================================================
    /**
     * @dev We store the randomWord, set randomReady=true. No mint to avoid reverts.
     */
    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] calldata _randomWords
    ) internal override {
        StakeRequest storage sr = stakes[_requestId];
        if (sr.staker == address(0) || !sr.stakeActive || sr.randomReady) {
            // either invalid, or user canceled, or already assigned
            return;
        }

        sr.randomReady = true;
        sr.randomWord = _randomWords[0];

        emit VRFCallbackSuccess(_requestId, sr.staker, _randomWords[0]);
    }

    // ===================================================
    //   3) CLAIM NFT or REFUND IF POOL EMPTY
    // ===================================================
    /**
     * @notice If VRF arrived, user calls claim to finalize. 
     *         If the pool is empty, we refund them (no NFT minted).
     */
    function claimNFT(uint256 requestId) external nonReentrant {
        StakeRequest storage sr = stakes[requestId];
        require(sr.staker == msg.sender, "Not your stake");
        require(sr.stakeActive, "Already inactive");
        require(sr.randomReady, "Random not ready");
        require(!sr.claimed, "Already claimed");

        uint256 numAvailable = availableIds.length;
        if (numAvailable == 0) {
            // Edge case: pool exhausted => auto-refund
            sr.stakeActive = false;
            sr.claimed = false;
            sr.randomReady = false;

            gluteuToken.safeTransfer(msg.sender, STAKE_AMOUNT);
            emit PoolExhaustedRefund(msg.sender, requestId);
            return;
        }

        // There's at least 1 ID
        uint256 index = sr.randomWord % numAvailable;
        uint256 tokenId = availableIds[index];

        // swap & pop
        uint256 lastIndex = numAvailable - 1;
        if (index != lastIndex) {
            availableIds[index] = availableIds[lastIndex];
        }
        availableIds.pop();

        sr.claimed = true;

        // Mint the NFT
        nftContract.mintWithId(msg.sender, tokenId);

        // record minted time
        mintedTimestamp[tokenId] = block.timestamp;

        emit ClaimNFT(msg.sender, requestId, tokenId);
    }

    // ===================================================
    //   4) UNSTAKE NO NFT (IF randomReady=false, AFTER 1 HOUR)
    // ===================================================
    /**
     * @notice If the VRF never arrived (randomReady=false), user can unstake after 
     *         at least 1 hour. This stops immediate MEV watchers from "rerolling" 
     *         if they see an unfavorable random in the mempool.
     *
     * @param requestId The stake request ID to cancel
     */
    function unstakeNoNFT(uint256 requestId) external nonReentrant {
        StakeRequest storage sr = stakes[requestId];
        require(sr.staker == msg.sender, "Not your stake");
        require(sr.stakeActive, "Already inactive or used");
        require(!sr.claimed, "Already claimed NFT");
        require(!sr.randomReady, "Random assigned; can't forfeit now");
        // The critical new line: must wait >= 1 hour since staked
        require(block.timestamp >= sr.stakedAt + MIN_NO_NFT_WAIT, "Must wait 1 hour to unstakeNoNFT");

        sr.stakeActive = false;
        gluteuToken.safeTransfer(msg.sender, STAKE_AMOUNT);

        emit UnstakeNoNFT(msg.sender, requestId);
    }

    // ===================================================
    //   5) UNSTAKE & BURN NFT (TRANSFERABLE)
    // ===================================================
    /**
     * @notice The NFT owner (whoever holds it) can burn after `waitPeriod`
     *         to reclaim 1 million GLUTEU, re-adding the tokenId to the pool.
     */
    function unstakeAndBurnNFT(uint256 tokenId) external nonReentrant {
        require(nftContract.ownerOf(tokenId) == msg.sender, "Not NFT owner");
        uint256 mintedTime = mintedTimestamp[tokenId];
        require(mintedTime != 0, "Invalid token");
        require(block.timestamp >= mintedTime + waitPeriod, "Wait period not met");

        nftContract.burnWithId(tokenId);
        availableIds.push(tokenId);

        gluteuToken.safeTransfer(msg.sender, STAKE_AMOUNT);

        delete mintedTimestamp[tokenId];
        emit SenatorBurned(msg.sender, tokenId);
    }

    // ===================================================
    //   VIEW: GET USER REQUESTS
    // ===================================================
    /**
     * @notice Return all requestIds for a given user.
     */
    function getUserRequests(address user) external view returns (uint256[] memory) {
        return userRequests[user];
    }

    /**
     * @notice Return the array of currently available IDs
     */
    function getAvailableIds() external view returns (uint256[] memory) {
        return availableIds;
    }

    // ===================================================
    //   OWNER-LIKE FUNCTIONS (Chainlink style)
    // ===================================================
    /**
     * @notice Adjust waitPeriod if needed (onlyOwner).
     */
    function setWaitPeriod(uint256 newWait) external onlyOwner {
        waitPeriod = newWait;
    }

    /**
     * @notice Update VRF config if needed (onlyOwner).
     */
    function updateVRFSettings(
        bytes32 newKeyHash,
        uint16 newConfirmations,
        uint32 newCallbackGas
    ) external onlyOwner {
        keyHash = newKeyHash;
        requestConfirmations = newConfirmations;
        callbackGasLimit = newCallbackGas;
    }
}
