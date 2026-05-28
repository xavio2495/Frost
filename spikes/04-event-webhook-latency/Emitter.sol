// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Emitter {
    uint256 public nonce;
    event Ping(uint256 nonce, uint256 ts);

    function ping() external {
        nonce += 1;
        emit Ping(nonce, block.timestamp);
    }
}
