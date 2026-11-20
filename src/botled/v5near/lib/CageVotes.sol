// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CageVotes — pure vote encoding rules of BotledCageV5Near (linked library, moved out for bytecode headroom)
/// @notice vote = keccak256(abi.encode(outcome, workerBps)); allowed allocations follow the Botled v4/v5 rules.
library CageVotes {
    uint8 internal constant NONE_ = 0;
    uint8 internal constant POSTER_WINS = 1;
    uint8 internal constant WORKER_WINS = 2;
    uint8 internal constant SPLIT = 3;
    uint8 internal constant MUTUAL = 4;
    uint16 internal constant SPLIT_STEP_BPS = 500;
    uint16 internal constant NEUTRAL_BAND_BPS = 1_000;

    error Allocation();

    function validate(uint8 o, uint16 b) public pure {
        bool ok = (o == NONE_ && b == 0) || (o == POSTER_WINS && b == 0) || (o == WORKER_WINS && b == 10_000)
            || (o == SPLIT && b >= NEUTRAL_BAND_BPS && b <= 10_000 - NEUTRAL_BAND_BPS && b % SPLIT_STEP_BPS == 0)
            || (o == MUTUAL && (b == 0 || b == 5_000));
        if (!ok) revert Allocation();
    }

    /// @dev (NONE, 0) for anything that is not a valid vote hash
    function decode(bytes32 v) public pure returns (uint8, uint16) {
        if (v == keccak256(abi.encode(POSTER_WINS, uint16(0)))) return (POSTER_WINS, 0);
        if (v == keccak256(abi.encode(WORKER_WINS, uint16(10_000)))) return (WORKER_WINS, 10_000);
        if (v == keccak256(abi.encode(MUTUAL, uint16(0)))) return (MUTUAL, 0);
        if (v == keccak256(abi.encode(MUTUAL, uint16(5_000)))) return (MUTUAL, 5_000);
        for (uint16 b = NEUTRAL_BAND_BPS; b <= 10_000 - NEUTRAL_BAND_BPS; b += SPLIT_STEP_BPS) {
            if (v == keccak256(abi.encode(SPLIT, b))) return (SPLIT, b);
        }
        return (NONE_, 0);
    }
}
