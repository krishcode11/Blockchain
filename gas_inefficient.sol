// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title GasInefficient
 * @dev Contains multiple gas optimization opportunities.
 *      OmniAudit GasAnalyzer should detect these patterns.
 */
contract GasInefficient {
    // GAS ISSUE: Bool uses full storage slot
    bool public isActive;
    bool public isPaused;

    // GAS ISSUE: Variable initialized to default value
    uint256 public counter = 0;
    uint256 public total = 0;

    // GAS ISSUE: String for short data
    string public name = "TokenName";

    uint256[] public values;
    mapping(address => uint256) public balances;

    // GAS ISSUE: Array length in loop condition
    function sumValues() public view returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < values.length; i++) {
            sum += values[i];
        }
        return sum;
    }

    // GAS ISSUE: Post-increment in loop
    function processAll() public {
        for (uint256 i = 0; i < values.length; i++) {
            values[i] = values[i] * 2;
        }
    }

    // GAS ISSUE: Public function that could be external
    function updateBalance(address user, uint256 amount) public returns (bool) {
        balances[user] = amount;
        return true;
    }

    // GAS ISSUE: Long require string
    function verifyAmount(uint256 amount) public pure returns (bool) {
        require(amount > 0, "The amount provided must be greater than zero to proceed with this transaction");
        return true;
    }

    // GAS ISSUE: Repeated storage reads
    function doubleCheck() public view returns (uint256) {
        if (counter > 0 && counter < 100) {
            return counter * 2;
        }
        return counter;
    }

    // GAS ISSUE: Non-payable constructor
    constructor() {
        isActive = true;
    }

    function addValue(uint256 val) public {
        values.push(val);
        total += val;
    }
}
