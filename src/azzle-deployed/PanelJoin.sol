// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPanelArbitration, IPanelBond} from "./IPanelJoin.sol";
import {PanelJoinGate} from "./PanelJoinGate.sol";

/// @notice One join for an agent account. Posts the ETH pfand, bonds 10,000 AZL, then asks the Safe module to add the account.
/// @dev Run this by delegatecall from the agent account, the same way `AzlHopV2` runs. The bond vault credits `msg.sender`,
///      so a direct call would bond this contract instead of the agent.
contract PanelJoin {
    using SafeERC20 for IERC20;

    PanelJoinGate public immutable gate;
    address public immutable self;

    error DirectCall();
    error EthPfand();

    constructor(address gate_) {
        if (gate_.code.length == 0) revert DirectCall();
        gate = PanelJoinGate(gate_);
        self = address(this);
    }

    /// @notice Join one panel. `msg.value` is the ETH pfand on the first join and zero after that.
    function joinPanel(address arbitration) external payable {
        if (address(this) == self) revert DirectCall();
        if (IPanelArbitration(arbitration).authorized(address(this))) revert PanelJoinGate.AlreadyPanel();
        gate.requireNoUnassigned(arbitration);

        uint256 ethDue = gate.ethOf(address(this)) == 0 ? gate.ethPfand() : 0;
        if (msg.value != ethDue) revert EthPfand();

        _bond(arbitration);
        gate.joinPanel{value: msg.value}(arbitration);
    }

    function _bond(address arbitration) internal {
        IPanelBond vault = IPanelBond(IPanelArbitration(arbitration).bonds());
        uint256 target = gate.bondTarget(arbitration);
        uint256 have = vault.bonds(address(this));
        if (have >= target) return;
        IERC20(vault.azl()).forceApprove(address(vault), target - have);
        vault.bond(target - have);
    }
}
