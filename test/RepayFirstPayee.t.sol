// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IRepayFirstPayee} from "../src/IRepayFirstPayee.sol";
import {RepayFirstPayee, RepayFirstPayeeFactory} from "../src/RepayFirstPayee.sol";
import {
    MockRegistry,
    MockToken,
    MockCreditor,
    RevertingCreditor,
    GreedyCreditor,
    GasBurningCreditor
} from "./mocks/Mocks.sol";

contract RepayFirstPayeeTest is Test {
    event Swept(address indexed token, uint256 toCreditors, uint256 forwarded);

    uint256 constant AGENT = 8835;

    MockRegistry registry;
    MockToken usd;
    RepayFirstPayeeFactory factory;
    RepayFirstPayee payee;
    MockCreditor lenderA;
    MockCreditor lenderB;
    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");

    function setUp() public {
        registry = new MockRegistry();
        usd = new MockToken();
        factory = new RepayFirstPayeeFactory(address(registry));
        registry.mint(owner, AGENT);
        payee = RepayFirstPayee(factory.deploy(AGENT));
        lenderA = new MockCreditor();
        lenderB = new MockCreditor();
    }

    function _pay(uint256 amount) internal {
        usd.mint(address(payee), amount); // an x402 payment is a plain transfer to the payee
    }

    function _add(address creditor, uint16 bps) internal {
        vm.prank(owner);
        payee.addCreditor(creditor, bps);
    }

    // ------------------------------------------------------------- factory and views

    function test_factory_payeeOfIsTheDeployedAddress_andKnownBeforehand() public {
        address predicted = factory.payeeOf(42);
        assertEq(predicted.code.length, 0);
        registry.mint(owner, 42);
        assertEq(factory.deploy(42), predicted);
        assertEq(factory.payeeOf(AGENT), address(payee));
        vm.expectRevert(abi.encodeWithSelector(RepayFirstPayeeFactory.AlreadyDeployed.selector, predicted));
        factory.deploy(42);
    }

    function test_views() public view {
        assertEq(payee.identityRegistry(), address(registry));
        assertEq(payee.agentId(), AGENT);
        assertEq(payee.beneficiary(), owner);
        assertEq(payee.creditors().length, 0);
        assertTrue(payee.supportsInterface(type(IRepayFirstPayee).interfaceId));
        assertTrue(payee.supportsInterface(0x01ffc9a7));
        assertFalse(payee.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------- sweep

    function test_sweep_noCreditors_forwardsEverything() public {
        _pay(100e6);
        vm.expectEmit(true, false, false, true);
        emit Swept(address(usd), 0, 100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 0);
        assertEq(forwarded, 100e6);
        assertEq(usd.balanceOf(owner), 100e6);
    }

    function test_sweep_paysWhatIsOwedFirst_thenForwardsTheRest() public {
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 30e6);
        _pay(100e6);
        vm.prank(stranger); // anyone may sweep
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 30e6);
        assertEq(forwarded, 70e6);
        assertEq(usd.balanceOf(address(lenderA)), 30e6);
        assertEq(usd.balanceOf(owner), 70e6);
        assertEq(lenderA.owed(AGENT), 0);
    }

    function test_sweep_capsEachCreditorAtItsShareOfTheSweep() public {
        _add(address(lenderA), 2_000); // 20%
        lenderA.setOwed(AGENT, 50e6);
        _pay(100e6);
        payee.sweep(address(usd));
        assertEq(usd.balanceOf(address(lenderA)), 20e6);
        assertEq(usd.balanceOf(owner), 80e6);
        assertEq(lenderA.owed(AGENT), 30e6);
    }

    function test_sweep_paysTheSeniorCreditorFirst() public {
        _add(address(lenderA), 10_000);
        _add(address(lenderB), 10_000);
        lenderA.setOwed(AGENT, 60e6);
        lenderB.setOwed(AGENT, 60e6);
        _pay(100e6);
        payee.sweep(address(usd));
        assertEq(usd.balanceOf(address(lenderA)), 60e6);
        assertEq(usd.balanceOf(address(lenderB)), 40e6);
        assertEq(usd.balanceOf(owner), 0);
    }

    function test_sweep_creditorTakingLessThanGiven_restIsForwarded_andAllowanceReset() public {
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 50e6);
        lenderA.setTakeBps(5_000); // applies only half of what it is given
        _pay(100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 25e6);
        assertEq(forwarded, 75e6);
        assertEq(usd.allowance(address(payee), address(lenderA)), 0);
    }

    function test_sweep_skipsAFailingCreditor() public {
        RevertingCreditor bad = new RevertingCreditor();
        _add(address(bad), 10_000);
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 10e6);
        _pay(100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 10e6);
        assertEq(forwarded, 90e6);
    }

    function test_sweep_survivesACreditorThatBurnsItsGas() public {
        GasBurningCreditor burner = new GasBurningCreditor();
        _add(address(burner), 10_000);
        _pay(100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep{gas: 2_000_000}(address(usd));
        assertEq(toCreditors, 0);
        assertEq(forwarded, 100e6);
        assertEq(usd.allowance(address(payee), address(burner)), 0);
    }

    function test_sweep_aCreditorCannotTakeMoreThanItIsGiven() public {
        GreedyCreditor greedy = new GreedyCreditor();
        _add(address(greedy), 3_000);
        _pay(100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 0); // its pull of give + 1 failed against the allowance
        assertEq(forwarded, 100e6);
    }

    function test_sweep_afterTheIdentityIsBurned_stillPaysCreditors_andKeepsTheRest() public {
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 30e6);
        vm.prank(owner);
        registry.burn(AGENT);
        assertEq(payee.beneficiary(), address(0)); // no owner to read, none set

        _pay(100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 30e6);
        assertEq(forwarded, 0);
        assertEq(usd.balanceOf(address(lenderA)), 30e6);
        assertEq(usd.balanceOf(address(payee)), 70e6); // kept, not lost to the zero address
    }

    function test_sweep_emptyBalance_isANoOp() public {
        (uint256 a, uint256 b) = payee.sweep(address(usd));
        assertEq(a + b, 0);
    }

    function testFuzz_sweep_conservesTheBalance(uint96 paid, uint96 owedA, uint96 owedB, uint16 bpsA, uint16 bpsB)
        public
    {
        bpsA = uint16(bound(bpsA, 1, 10_000));
        bpsB = uint16(bound(bpsB, 1, 10_000));
        _add(address(lenderA), bpsA);
        _add(address(lenderB), bpsB);
        lenderA.setOwed(AGENT, owedA);
        lenderB.setOwed(AGENT, owedB);
        _pay(paid);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));

        uint256 tookA = usd.balanceOf(address(lenderA));
        uint256 tookB = usd.balanceOf(address(lenderB));
        assertEq(toCreditors + forwarded, paid);
        assertEq(tookA + tookB, toCreditors);
        assertEq(usd.balanceOf(owner), forwarded);
        assertLe(tookA, owedA);
        assertLe(tookA, uint256(paid) * bpsA / 10_000);
        assertLe(tookB, owedB);
        assertLe(tookB, uint256(paid) * bpsB / 10_000);
        assertEq(usd.balanceOf(address(payee)), 0);
    }

    // ------------------------------------------------------------- configuration

    function test_onlyTheOwnerConfigures() public {
        vm.startPrank(stranger);
        vm.expectRevert(RepayFirstPayee.NotOwner.selector);
        payee.addCreditor(address(lenderA), 10_000);
        vm.expectRevert(RepayFirstPayee.NotOwner.selector);
        payee.setBeneficiary(stranger);
        vm.stopPrank();
    }

    function test_addCreditor_rejectsBadInput() public {
        vm.startPrank(owner);
        vm.expectRevert(RepayFirstPayee.BadShare.selector);
        payee.addCreditor(address(lenderA), 0);
        vm.expectRevert(RepayFirstPayee.BadShare.selector);
        payee.addCreditor(address(lenderA), 10_001);
        vm.expectRevert(RepayFirstPayee.BadCreditor.selector);
        payee.addCreditor(address(0), 1);
        payee.addCreditor(address(lenderA), 1);
        vm.expectRevert(RepayFirstPayee.BadCreditor.selector);
        payee.addCreditor(address(lenderA), 1);
        vm.stopPrank();
    }

    function test_setBeneficiary_redirectsOnlyWhatIsLeft() public {
        address wallet = makeAddr("wallet");
        vm.prank(owner);
        payee.setBeneficiary(wallet);
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 10e6);
        _pay(100e6);
        payee.sweep(address(usd));
        assertEq(usd.balanceOf(address(lenderA)), 10e6);
        assertEq(usd.balanceOf(wallet), 90e6);
    }

    function test_setBeneficiary_lapsesWhenTheIdentityIsSold() public {
        address sellersWallet = makeAddr("sellersWallet");
        vm.prank(owner);
        payee.setBeneficiary(sellersWallet); // set just before selling
        vm.prank(owner);
        registry.transfer(AGENT, buyer);

        assertEq(payee.beneficiary(), buyer);
        _pay(100e6); // revenue earned after the sale
        vm.prank(stranger); // anyone may sweep, the seller included
        payee.sweep(address(usd));
        assertEq(usd.balanceOf(buyer), 100e6);
        assertEq(usd.balanceOf(sellersWallet), 0);
    }

    function test_setBeneficiary_appliesAgainIfTheSameOwnerHoldsTheIdentity() public {
        address wallet = makeAddr("wallet");
        vm.prank(owner);
        payee.setBeneficiary(wallet);
        vm.prank(owner);
        registry.transfer(AGENT, buyer);
        vm.prank(buyer);
        registry.transfer(AGENT, owner); // back to the owner who chose it
        assertEq(payee.beneficiary(), wallet);
    }

    function test_removeCreditor_ownerCannotDropAnOwedCreditor_canOnceRepaid() public {
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 10e6);
        vm.prank(owner);
        vm.expectRevert(RepayFirstPayee.CreditorHasClaim.selector);
        payee.removeCreditor(address(lenderA));

        _pay(10e6);
        payee.sweep(address(usd)); // repaid from revenue
        vm.prank(owner);
        payee.removeCreditor(address(lenderA));
        assertEq(payee.creditors().length, 0);
        assertEq(payee.maxShareBps(address(lenderA)), 0);
    }

    function test_removeCreditor_aFailingClaimCheckCountsAsAClaim() public {
        RevertingCreditor bad = new RevertingCreditor();
        _add(address(bad), 10_000);
        vm.prank(owner);
        vm.expectRevert(RepayFirstPayee.CreditorHasClaim.selector);
        payee.removeCreditor(address(bad));
    }

    function test_removeCreditor_theCreditorMayLeaveAnytime_andOrderIsKept() public {
        MockCreditor lenderC = new MockCreditor();
        _add(address(lenderA), 10_000);
        _add(address(lenderB), 10_000);
        _add(address(lenderC), 10_000);
        lenderB.setOwed(AGENT, 1);
        vm.prank(address(lenderB));
        payee.removeCreditor(address(lenderB));
        address[] memory cs = payee.creditors();
        assertEq(cs.length, 2);
        assertEq(cs[0], address(lenderA));
        assertEq(cs[1], address(lenderC));
    }

    function test_afterATransfer_theNewOwnerControls_butCannotDropAnOwedCreditor() public {
        _add(address(lenderA), 10_000);
        lenderA.setOwed(AGENT, 10e6);
        vm.prank(owner);
        registry.transfer(AGENT, buyer);

        assertEq(payee.beneficiary(), buyer);
        vm.prank(owner);
        vm.expectRevert(RepayFirstPayee.NotOwner.selector);
        payee.addCreditor(address(lenderB), 10_000);
        vm.prank(buyer);
        vm.expectRevert(RepayFirstPayee.CreditorHasClaim.selector);
        payee.removeCreditor(address(lenderA));
    }

    function test_maxCreditors() public {
        vm.startPrank(owner);
        for (uint256 i; i < 8; ++i) {
            payee.addCreditor(address(new MockCreditor()), 1);
        }
        address ninth = address(new MockCreditor());
        vm.expectRevert(RepayFirstPayee.TooManyCreditors.selector);
        payee.addCreditor(ninth, 1);
        vm.stopPrank();
    }
}
