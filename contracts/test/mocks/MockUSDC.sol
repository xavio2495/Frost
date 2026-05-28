// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal USDC stand-in. Tracks balances + a "fail next transfer" toggle
///      for the §6.3 step-5 transfer-failure test path.
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    bool public failNextTransfer;
    uint256 public transferFromCallCount;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setFailNextTransfer(bool v) external {
        failNextTransfer = v;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        transferFromCallCount += 1;
        if (failNextTransfer) {
            failNextTransfer = false;
            return false;
        }
        require(balanceOf[from] >= amount, "MockUSDC: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
