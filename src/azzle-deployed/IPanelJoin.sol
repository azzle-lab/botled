// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPanelArbitration {
    function registry() external view returns (address);
    function bonds() external view returns (address);
    function authorized(address member) external view returns (bool);
    function addPanelMember(address member) external;
    function removePanelMember(address member) external;
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
}

interface IPanelRegistry {
    function taskCount() external view returns (uint256);
}

interface IPanelBond {
    function azl() external view returns (address);
    function minimumBond() external view returns (uint256);
    function bonds(address verifier) external view returns (uint256);
    function isEligible(address verifier) external view returns (bool);
    function canRelease(address verifier) external view returns (bool);
    function bond(uint256 amount) external;
}

interface IGovernanceSafe {
    enum Operation {
        Call,
        DelegateCall
    }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, Operation operation)
        external
        returns (bool success);
}
