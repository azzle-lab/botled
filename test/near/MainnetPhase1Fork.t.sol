// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {INearVerifier} from "../../src/botled/v5near/interfaces/IBotledNear.sol";

/// @notice Read-only check of the DEPLOYED Base mainnet phase-1 contracts with the real paid NEAR AI receipts.
///         Runs only with FORK_BASE=true:  FORK_BASE=true forge test --match-contract MainnetPhase1Fork --fork-url <base rpc>
contract MainnetPhase1ForkTest is Test {
    INearVerifier constant VER = INearVerifier(0x5B649acd02838b33777FdBaEe49D9FC405A62483);
    address constant VRUNNER = 0x1111111111111111111111111111111111111111;
    bytes32 constant VINPUT = 0x2222222222222222222222222222222222222222222222222222222222222222;
    bytes constant VSCOPE = "Build /refund.";
    bytes constant VPOSTER = "Poster: delivery misses the /refund endpoint that the scope requires.";
    bytes constant VWORKER = "Worker: commit 9f2c implements /refund; see tests/refund.spec.ts (41/41 green).\nDeadline met.";

    function _check(string memory name, uint8 lane, uint32 signerId, bool ed) internal view {
        string memory base = string.concat("test/near-vectors/real/", name);
        string memory meta = vm.readFile(string.concat(base, ".receipt.json"));
        INearVerifier.Receipt memory rc;
        rc.request = vm.readFileBinary(string.concat(base, ".request.json"));
        rc.response = vm.readFileBinary(string.concat(base, ".response.json"));
        rc.signerId = signerId;
        rc.signature = vm.parseJsonBytes(meta, ed ? ".signatures.ed25519.signature" : ".signatures.ecdsa.signature");
        (bool ok, bytes memory r) = address(VER).staticcall(abi.encodeWithSignature(
            "userBinding(bytes,bytes,bytes)", VSCOPE, VPOSTER, VWORKER));
        require(ok);
        (bytes32 uh, uint32 ul) = abi.decode(r, (bytes32, uint32));
        INearVerifier.Ctx memory c = INearVerifier.Ctx(0, lane, VRUNNER, 1, VINPUT, uh, ul);
        (uint8 o, uint16 b,,, bool sp) = VER.check(c, rc);
        assertEq(o, 2);
        assertEq(b, 10_000);
        assertFalse(sp);
    }

    function testDeployedVerifierAcceptsRealReceipts() public view {
        if (!vm.envOr("FORK_BASE", false)) return;
        _check("kimi", 0, 0, false);
        _check("kimi", 0, 1, true);
        _check("deepseek", 1, 2, false);
        _check("deepseek", 1, 3, true);
    }
}
