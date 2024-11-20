// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave Lending Pool interface
interface ILendingPool {
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// ERC20 interface for tokens
interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external;
    function transfer(address to, uint256 value) external returns (bool);
}

// Wrapped ETH interface
interface IWETH is IERC20 {
    function withdraw(uint256) external;
}

// Uniswap V2 Callee for flash loan
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// Uniswap V2 Factory
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// Uniswap V2 Pair
interface IUniswapV2Pair {
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;
    address constant aaveLendingPool = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address constant uniswapFactory = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant targetAddress = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;

    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    ILendingPool lendingPool = ILendingPool(aaveLendingPool);
    IERC20 usdtToken = IERC20(USDT);
    IERC20 wbtcToken = IERC20(WBTC);
    IWETH wethToken = IWETH(WETH);

    receive() external payable {}

    function operate() external {
        console.log("Starting operate() function");
        
        // 1. Get the target user's account data
        (
            ,
            uint256 totalDebtETH,
            ,
            ,
            ,
            uint256 healthFactor
        ) = lendingPool.getUserAccountData(targetAddress);
        
        console.log("Total Debt ETH:", totalDebtETH);
        console.log("Health Factor:", healthFactor);

        totalDebtETH = totalDebtETH / 1e18;

        // Ensure target is liquidatable
        require(
            healthFactor < 10**health_factor_decimals,
            "Target user is not liquidatable"
        );

        // 2. Get the Uniswap pair for WBTC and USDT, initiate flash loan
        IUniswapV2Factory factory = IUniswapV2Factory(uniswapFactory);
        address pairAddress = factory.getPair(WBTC, USDT);
        require(pairAddress != address(0), "Uniswap pair does not exist");

        console.log("Uniswap WBTC/USDT pair address:", pairAddress);

        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        
        console.log("Uniswap Pair Reserves - Reserve0 (WBTC):", reserve0);
        console.log("Uniswap Pair Reserves - Reserve1 (USDT):", reserve1);

        uint256 maxBorrowableUSDT = reserve1; // 90% of USDT liquidity
        //uint256 debtToCover = totalDebtETH > maxBorrowableUSDT ? maxBorrowableUSDT : totalDebtETH;
        uint256 debtToCover = totalDebtETH;
        console.log("Max Borrowable USDT:", maxBorrowableUSDT);
        console.log("Adjusted Debt to cover for flash loan:", debtToCover);




        // Initiate flash loan with adjusted amount
        pair.swap(0, debtToCover, address(this), "flash loan");
    }

    function uniswapV2Call(
    address,
    uint256,
    uint256 amount1,
    bytes calldata
    ) external override {
        console.log("Inside uniswapV2Call() with amount:", amount1);

        usdtToken.approve(aaveLendingPool, amount1);
        console.log("Approved Aave Lending Pool to use USDT for liquidation");

        lendingPool.liquidationCall(
            WBTC,
            USDT,
            targetAddress,
            amount1,
            false
        );
        console.log("Executed Aave liquidation call");

        uint256 wbtcBalance = wbtcToken.balanceOf(address(this));
        console.log("WBTC balance after liquidation:", wbtcBalance);

        address wethUsdtPair = IUniswapV2Factory(uniswapFactory).getPair(WETH, USDT);
        require(wethUsdtPair != address(0), "Uniswap WETH/USDT pair does not exist");

        (uint112 reserveWeth, uint112 reserveUsdt, ) = IUniswapV2Pair(wethUsdtPair).getReserves();

        // Calculate expected USDT amount if we swap WBTC for USDT
        uint256 expectedUsdtAmount = (wbtcBalance * reserveUsdt) / (reserveWeth + wbtcBalance);
        require(expectedUsdtAmount >= amount1, "Insufficient liquidity for swap");

        IUniswapV2Pair(wethUsdtPair).swap(
            wbtcBalance,
            0,
            address(this),
            abi.encode("swap")
        );
        console.log("Swapped WBTC back to repay Uniswap");

        uint256 wethBalance = wethToken.balanceOf(address(this));
        console.log("WETH balance after swap:", wethBalance);

        wethToken.withdraw(wethBalance);
        console.log("Converted WETH to ETH");

        (bool success, ) = msg.sender.call{value: wethBalance}("");
        require(success, "ETH transfer failed");
        console.log("Profit sent to msg.sender:", wethBalance);
    }

}
