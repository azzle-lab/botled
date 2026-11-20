// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IRewardSink {
    function fundRewardsFromCage(uint256 amount) external;
}

interface IDrawSink {
    function drawInfo(address cage, uint256 drawId) external view returns (uint64, uint64, uint256, bool);
    function drawnRunners(address cage, uint256 drawId) external view returns (address[] memory);
    function settleDraw(uint256 drawId, uint8[] calldata status, bool penalize, uint256 reward) external;
}

/// @title CageSettle — appeal-bond settlement of BotledCageV5Near (linked library, DELEGATECALL: runs as the cage)
library CageSettle {
    using SafeERC20 for IERC20;

    struct Round {
        uint8 revealed;
        uint8 leaderCount;
        bytes32 leaderVote;
        address appellant;     // 0 = automatic round
        uint128 bond;
        bytes32 appealedResult;
    }

    /// @dev Final ruling: an appeal that changed the result gets its bond back; a failed appeal pays half to the
    ///      other party and half into the runner reward pool (returned as `bonus` for the final round).
    function settleAppealBonds(
        mapping(uint8 => Round) storage rounds,
        IERC20 token,
        address pool,
        uint8 lastRound,
        bytes32 result,
        address poster,
        address worker
    ) public returns (uint256 bonus, uint256 released) {
        for (uint8 r = 2; r <= lastRound; ++r) {
            Round storage rd = rounds[r];
            if (rd.bond == 0) continue;
            released += rd.bond;
            if (result != rd.appealedResult) {
                token.safeTransfer(rd.appellant, rd.bond);
            } else {
                uint256 half = rd.bond / 2;
                token.safeTransfer(rd.appellant == poster ? worker : poster, half);
                bonus += rd.bond - half;
            }
        }
        if (bonus > 0) {
            token.forceApprove(pool, bonus);
            IRewardSink(pool).fundRewardsFromCage(bonus);
        }
    }

    /// @dev Azzle timeout settled the dispute: every appeal bond goes back to its appellant.
    function refundAll(mapping(uint8 => Round) storage rounds, IERC20 token, uint8 lastRound) public returns (uint256 released) {
        for (uint8 r = 1; r <= lastRound; ++r) {
            Round storage rd = rounds[r];
            if (rd.bond > 0) {
                released += rd.bond;
                token.safeTransfer(rd.appellant, rd.bond);
            }
        }
    }

    /// @dev No minority slash: every drawn runner with a valid reveal shares the round reward (status 2 counted,
    ///      1 liveness-only); runners without a reveal are no-shows (0) — unless the evidence was bound too late for
    ///      anyone to reveal in time (then `penalize` is false).
    function settleDraw(
        mapping(address => bytes32) storage votes,
        IDrawSink pool,
        uint256 id,
        uint64 boundAt,
        uint256 commitWindow,
        uint256 reward
    ) public {
        (uint64 requestedAt, uint64 fulfilledAt,, bool settled) = pool.drawInfo(address(this), id);
        if (requestedAt == 0 || settled) return;
        address[] memory list = pool.drawnRunners(address(this), id);
        uint8[] memory status = new uint8[](list.length);
        for (uint256 i; i < list.length; ++i) {
            bytes32 v = votes[list[i]];
            status[i] = v == 0 ? 0 : v == bytes32(uint256(1)) ? 1 : 2; // bytes32(1) = LIVENESS
        }
        bool penalize = boundAt != 0 && fulfilledAt != 0 && boundAt <= uint256(fulfilledAt) + commitWindow;
        pool.settleDraw(id, status, penalize, reward);
    }
}
