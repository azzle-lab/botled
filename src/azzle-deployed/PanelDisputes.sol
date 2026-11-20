// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPanelArbitration, IPanelRegistry} from "./IPanelJoin.sol";

/// @notice Reads live disputes. An open dispute with no arbitrator blocks a join.
library PanelDisputes {
    uint8 internal constant EVIDENCE = 1;
    uint8 internal constant RULING = 2;

    error UnassignedDispute(uint256 taskId);

    function requireNone(address arbitration) internal view {
        uint256 count = IPanelRegistry(IPanelArbitration(arbitration).registry()).taskCount();
        for (uint256 id = 1; id <= count; ++id) {
            (, , address arbitrator, , , , , uint8 status, , ) = IPanelArbitration(arbitration).disputes(id);
            if (arbitrator == address(0) && (status == EVIDENCE || status == RULING)) revert UnassignedDispute(id);
        }
    }
}
