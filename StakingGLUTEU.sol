// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
   ----------------------------------------------------------------------------
   Authored by The Consul @ Gluteus Maximus

   COMPLETE FLOW:

   1) stakeAndGetNFT():
      - User stakes 1 million GLUTEU and requests 1 random word via Chainlink VRF.
      - We store a "StakeRequest" in `stakes[requestId]`.
      - Also store `requestId` in `userRequests[user]`, so the user can track all their requests.

   2) fulfillRandomWords():
      - The Chainlink VRF callback sets `randomWord` and `randomReady=true`.
      - We do NOT mint here to avoid potential out-of-gas issues.

   3) claimNFT(requestId):
      - If the pool has at least 1 available ID, the user mints the assigned ID.
      - If the pool is exhausted (0 left), we automatically refund the user’s 1 million GLUTEU
        in the same call, marking stake as inactive. This handles the edge case where the user
        was "late" to claim and all 500 IDs were already taken.

   4) unstakeNoNFT(requestId):
      - If `randomReady=false` (VRF never arrived), the user can reclaim their 1 million GLUTEU
        without an NFT. This prevents permanently locked tokens if the callback fails.
      - If `randomReady=true`, the user CANNOT unstakeNoNFT (no "reroll" if the random is assigned).

   5) unstakeAndBurnNFT(tokenId):
      - After waiting `waitPeriod` seconds from mint time, the current owner of the NFT
        (transferable!) can burn it to reclaim 1 million GLUTEU. That `tokenId` then reenters
        the pool (`availableIds`).

   SOLVES "POOL EXHAUSTION" + "VRF FAIL" ISSUES:
   - If VRF fails, user calls `unstakeNoNFT`.
   - If VRF succeeds but pool is empty when user calls `claimNFT`, we auto-refund.
   - No leftover-withdraw function. The only ways to remove GLUTEU are:
     * UnstakeNoNFT (if random not assigned) 
     * Claim the NFT and later burn it 
     * Automatic refund if pool is exhausted in `claimNFT`.
   - The userRequests mapping helps users see all their pending or used requestIds.

   ----------------------------------------------------------------------------
*/

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./SenatorNFTCollection.sol";

/**
 * @title StakingGLUTEU
 * @notice Non-upgradeable contract to stake 1M GLUTEU for 1 random Senator NFT
 *         using a two-phase approach and edge-case handling if the pool is exhausted.
 *
 * - If VRF never arrives, user can `unstakeNoNFT`.
 * - If VRF arrives and pool has IDs, user calls `claimNFT(requestId)`.
 * - If VRF arrives but the pool is empty, the contract auto-refunds user 
 *   in the same `claimNFT` call (no NFT minted).
 * - Minted NFTs lock 1M GLUTEU until `unstakeAndBurnNFT(tokenId)` after `waitPeriod`.
 * - `userRequests[user]` array to let each user see all their VRF requests.
 *
 * Author: The Consul @ Gluteus Maximus
 */
