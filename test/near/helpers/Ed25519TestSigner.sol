// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SCL_EIP6565_UTILS} from "@solidity/lib/libSCL_eddsaUtils.sol";

/// @dev TEST ONLY: an RFC 8032 ed25519 key that stands in for a NEAR AI gateway key in the via-IR flow tests
///      (deployed with vm.deployCode because SCL compiles with the legacy pipeline). Seed is public test data.
contract Ed25519TestSigner {
    uint256[5] internal _ext;
    uint256[2] internal _signer;

    constructor(uint256 seed) {
        (_ext, _signer) = SCL_EIP6565_UTILS.SetKey(seed);
    }

    function extKey() external view returns (uint256[5] memory k) {
        k = [_ext[0], _ext[1], 0, 0, _ext[4]];
    }

    function sign(bytes calldata text) external view returns (bytes memory) {
        (uint256 r, uint256 s) = SCL_EIP6565_UTILS.Sign(_ext[4], _signer, string(text));
        return abi.encodePacked(r, s);
    }
}
