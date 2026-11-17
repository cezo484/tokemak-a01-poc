// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IAutopool {
    struct AssetBreakdown {
        uint256 totalIdle;
        uint256 totalDebt;
        uint256 totalDebtMin;
        uint256 totalDebtMax;
    }

    struct DestinationInfo {
        uint256 cachedDebtValue;
        uint256 cachedMinDebtValue;
        uint256 cachedMaxDebtValue;
        uint256 lastReport;
        uint256 ownedShares;
    }

    struct RebalanceParams {
        address destinationIn;
        address tokenIn;
        uint256 amountIn;
        address destinationOut;
        address tokenOut;
        uint256 amountOut;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function previewDeposit(uint256 assets) external returns (uint256 shares);
    function previewWithdraw(uint256 assets) external returns (uint256 shares);
    function previewRedeem(uint256 shares) external returns (uint256 assets);
    function maxWithdraw(address owner) external returns (uint256 maxAssets);
    function maxDeposit(address wallet) external returns (uint256 maxAssets);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function asset() external view returns (address);
    function getDestinationInfo(address destVault) external view returns (DestinationInfo memory);
    function getDebtReportingQueue() external view returns (address[] memory);
    function getAssetBreakdown() external view returns (AssetBreakdown memory);
    function isDestinationQueuedForRemoval(address dest) external view returns (bool);
    function removeDestinations(address[] calldata destinations) external;
    function updateDebtReporting(uint256 numToProcess) external;
    function flashRebalance(address receiver, RebalanceParams memory rebalanceParams, bytes calldata data) external;
}

interface IDestinationVault {
    function balanceOf(address account) external view returns (uint256);
    function underlying() external view returns (address);
    function decimals() external view returns (uint8);
    function debtValue(uint256 shares) external returns (uint256 value);
}

