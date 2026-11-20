// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal views of Azzle's PUBLIC interfaces that Botled uses as a client.
/// @dev ABI-compatible with azzle-lab/azzle contracts/src/v2 (enums encode as uint8).

interface IAzzleArbitrationV2 {
    function disputes(uint256 taskId)
        external
        view
        returns (
            uint256 taskId_,
            address opener,
            address arbitrator,
            bytes32 posterEvidence,
            bytes32 workerEvidence,
            uint64 evidenceDeadline,
            uint64 rulingDeadline,
            uint8 status,
            uint8 outcome,
            uint256 slashed
        );
    function beginRuling(uint256 taskId) external;
    /// @dev `rule(uint256,Outcome,uint16)` in ArbitrationModuleV2; Outcome is uint8 in the ABI.
    function rule(uint256 taskId, uint8 outcome, uint16 workerBps) external;
    function registry() external view returns (address);
    function bonds() external view returns (address);
    function rulingWindow() external view returns (uint64);
    function authorized(address member) external view returns (bool);
    function panelLength() external view returns (uint256);
    function addPanelMember(address member) external;
    function removePanelMember(address member) external;
}

interface IAzzleTaskParties {
    function taskParties(uint256 taskId) external view returns (address poster, address worker);
}

interface IAzzleBondVaultV2 {
    function azl() external view returns (address);
    function minimumBond() external view returns (uint256);
    function assignmentReserve() external view returns (uint256);
    function bonds(address verifier) external view returns (uint256);
    function reservedSlash(address verifier) external view returns (uint256);
    function withdrawReadyAt(address verifier) external view returns (uint64);
    function isEligible(address verifier) external view returns (bool);
    function canRelease(address verifier) external view returns (bool);
    function bond(uint256 amount) external;
    function scheduleWithdrawal() external;
    function withdraw(uint256 amount) external;
}

/// @notice Join surface shared by the deployed PanelJoinGate and the optional PanelJoinGateV2.
interface IAzzlePanelGate {
    function ethPfand() external view returns (uint256);
    function ethOf(address agent) external view returns (uint256);
    function bondTarget(address arbitration) external view returns (uint256);
    function joinPanel(address arbitration) external payable;
    function withdrawEth() external;
}

interface IAzzleTaskScope {
    function scopeOf(uint256 taskId) external view returns (string memory);
}
