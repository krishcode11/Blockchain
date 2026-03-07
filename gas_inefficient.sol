// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "./interfaces/uniswap-v4/IHooks.sol";
import {Currency} from "./interfaces/uniswap-v4/Currency.sol";
import {PoolKey} from "./interfaces/uniswap-v4/PoolKey.sol";
import {TickMath} from "./interfaces/uniswap-v4/TickMath.sol";

interface IPositionManager {
    function initializePool(
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external payable returns (int24);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}

interface IAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/**
 * @title TuringLiquidityLoaderV4
 * @notice One-sided LP loader for TURING V4 pool at 10M TURING per ETH.
 * @dev Same proven PNKSTR pattern as V3, with:
 *      - New price: 10M TURING/ETH (10x higher FDV than V3)
 *      - sqrtPriceX96 = sqrt(10,000,000) * 2^96 ≈ 250541448375047931186413801569606
 *      - Initial tick ≈ 161189, tickUpper = 161180 (below current tick)
 *      - Auto-sweeps dust back to owner after loading (no tokens left in loader)
 */
contract TuringLiquidityLoaderV4 {
    IPositionManager public immutable posm;
    IAllowanceTransfer public immutable permit2;
    address public immutable token;
    address public immutable owner;

    // V4 PositionManager action IDs
    uint8 constant MINT_POSITION = 0x02;
    uint8 constant SETTLE_PAIR = 0x0d;

    constructor(address _positionManager, address _permit2, address _token) {
        posm = IPositionManager(_positionManager);
        permit2 = IAllowanceTransfer(_permit2);
        token = _token;
        owner = msg.sender;
    }

    /**
     * @notice Load liquidity: 10M TURING per ETH, one-sided position
     * @param _hook The hook address for the pool
     * @dev Call with exactly 2 wei ETH: loader.loadLiquidity{value: 2}(hookAddr)
     *
     *      Price: 10M TURING per ETH → sqrtPriceX96 = sqrt(10,000,000) * 2^96
     *      Current tick ≈ 161189
     *      Position: tickLower = -887270, tickUpper = 161180 (below current tick)
     *      → One-sided: 100% token1 (TURING), ~0 token0 (ETH)
     *      → After loading, remaining dust is swept back to owner
     */
    function loadLiquidity(address _hook) external payable {
        require(msg.sender == owner, "Only owner");
        require(msg.value == 2, "Send exactly 2 wei");

        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance > 0, "No tokens");

        Currency currency0 = Currency.wrap(address(0)); // ETH
        Currency currency1 = Currency.wrap(token);       // TURING

        uint24 lpFee = 0;
        int24 tickSpacing = 10;

        // 10M TURING per ETH: sqrtPriceX96 = sqrt(10,000,000) * 2^96
        uint160 startingPrice = 250541448375047931186413801569606;

        int24 tickLower = TickMath.minUsableTick(tickSpacing); // -887270
        int24 tickUpper = int24(161180);                        // below current tick ~161189

        PoolKey memory key = PoolKey(currency0, currency1, lpFee, tickSpacing, IHooks(_hook));
        bytes memory hookData = new bytes(0);

        uint256 amount0Max = 2;                   // 2 wei ETH
        uint256 amount1Max = tokenBalance + 1;    // full balance + 1 wei margin

        // Compute exact liquidity for one-sided token1 position (currentTick > tickUpper)
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 Q96 = 1 << 96;
        uint128 liquidity = uint128(
            (tokenBalance * Q96) / (uint256(sqrtPriceUpper) - uint256(sqrtPriceLower))
        );

        // Build mint params
        bytes memory actions = abi.encodePacked(uint8(MINT_POSITION), uint8(SETTLE_PAIR));

        bytes[] memory mintParams = new bytes[](2);
        mintParams[0] = abi.encode(
            key, tickLower, tickUpper, liquidity,
            amount0Max, amount1Max,
            address(this), hookData
        );
        mintParams[1] = abi.encode(key.currency0, key.currency1);

        // Multicall: initializePool + modifyLiquidities
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encodeWithSelector(
            posm.initializePool.selector,
            key, startingPrice
        );
        params[1] = abi.encodeWithSelector(
            posm.modifyLiquidities.selector,
            abi.encode(actions, mintParams),
            block.timestamp + 60
        );

        // Approval chain: token → Permit2 → PositionManager
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(posm), type(uint160).max, type(uint48).max);

        // Execute multicall with 2 wei ETH
        posm.multicall{value: msg.value}(params);

        // Auto-sweep remaining dust back to owner (avoids tokens stuck in loader)
        uint256 remaining = IERC20(token).balanceOf(address(this));
        if (remaining > 0) {
            IERC20(token).transfer(owner, remaining);
        }
    }

    /**
     * @notice Emergency function to recover tokens and ETH
     */
    function recover() external {
        require(msg.sender == owner, "Only owner");

        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        if (tokenBalance > 0) {
            IERC20(token).transfer(owner, tokenBalance);
        }

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            payable(owner).transfer(ethBalance);
        }
    }

    receive() external payable {}
}
