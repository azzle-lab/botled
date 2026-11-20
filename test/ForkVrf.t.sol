// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {NativeVrfConsumer} from "../src/shared/NativeVrfConsumer.sol";

contract Probe is NativeVrfConsumer {
    constructor(address w) NativeVrfConsumer(w) {}
    function req(uint32 g) external returns (uint256 price) { (, price) = _requestRandom(g, 3); }
    function _fulfillRandom(uint256, uint256) internal override {}
    receive() external payable {}
}

/// Only runs with FORK_BASE=1 (reads the live Base VRF wrapper; no transaction is sent).
contract ForkVrfTest is Test {
    function testForkVrfRequestGas() public {
        if (!vm.envOr("FORK_BASE", false)) return;
        vm.createSelectFork("https://mainnet.base.org");
        vm.txGasPrice(9_096_040);
        Probe p = new Probe(0xb0407dbe851f8318bd31404A49e658143C982F23);
        vm.deal(address(p), 1 ether);
        uint8[3] memory ns = [uint8(3), 7, 15];
        for (uint256 i; i < 3; ++i) {
            uint32 g = 100_000 + 70_000 * ns[i];
            uint256 gl = gasleft();
            uint256 price = p.req(g);
            emit log_named_uint(string.concat("jurors ", vm.toString(ns[i]), " request gas"), gl - gasleft());
            emit log_named_uint("   VRF fee (wei)", price);
        }
    }
}
