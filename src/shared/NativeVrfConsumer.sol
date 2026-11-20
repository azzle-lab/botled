// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Chainlink VRF v2.5 wrapper ("direct funding"), paid in native ETH.
///      Base mainnet (docs.chain.link/vrf/v2-5/supported-networks, read 2026-11-18):
///      VRF Wrapper 0xb0407dbe851f8318bd31404A49e658143C982F23 ("VRFV2PlusWrapper 1.0.0" on-chain),
///      VRF Coordinator 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634, native premium 60 %, max 10 words.
interface IVRFV2PlusWrapperNative {
    function calculateRequestPriceNative(uint32 callbackGasLimit, uint32 numWords) external view returns (uint256);
    function requestRandomWordsInNative(
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        uint32 numWords,
        bytes calldata extraArgs
    ) external payable returns (uint256 requestId);
}

/// @notice Minimal re-implementation of VRFV2PlusWrapperConsumerBase (native payment only).
abstract contract NativeVrfConsumer {
    /// @dev VRFV2PlusClient.EXTRA_ARGS_V1_TAG
    bytes4 internal constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    struct ExtraArgsV1 {
        bool nativePayment;
    }

    IVRFV2PlusWrapperNative public immutable vrfWrapper;

    error OnlyVrfWrapper();

    constructor(address wrapper) {
        vrfWrapper = IVRFV2PlusWrapperNative(wrapper);
    }

    function _vrfPrice(uint32 callbackGasLimit) internal view returns (uint256) {
        return vrfWrapper.calculateRequestPriceNative(callbackGasLimit, 1);
    }

    /// @dev Pays exactly the quoted price; the wrapper keeps any overpayment.
    function _requestRandom(uint32 callbackGasLimit, uint16 confirmations) internal returns (uint256 id, uint256 price) {
        price = _vrfPrice(callbackGasLimit);
        id = vrfWrapper.requestRandomWordsInNative{value: price}(
            callbackGasLimit, confirmations, 1, abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, ExtraArgsV1({nativePayment: true}))
        );
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfWrapper)) revert OnlyVrfWrapper();
        _fulfillRandom(requestId, randomWords[0]);
    }

    /// @dev Must not revert for foreseeable states (a reverted fulfillment is not retried).
    function _fulfillRandom(uint256 requestId, uint256 word) internal virtual;
}
