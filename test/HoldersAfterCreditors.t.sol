// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {IRepayFirstPayee, IRepayFirstCreditor} from "../src/IRepayFirstPayee.sol";
import {RepayFirstPayee, RepayFirstPayeeFactory} from "../src/RepayFirstPayee.sol";
import {IHoldersAfterCreditors} from "../src/IHoldersAfterCreditors.sol";
import {HoldersAfterCreditorsToken} from "../src/HoldersAfterCreditorsToken.sol";
import {MockRegistry, MockToken, MockCreditor} from "./mocks/Mocks.sol";
import {MintableHoldersToken} from "./mocks/HoldersMocks.sol";

contract HoldersAfterCreditorsTest is Test {
    event RevenueFromPayee(address indexed payee, address indexed asset, uint256 amount);

    uint256 constant AGENT = 8835;
    uint256 constant SUPPLY = 1_000_000e18;

    MockRegistry registry;
    MockToken usd;
    MockToken eur; // paid to the agent, but not one of the token's reward assets
    RepayFirstPayee payee;
    HoldersAfterCreditorsToken token;
    MockCreditor lender;
    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");
    address alice = makeAddr("alice"); // holds 75% of the token
    address bob = makeAddr("bob"); // holds 25%

    function setUp() public {
        registry = new MockRegistry();
        usd = new MockToken();
        eur = new MockToken();
        RepayFirstPayeeFactory factory = new RepayFirstPayeeFactory(address(registry));
        registry.mint(owner, AGENT);
        payee = RepayFirstPayee(factory.deploy(AGENT));
        lender = new MockCreditor();

        token = new HoldersAfterCreditorsToken("Agent", "AGT", address(payee), _usdOnly(), alice, SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(bob, SUPPLY / 4));

        vm.startPrank(owner);
        payee.addCreditor(address(lender), 10_000);
        payee.setBeneficiary(address(token)); // the holders' place: the beneficiary, never a creditor
        vm.stopPrank();
    }

    function _pay(uint256 amount) internal {
        usd.mint(address(payee), amount); // a plain transfer to the payee
    }

    function _usdOnly() internal view returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = address(usd);
    }

    function _reward(address holder) internal view returns (uint256) {
        return token.viewReward(holder)[0];
    }

    function _revenueEvents(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == IHoldersAfterCreditors.RevenueFromPayee.selector) {
                ++n;
            }
        }
    }

    // ------------------------------------------------------------- the profile

    function test_supportsInterface_andErc7254Views() public view {
        assertTrue(token.supportsInterface(type(IHoldersAfterCreditors).interfaceId));
        assertTrue(token.supportsInterface(0x01ffc9a7));
        assertFalse(token.supportsInterface(0xffffffff));
        assertEq(token.maxTokenReward(), 8);
        address[] memory rewards = token.tokenReward();
        assertEq(rewards.length, 1);
        assertEq(rewards[0], address(usd));
        assertTrue(token.existsTokenReward(address(usd)));
        assertEq(token.informationOfBatch(alice).length, 1);
    }

    function test_payee_isTheAgentsPayee_andDoesNotChange() public {
        assertEq(token.payee(), address(payee));
        assertEq(IRepayFirstPayee(token.payee()).agentId(), AGENT);

        vm.prank(owner);
        registry.transfer(AGENT, buyer);
        vm.prank(buyer);
        payee.setBeneficiary(buyer);
        _pay(10e6);
        payee.sweep(address(usd));
        token.syncFromPayee(address(usd));
        assertEq(token.payee(), address(payee));
    }

    function test_theTokenTakesNothingAsACreditor_soLendersAddedAfterItStayAhead() public {
        // The owner wrongly lists the token as a creditor, ahead of a lender.
        vm.startPrank(owner);
        payee.removeCreditor(address(lender)); // owed nothing yet
        payee.addCreditor(address(token), 10_000);
        payee.addCreditor(address(lender), 10_000);
        vm.stopPrank();
        lender.setOwed(AGENT, 30e6);

        vm.expectRevert(); // the token is not an IRepayFirstCreditor
        IRepayFirstCreditor(address(token)).amountOwed(AGENT, address(usd));

        _pay(100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 30e6); // all of it to the lender
        assertEq(usd.balanceOf(address(lender)), 30e6);
        assertEq(forwarded, 70e6); // the token gets only what is left, as the beneficiary
        assertEq(token.syncFromPayee(address(usd)), 70e6);
    }

    // ------------------------------------------------------------- syncFromPayee

    function test_holdersShareOnlyWhatTheCreditorsLeft_proRata() public {
        lender.setOwed(AGENT, 20e6);
        _pay(100e6);
        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors, 20e6);
        assertEq(forwarded, 80e6);
        assertEq(usd.balanceOf(address(token)), 80e6);
        assertEq(_reward(alice), 0); // a sweep is a plain transfer: nothing is booked yet

        vm.prank(stranger); // anyone may sync
        assertEq(token.syncFromPayee(address(usd)), 80e6);
        assertApproxEqAbs(_reward(alice), 60e6, 1);
        assertApproxEqAbs(_reward(bob), 20e6, 1);

        vm.prank(alice);
        token.getReward(_usdOnly()); // the form in ERC-7254's specification
        address bobsWallet = makeAddr("bobsWallet");
        vm.prank(bob);
        token.getReward(_usdOnly(), bobsWallet); // the form in its reference interface
        assertApproxEqAbs(usd.balanceOf(alice), 60e6, 1);
        assertApproxEqAbs(usd.balanceOf(bobsWallet), 20e6, 1);
        assertLe(usd.balanceOf(alice) + usd.balanceOf(bobsWallet), 80e6);
        assertEq(usd.balanceOf(address(lender)), 20e6);
        assertEq(_reward(alice), 0);
    }

    function test_syncFromPayee_booksABalanceIncreaseOnce() public {
        _pay(100e6);
        payee.sweep(address(usd));
        assertEq(token.syncFromPayee(address(usd)), 100e6);
        uint256 perShare = token.getRewardPerShare(address(usd));
        uint256 alices = _reward(alice);

        assertEq(token.syncFromPayee(address(usd)), 0); // nothing new arrived
        assertEq(token.getRewardPerShare(address(usd)), perShare);
        assertEq(_reward(alice), alices);

        _pay(50e6);
        payee.sweep(address(usd));
        assertEq(token.syncFromPayee(address(usd)), 50e6); // only the new forward
    }

    function test_syncFromPayee_afterHoldersClaim_booksTheNextForwardInFull() public {
        _pay(100e6);
        payee.sweep(address(usd));
        token.syncFromPayee(address(usd));
        vm.prank(alice);
        token.getReward(_usdOnly()); // about 75e6 leaves the token

        _pay(40e6);
        payee.sweep(address(usd));
        assertEq(token.syncFromPayee(address(usd)), 40e6);
        assertApproxEqAbs(_reward(alice), 30e6, 1);
        assertApproxEqAbs(_reward(bob), 35e6, 2);
    }

    function test_syncFromPayee_emitsRevenueFromPayee_withTheBookedAmount() public {
        lender.setOwed(AGENT, 20e6);
        _pay(100e6);
        payee.sweep(address(usd));
        vm.expectEmit(true, true, false, true, address(token));
        emit RevenueFromPayee(address(payee), address(usd), 80e6);
        token.syncFromPayee(address(usd));
    }

    function test_syncFromPayee_bookingNothing_emitsNothing() public {
        vm.recordLogs();
        assertEq(token.syncFromPayee(address(usd)), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_updateReward_byAnyone_isShared_butNotMarkedAsPayeeRevenue_norBookedTwice() public {
        _pay(80e6);
        payee.sweep(address(usd)); // forwarded to the token, not synced yet

        address contributor = makeAddr("contributor");
        usd.mint(contributor, 10e6);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;
        vm.startPrank(contributor);
        usd.approve(address(token), 10e6);
        vm.recordLogs();
        token.updateReward(_usdOnly(), amounts); // ERC-7254 leaves it open to anyone
        vm.stopPrank();
        assertEq(_revenueEvents(vm.getRecordedLogs()), 0);
        assertApproxEqAbs(_reward(alice), 7.5e6, 1);
        assertApproxEqAbs(_reward(bob), 2.5e6, 1);

        // The sync books the forward, and not the contributor's 10e6 a second time.
        vm.expectEmit(true, true, false, true, address(token));
        emit RevenueFromPayee(address(payee), address(usd), 80e6);
        assertEq(token.syncFromPayee(address(usd)), 80e6);
        assertEq(token.syncFromPayee(address(usd)), 0);
        assertApproxEqAbs(_reward(alice), 67.5e6, 2);
    }

    function test_syncFromPayee_revertsForAnAssetTheTokenDoesNotReward() public {
        eur.mint(address(payee), 100e6);
        payee.sweep(address(eur)); // a payee forwards every asset it is swept in
        assertEq(eur.balanceOf(address(token)), 100e6);
        assertFalse(token.existsTokenReward(address(eur)));

        vm.expectRevert(HoldersAfterCreditorsToken.NotARewardAsset.selector);
        token.syncFromPayee(address(eur));
        assertEq(token.getRewardPerShare(address(eur)), 0);
    }

    function test_syncFromPayee_atZeroSupply_booksNothing_thenOnceThereAreHolders() public {
        MintableHoldersToken empty = new MintableHoldersToken(address(payee), _usdOnly());
        vm.prank(owner);
        payee.setBeneficiary(address(empty));
        _pay(100e6);
        payee.sweep(address(usd));
        assertEq(usd.balanceOf(address(empty)), 100e6);

        vm.recordLogs();
        assertEq(empty.syncFromPayee(address(usd)), 0);
        assertEq(_revenueEvents(vm.getRecordedLogs()), 0);
        assertEq(empty.getRewardPerShare(address(usd)), 0);

        empty.mint(alice, 1e18);
        assertEq(empty.viewReward(alice)[0], 0);
        assertEq(empty.syncFromPayee(address(usd)), 100e6); // the whole balance, once
        assertEq(empty.syncFromPayee(address(usd)), 0);
        assertApproxEqAbs(empty.viewReward(alice)[0], 100e6, 1);
    }

    // ------------------------------------------------------------- the beneficiary after a sale

    function test_afterASale_theResidualGoesToTheBuyer_untilItPointsTheBeneficiaryAtTheToken() public {
        lender.setOwed(AGENT, 20e6);
        vm.prank(owner);
        registry.transfer(AGENT, buyer);
        assertEq(payee.beneficiary(), buyer); // the seller's choice of the token lapsed with the sale

        _pay(100e6);
        payee.sweep(address(usd));
        assertEq(usd.balanceOf(address(lender)), 20e6);
        assertEq(usd.balanceOf(buyer), 80e6);
        assertEq(usd.balanceOf(address(token)), 0);
        vm.recordLogs();
        assertEq(token.syncFromPayee(address(usd)), 0); // does not revert; nothing arrived
        assertEq(_revenueEvents(vm.getRecordedLogs()), 0);
        assertEq(_reward(alice), 0);

        vm.prank(buyer);
        payee.setBeneficiary(address(token));
        assertEq(payee.beneficiary(), address(token));
        _pay(100e6);
        payee.sweep(address(usd)); // the lender is repaid, so all of it is left
        assertEq(token.syncFromPayee(address(usd)), 100e6);
        assertApproxEqAbs(_reward(alice), 75e6, 1);
    }

    function test_afterASale_syncStillBooksWhatArrivedWhileTheTokenWasTheBeneficiary() public {
        _pay(100e6);
        payee.sweep(address(usd)); // forwarded before the sale, not synced
        vm.prank(owner);
        registry.transfer(AGENT, buyer);
        assertEq(payee.beneficiary(), buyer);

        assertEq(token.syncFromPayee(address(usd)), 100e6);
        assertApproxEqAbs(_reward(alice), 75e6, 1);
        assertApproxEqAbs(_reward(bob), 25e6, 1);
    }

    // ------------------------------------------------------------- ERC-7254 accounting

    function test_transferAfterBooking_keepsWhatWasAccruedWithTheSender() public {
        _pay(100e6);
        payee.sweep(address(usd));
        token.syncFromPayee(address(usd));
        address carol = makeAddr("carol");
        vm.prank(alice);
        assertTrue(token.transfer(carol, SUPPLY * 3 / 4));
        assertEq(_reward(carol), 0);
        assertApproxEqAbs(_reward(alice), 75e6, 1);

        _pay(40e6);
        payee.sweep(address(usd));
        token.syncFromPayee(address(usd));
        assertApproxEqAbs(_reward(carol), 30e6, 1);
        assertApproxEqAbs(_reward(alice), 75e6, 1);
        assertApproxEqAbs(_reward(bob), 35e6, 2);
    }

    function test_claimRemaindersStayClaimable_twoEqualHoldersGetOneUnitEachAfterTwoOneUnitRewards() public {
        MintableHoldersToken halves = new MintableHoldersToken(address(payee), _usdOnly());
        address carol = makeAddr("carol");
        address dave = makeAddr("dave");
        halves.mint(carol, 2 ** 60); // a power-of-two supply, so the reward per share is exact
        halves.mint(dave, 2 ** 60);
        vm.prank(owner);
        payee.setBeneficiary(address(halves));

        uint256 booked;
        for (uint256 round; round < 2; ++round) {
            _pay(1); // one unit of the asset
            payee.sweep(address(usd));
            booked += halves.syncFromPayee(address(usd));
            vm.prank(carol);
            halves.getReward(_usdOnly()); // half a unit each after the first round: a claim of zero
            vm.prank(dave);
            halves.getReward(_usdOnly(), dave);
            assertLe(usd.balanceOf(carol) + usd.balanceOf(dave), booked);
        }
        assertEq(booked, 2);
        assertEq(usd.balanceOf(carol), 1);
        assertEq(usd.balanceOf(dave), 1);
    }

    function testFuzz_claimsNeverExceedWhatWasBooked(uint64[4] memory rewards, uint16 claims, uint96 moved) public {
        address carol = makeAddr("carol");
        address[3] memory holders = [alice, bob, carol];
        uint256 booked;
        uint256 paid;
        for (uint256 round; round < 4; ++round) {
            _pay(rewards[round] % 1000); // small rewards, where sub-unit remainders matter
            payee.sweep(address(usd));
            booked += token.syncFromPayee(address(usd));
            if (round == 1) {
                uint256 amount = bound(moved, 0, token.balanceOf(alice));
                vm.prank(alice);
                assertTrue(token.transfer(carol, amount));
            }
            for (uint256 h; h < 3; ++h) {
                if ((claims >> (round * 3 + h)) & 1 == 1) {
                    vm.prank(holders[h]);
                    token.getReward(_usdOnly());
                }
            }
            paid = usd.balanceOf(alice) + usd.balanceOf(bob) + usd.balanceOf(carol);
            assertLe(paid, booked);
        }
        for (uint256 h; h < 3; ++h) {
            vm.prank(holders[h]);
            token.getReward(_usdOnly());
        }
        paid = usd.balanceOf(alice) + usd.balanceOf(bob) + usd.balanceOf(carol);
        assertLe(paid, booked);
        assertLe(booked - paid, 3); // at most a sub-unit remainder per holder is left behind
    }

    function testFuzz_holdersShareOnlyTheResidual(uint96 paid, uint96 owed, uint16 bps) public {
        bps = uint16(bound(bps, 1, 10_000));
        vm.startPrank(owner);
        payee.removeCreditor(address(lender));
        payee.addCreditor(address(lender), bps);
        vm.stopPrank();
        lender.setOwed(AGENT, owed);
        _pay(paid);

        (uint256 toCreditors, uint256 forwarded) = payee.sweep(address(usd));
        assertEq(toCreditors + forwarded, paid);
        assertEq(usd.balanceOf(address(lender)), toCreditors);
        assertEq(token.syncFromPayee(address(usd)), forwarded);
        uint256 a = _reward(alice);
        uint256 b = _reward(bob);
        assertLe(a + b, forwarded);
        assertApproxEqAbs(a, forwarded * 3 / 4, 1);
        assertApproxEqAbs(b, forwarded / 4, 1);
    }
}