/// @notice Mock solver receiver: gets the LP tokens from the rebalance-out leg and
/// pays back WETH (simulating the solver swapping LP -> WETH off-chain/on-chain).
contract MockSolverReceiver {
    IERC20 public immutable weth;
    address public immutable autopool;

    constructor(address _weth, address _autopool) {
        weth = IERC20(_weth);
        autopool = _autopool;
    }

    function onFlashLoan(
        address /*operator*/,
        address token,
        uint256 amount,
        uint256 /*fee*/,
        bytes calldata /*data*/
    ) external returns (bytes32) {
        require(msg.sender == autopool, "only autopool");
        require(token == address(weth), "only weth in");
        // Pay back the agreed WETH amount to the autopool.
        weth.transfer(autopool, amount);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @notice PoC: totalAssetsTimeChecked() divides by ownedShares with no zero guard.
/// After a destination is fully exited via a routine rebalance, its
/// _destinationInfo.ownedShares is 0 while it stays in the debt reporting queue.
/// Once its lastReport goes stale (>1 day), every deposit/mint/withdraw/redeem/
/// preview call reverts with a division-by-zero panic, freezing the whole vault
/// until the team runs updateDebtReporting.
contract TokemakA01Test is Test {
    address public constant AUTOPOOL = 0x0A2b94F6871c1D7A32Fe58E1ab5e6deA2f114E56;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // CurveNG destination vault (active, head of the debt reporting queue).
    address public constant DV_CURVE_NG = 0x5c6aeb9ef0d5BbA4E6691f381003503FD0D45126;

    // Team role holders (setup only: routine team operations, not attacker actions).
    address public constant DEST_UPDATER = 0x8b4334d4812C530574Bd4F2763FcD22dE94A969B;
    address public constant SOLVER = 0x952D7a7eB2e0804d37d9244BE8e47341356d2f5D;
    address public constant REPORT_EXECUTOR = 0x241b8f1fA50F1Ce8fb78e7824757280feEb2aea3;

    uint256 public constant FORK_BLOCK = 26433223;

    IAutopool public autopool;
    MockSolverReceiver public receiver;

    function setUp() public {
        vm.createSelectFork("https://eth-mainnet.public.blastapi.io", FORK_BLOCK);
        autopool = IAutopool(AUTOPOOL);
        receiver = new MockSolverReceiver(WETH, AUTOPOOL);
    }

    function testVaultFrozenAfterFullExitAndStaleReport() public {
        // --- Arrange: an ordinary user deposits before anything happens. ---
        (address user, uint256 userKey) = makeAddrAndKey("user");
        vm.deal(user, 10 ether);
        deal(WETH, user, 100 ether);
        vm.startPrank(user);
        IERC20(WETH).approve(AUTOPOOL, type(uint256).max);
        uint256 userShares = autopool.deposit(10 ether, user);
        vm.stopPrank();
        assertGt(userShares, 0, "user got no shares");
        assertEq(autopool.balanceOf(user), userShares, "user share balance");

        // Sanity: deposits and withdrawals work right now.
        vm.prank(user);
        autopool.deposit(1 ether, user);
        vm.prank(user);
        autopool.withdraw(1 ether, user, user);

        // --- Team step 1 (routine): queue the CurveNG destination for removal. ---
        address[] memory toRemove = new address[](1);
        toRemove[0] = DV_CURVE_NG;
        vm.prank(DEST_UPDATER);
        autopool.removeDestinations(toRemove);
        assertTrue(autopool.isDestinationQueuedForRemoval(DV_CURVE_NG), "not queued for removal");

        // --- Team step 2 (routine): solver fully exits the destination to idle. ---
        uint256 dvShares = IDestinationVault(DV_CURVE_NG).balanceOf(AUTOPOOL);
        assertGt(dvShares, 0, "no dv shares to exit");
        // Value the exit at the destination's safe-price debt value so the
        // rebalance passes the strategy slippage check.
        uint256 amountIn = IDestinationVault(DV_CURVE_NG).debtValue(dvShares);
        deal(WETH, address(receiver), amountIn);

        IAutopool.RebalanceParams memory params = IAutopool.RebalanceParams({
            destinationIn: AUTOPOOL,
            tokenIn: WETH,
            amountIn: amountIn,
            destinationOut: DV_CURVE_NG,
            tokenOut: IDestinationVault(DV_CURVE_NG).underlying(),
            amountOut: dvShares
        });
        vm.prank(SOLVER);
        autopool.flashRebalance(address(receiver), params, "");

        // --- Assert the dangerous state: ownedShares == 0 but still queued. ---
        IAutopool.DestinationInfo memory info = autopool.getDestinationInfo(DV_CURVE_NG);
        assertEq(info.ownedShares, 0, "ownedShares not zero after full exit");
        assertEq(info.cachedDebtValue, 0, "cached debt not zero after full exit");
        address[] memory queue = autopool.getDebtReportingQueue();
        bool stillQueued = false;
        for (uint256 i = 0; i < queue.length; ++i) {
            if (queue[i] == DV_CURVE_NG) stillQueued = true;
        }
        assertTrue(stillQueued, "dest should still be in debt reporting queue");

        // Deposits still work while the report is fresh.
        vm.prank(user);
        autopool.deposit(1 ether, user);

        // --- Time passes: no debt reporting covers this destination for > 1 day. ---
        // NOTE: we backdate `lastReport` with vm.store instead of warping.
        // Warping freezes the Chainlink feeds (their pricing timeout is 2h),
        // which makes the oracle revert first and masks the bug. In reality
        // Chainlink feeds keep updating while Tokemak reporting stops, so the
        // real-world state is exactly "fresh oracle, stale lastReport".
        // _destinationInfo is AutopoolETH storage slot 12; DestinationInfo is
        // (cachedDebtValue, cachedMinDebtValue, cachedMaxDebtValue,
        //  lastReport, ownedShares), so lastReport is at base slot + 3.
        bytes32 baseSlot = keccak256(abi.encode(DV_CURVE_NG, uint256(12)));
        bytes32 lastReportSlot = bytes32(uint256(baseSlot) + 3);
        vm.store(AUTOPOOL, lastReportSlot, bytes32(uint256(block.timestamp - 1 days - 1)));
        info = autopool.getDestinationInfo(DV_CURVE_NG);
        assertEq(info.lastReport, block.timestamp - 1 days - 1, "lastReport not backdated");
        assertEq(info.ownedShares, 0, "ownedShares changed");

        // --- Assert: EVERY user flow now reverts (division by zero panic 0x12). ---
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        autopool.deposit(1 ether, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        autopool.mint(1 ether, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        autopool.withdraw(1 ether, user, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        autopool.redeem(1 ether, user, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        autopool.previewDeposit(1 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        autopool.previewWithdraw(1 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        autopool.previewRedeem(1 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        autopool.maxWithdraw(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        autopool.maxDeposit(user);

        // The user's funds are frozen: shares still exist but cannot be redeemed.
        assertGt(autopool.balanceOf(user), 0, "user shares gone");
        assertGt(autopool.totalAssets(), 0, "vault empty");

        // --- Recovery (honest reporting): team debt reporting un-bricks the vault. ---
        vm.prank(REPORT_EXECUTOR);
        autopool.updateDebtReporting(10);

        queue = autopool.getDebtReportingQueue();
        for (uint256 i = 0; i < queue.length; ++i) {
            assertTrue(queue[i] != DV_CURVE_NG, "dest should be popped from queue");
        }

        // User flows work again after the report.
        vm.prank(user);
        autopool.deposit(1 ether, user);
        uint256 userBalance = autopool.balanceOf(user);
        vm.prank(user);
        uint256 redeemed = autopool.redeem(userBalance, user, user);
        assertGt(redeemed, 0, "user could not exit after recovery");
        assertEq(autopool.balanceOf(user), 0, "user shares remain after full redeem");
    }
}