contract StakingGLUTEU is VRFConsumerBaseV2Plus, ReentrancyGuard {
    // ========== CHAINLINK VRF SETTINGS ==========

    /// @notice VRF v2.5 subscription ID
    uint256 public s_subscriptionId;

    /// @notice KeyHash (gas lane) for VRF
    bytes32 public keyHash;

    /// @notice How many block confirmations VRF should wait
    uint16 public requestConfirmations;

    /// @notice Gas limit for fulfillRandomWords callback
    uint32 public callbackGasLimit;

    // ========== TOKEN + NFT REFERENCES ==========

    /// @dev 1 million staked per NFT
    IERC20 public immutable gluteuToken;

    /// @dev SenatorNFTCollection with 500 possible IDs
    SenatorNFTCollection public immutable nftContract;

    // ========== STAKING + WAIT PERIOD ==========

    /// @notice Each Senator costs 1,000,000 GLUTEU
    uint256 public constant STAKE_AMOUNT = 1_000_000 * 10**18;

    /// @notice Seconds to wait before the minted NFT can be burned
    uint256 public waitPeriod;

    // ========== ID POOL ==========

    /// @notice The pool of available IDs [1..500]
    uint256[] private availableIds;

    // ========== STAKE REQUESTS DATA ==========

    /**
     * @notice Each VRF request -> a StakeRequest storing:
     *  - staker: the user who staked
     *  - stakedAt: block.timestamp of staking
     *  - stakeActive: user hasn't unstaked or minted
     *  - randomReady: VRF arrived with a randomWord
     *  - claimed: user minted the NFT
     *  - randomWord: the random assigned
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
     *         so the current holder can burn after waitPeriod
     */
    mapping(uint256 => uint256) public mintedTimestamp;

    /**
     * @notice userRequests[user] = array of requestIds for that user
     */
    mapping(address => uint256[]) private userRequests;

    // ========== EVENTS ==========

    event StakeAndGetNFTCalled(address indexed user, uint256 timestamp);
    event VRFRequested(uint256 indexed requestId, address indexed user);
    event VRFCallbackSuccess(uint256 indexed requestId, address indexed user, uint256 randomWord);
    event ClaimNFT(address indexed user, uint256 indexed requestId, uint256 tokenId);
    event PoolExhaustedRefund(address indexed user, uint256 indexed requestId);
    event UnstakeNoNFT(address indexed user, uint256 indexed requestId);
    event SenatorBurned(address indexed holder, uint256 indexed tokenId);

    // ========== CONSTRUCTOR ==========

    /**
     * @param _subscriptionId VRF subscription ID
     * @param _gluteuToken    Address of GLUTEU (ERC20)
     * @param _nftContract    Address of SenatorNFTCollection
     * @param _vrfCoordinator Chainlink VRF v2.5 coordinator
     * @param _keyHash        The VRF gas lane
     * @param _requestConfirmations Blocks to wait
     * @param _callbackGasLimit How much gas for fulfill
     * @param _waitPeriod     Lock time in seconds
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
     * @notice The user stakes 1M GLUTEU and requests VRF for 1 random word.
     *         If VRF fails, they can unstakeNoNFT. 
     *         We also store requestId in userRequests[user].
     */
    function stakeAndGetNFT() external nonReentrant returns (uint256 requestId) {
        bool success = gluteuToken.transferFrom(msg.sender, address(this), STAKE_AMOUNT);
        require(success, "GLUTEU transfer failed");
        require(availableIds.length > 0, "No more IDs available");

        emit StakeAndGetNFTCalled(msg.sender, block.timestamp);

        // Build VRF request
        VRFV2PlusClient.RandomWordsRequest memory vrfReq = VRFV2PlusClient.RandomWordsRequest({
            keyHash: keyHash,
            subId: s_subscriptionId,
            requestConfirmations: requestConfirmations,
            callbackGasLimit: callbackGasLimit,
            numWords: 1,
            // If paying in LINK => false, if paying in native => true
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

        // track it for user
        userRequests[msg.sender].push(requestId);

        emit VRFRequested(requestId, msg.sender);
        return requestId;
    }

    // ===================================================
    //   2) VRF CALLBACK (STORE RANDOM)
    // ===================================================
    /**
     * @dev We store the randomWord, mark randomReady=true, no mint here
     */
    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] calldata _randomWords
    ) internal override {
        StakeRequest storage sr = stakes[_requestId];
        if (sr.staker == address(0) || !sr.stakeActive || sr.randomReady) {
            // either invalid, or user canceled, or already set
            return;
        }

        sr.randomReady = true;
        sr.randomWord = _randomWords[0];

        emit VRFCallbackSuccess(_requestId, sr.staker, _randomWords[0]);
    }

    // ===================================================
    //   3) CLAIM NFT or GET REFUND IF POOL EMPTY
    // ===================================================
    /**
     * @notice If VRF succeeded, user calls claim to finalize. 
     *         If the pool is empty at that moment, we refund them immediately.
     */
    function claimNFT(uint256 requestId) external nonReentrant {
        StakeRequest storage sr = stakes[requestId];
        require(sr.staker == msg.sender, "Not your stake");
        require(sr.stakeActive, "Already inactive");
        require(sr.randomReady, "Random not ready");
        require(!sr.claimed, "Already claimed");

        uint256 numAvailable = availableIds.length;
        if (numAvailable == 0) {
            // The user missed out, all minted. 
            // Auto-refund to avoid permanent lock
            sr.stakeActive = false;
            sr.claimed = false;
            sr.randomReady = false;

            bool success = gluteuToken.transfer(msg.sender, STAKE_AMOUNT);
            require(success, "Refund failed");

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

        // Mint
        nftContract.mintWithId(msg.sender, tokenId);

        // record minted time
        mintedTimestamp[tokenId] = block.timestamp;

        emit ClaimNFT(msg.sender, requestId, tokenId);
    }

    // ===================================================
    //   4) UNSTAKE NO NFT (IF randomReady=false)
    // ===================================================
    /**
     * @notice If VRF never arrived, user can recover 1M GLUTEU. 
     *         Not allowed if randomReady=true => no re-rolling.
     */
    function unstakeNoNFT(uint256 requestId) external nonReentrant {
        StakeRequest storage sr = stakes[requestId];
        require(sr.staker == msg.sender, "Not your stake");
        require(sr.stakeActive, "Inactive or used");
        require(!sr.claimed, "Already claimed");
        require(!sr.randomReady, "Random assigned; can't forfeit now");

        sr.stakeActive = false;
        bool success = gluteuToken.transfer(msg.sender, STAKE_AMOUNT);
        require(success, "Refund failed");

        emit UnstakeNoNFT(msg.sender, requestId);
    }

    // ===================================================
    //   5) UNSTAKE & BURN NFT (TRANSFERABLE)
    // ===================================================
    /**
     * @notice The current NFT owner can burn after `waitPeriod` to reclaim 1M GLUTEU.
     *         ID reenters the pool for future mint.
     */
    function unstakeAndBurnNFT(uint256 tokenId) external nonReentrant {
        require(nftContract.ownerOf(tokenId) == msg.sender, "Not NFT owner");
        uint256 mintedTime = mintedTimestamp[tokenId];
        require(mintedTime != 0, "Invalid token");
        require(block.timestamp >= mintedTime + waitPeriod, "Wait period not met");

        // burn
        nftContract.burnWithId(tokenId);
        availableIds.push(tokenId);

        bool success = gluteuToken.transfer(msg.sender, STAKE_AMOUNT);
        require(success, "GLUTEU refund failed");

        delete mintedTimestamp[tokenId];
        emit SenatorBurned(msg.sender, tokenId);
    }

    // ===================================================
    //   VIEW: GET USER REQUESTS
    // ===================================================
    /**
     * @notice Return all requestIds for a given user
     */
    function getUserRequests(address user) external view returns (uint256[] memory) {
        return userRequests[user];
    }

    /**
     * @notice Return the array of available IDs
     */
    function getAvailableIds() external view returns (uint256[] memory) {
        return availableIds;
    }

    // ===================================================
    //   OWNER-LIKE FUNCTIONS (CHAINLINK)
    // ===================================================
    /**
     * @notice Adjust waitPeriod if needed (onlyOwner)
     */
    function setWaitPeriod(uint256 newWait) external onlyOwner {
        waitPeriod = newWait;
    }

    /**
     * @notice Update VRF config if needed
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
