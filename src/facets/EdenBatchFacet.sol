// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract EdenBatchFacet {
    error NativeValueUnsupported(uint256 actual);

    function multicall(
        bytes[] calldata calls
    ) external payable returns (bytes[] memory results) {
        if (msg.value != 0) revert NativeValueUnsupported(msg.value);

        uint256 len = calls.length;
        results = new bytes[](len);
        for (uint256 i = 0; i < len; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(calls[i]);
            if (!success) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
    }
}
