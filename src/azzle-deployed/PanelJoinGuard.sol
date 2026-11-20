// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGovernanceSafe} from "./IPanelJoin.sol";
import {PanelDisputes} from "./PanelDisputes.sol";
import {PanelJoinGate} from "./PanelJoinGate.sol";

/// @notice Safe module guard. The panel module may only call `addPanelMember` on a live panel.
/// @dev `removePanelMember` and `transferOwnership` stay owner transactions on the Safe.
contract PanelJoinGuard {
    /// @dev `type(IModuleGuard).interfaceId` in Safe 1.5.
    bytes4 internal constant MODULE_GUARD_ID = 0x58401ed8;
    bytes4 internal constant ERC165_ID = 0x01ffc9a7;
    bytes4 internal constant ADD_PANEL = bytes4(keccak256("addPanelMember(address)"));

    address public immutable safe;
    PanelJoinGate public immutable gate;
    address public immutable standardArbitration;
    address public immutable microArbitration;

    error Blocked();

    constructor(address safe_, address gate_, address standard_, address micro_) {
        if (safe_.code.length == 0 || gate_.code.length == 0 || standard_.code.length == 0 || micro_.code.length == 0) {
            revert Blocked();
        }
        if (standard_ == micro_) revert Blocked();
        safe = safe_;
        gate = PanelJoinGate(gate_);
        standardArbitration = standard_;
        microArbitration = micro_;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == MODULE_GUARD_ID || interfaceId == ERC165_ID;
    }

    function checkModuleTransaction(
        address to,
        uint256 value,
        bytes memory data,
        IGovernanceSafe.Operation operation,
        address callerModule
    ) external view returns (bytes32) {
        if (msg.sender != safe || callerModule != address(gate) || value != 0 || operation != IGovernanceSafe.Operation.Call)
        {
            revert Blocked();
        }
        if ((to != standardArbitration && to != microArbitration) || data.length != 36 || _selector(data) != ADD_PANEL) {
            revert Blocked();
        }
        address member = _member(data);
        if (member == address(0) || member != gate.pendingMember() || to != gate.pendingArbitration()) revert Blocked();
        PanelDisputes.requireNone(to);
        return keccak256(abi.encode(to, value, data, operation, callerModule));
    }

    function checkAfterModuleExecution(bytes32, bool success) external view {
        if (msg.sender != safe || !success) revert Blocked();
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        assembly {
            selector := mload(add(data, 32))
        }
    }

    function _member(bytes memory data) private pure returns (address member) {
        assembly {
            member := mload(add(data, 36))
        }
    }
}
