// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGovernanceSafe, IPanelArbitration, IPanelBond} from "./IPanelJoin.sol";
import {PanelDisputes} from "./PanelDisputes.sol";

/// @notice Safe module. An agent joins a panel by posting the ETH pfand and the AZL bond.
/// @dev Removal and ownership transfer are not module calls. The Safe owners sign those.
contract PanelJoinGate is ReentrancyGuard {
    uint256 public constant AZL_PFAND = 10_000 ether;

    address public immutable safe;
    uint256 public immutable ethPfand;
    address public immutable standardArbitration;
    address public immutable microArbitration;

    address public pendingMember;
    address public pendingArbitration;
    mapping(address => uint256) public ethOf;

    event PanelJoined(address indexed agent, address indexed arbitration, uint256 ethAmount);
    event EthWithdrawn(address indexed agent, uint256 amount);

    error BadConfig();
    error UnknownPanel();
    error AlreadyPanel();
    error Unbonded();
    error JoinFailed();
    error EthPfand();
    error NoEth();
    error StillPanel();
    error Assigned();
    error EthTransfer();

    constructor(address safe_, uint256 ethPfand_, address standard_, address micro_) {
        if (safe_.code.length == 0 || standard_.code.length == 0 || micro_.code.length == 0) revert BadConfig();
        if (standard_ == micro_ || ethPfand_ == 0) revert BadConfig();
        safe = safe_;
        ethPfand = ethPfand_;
        standardArbitration = standard_;
        microArbitration = micro_;
    }

    function known(address arbitration) public view returns (bool) {
        return arbitration == standardArbitration || arbitration == microArbitration;
    }

    /// @notice AZL the agent must have bonded on this panel's vault. At least 10,000 AZL.
    function bondTarget(address arbitration) public view returns (uint256) {
        if (!known(arbitration)) revert UnknownPanel();
        uint256 minimum = IPanelBond(IPanelArbitration(arbitration).bonds()).minimumBond();
        return minimum > AZL_PFAND ? minimum : AZL_PFAND;
    }

    function requireNoUnassigned(address arbitration) external view {
        if (!known(arbitration)) revert UnknownPanel();
        PanelDisputes.requireNone(arbitration);
    }

    /// @notice Add `msg.sender` to one panel. The first join locks `ethPfand`. The caller must already hold the AZL bond.
    function joinPanel(address arbitration) external payable nonReentrant {
        if (!known(arbitration)) revert UnknownPanel();
        if (IPanelArbitration(arbitration).authorized(msg.sender)) revert AlreadyPanel();
        PanelDisputes.requireNone(arbitration);

        uint256 paid;
        if (ethOf[msg.sender] == 0) {
            if (msg.value != ethPfand) revert EthPfand();
            ethOf[msg.sender] = msg.value;
            paid = msg.value;
        } else if (msg.value != 0) {
            revert EthPfand();
        }

        IPanelBond vault = IPanelBond(IPanelArbitration(arbitration).bonds());
        if (vault.bonds(msg.sender) < bondTarget(arbitration) || !vault.isEligible(msg.sender)) revert Unbonded();

        pendingMember = msg.sender;
        pendingArbitration = arbitration;
        bool ok = IGovernanceSafe(safe).execTransactionFromModule(
            arbitration,
            0,
            abi.encodeCall(IPanelArbitration.addPanelMember, (msg.sender)),
            IGovernanceSafe.Operation.Call
        );
        pendingMember = address(0);
        pendingArbitration = address(0);
        if (!ok) revert JoinFailed();
        emit PanelJoined(msg.sender, arbitration, paid);
    }

    /// @notice Return the ETH pfand after the Safe has removed the agent from both panels.
    function withdrawEth() external nonReentrant {
        uint256 amount = ethOf[msg.sender];
        if (amount == 0) revert NoEth();
        if (_onPanel(msg.sender)) revert StillPanel();
        if (_assigned(msg.sender)) revert Assigned();
        ethOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransfer();
        emit EthWithdrawn(msg.sender, amount);
    }

    function _onPanel(address agent) internal view returns (bool) {
        return IPanelArbitration(standardArbitration).authorized(agent)
            || IPanelArbitration(microArbitration).authorized(agent);
    }

    function _assigned(address agent) internal view returns (bool) {
        return IPanelBond(IPanelArbitration(standardArbitration).bonds()).canRelease(agent)
            || IPanelBond(IPanelArbitration(microArbitration).bonds()).canRelease(agent);
    }
}
