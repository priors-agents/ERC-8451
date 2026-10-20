---
eip: 99902
title: Agent Repay-First Payees
description: A revenue address for an agent identity that pays its creditors before its owner
author: Priors contributors (@priors-agents)
discussions-to: https://ethereum-magicians.org/t/erc-repay-first-payees/0
status: Draft
type: Standards Track
category: ERC
created: 2026-10-20
requires: 20, 165, 721
---

## Abstract

This proposal defines a payee: a contract that an agent identity, held in an [ERC-721](./eip-721.md) identity registry,
uses as the address where it is paid. When the payee is swept, it pays each registered creditor what that creditor says
it is owed, most senior first and up to a share of the swept balance the creditor agreed to, and forwards the rest to the
agent's owner or an address the owner chose. The owner adds creditors, each junior to the ones before, and cannot remove
a creditor that still has a claim. A small creditor interface lets any lender take part, and any payer, explorer or
lender can tell that an identity's revenue address is encumbered.

## Motivation

Lending to an agent against what it earns is safest when repayment comes from the earnings themselves, before the agent
or its owner can spend them. Agent revenue already arrives at addresses the agent names: a pay-to address for HTTP
payments signed with [ERC-3009](./eip-3009.md) transfers, the provider address of an [ERC-8183](./eip-8183.md) job, the
payment wallet of an [ERC-8004](./eip-8004.md) identity. None of these says anything about what happens to the money
once it arrives.

Lenders that route revenue through a contract of their own today can only trust their own contract, and nobody else can
tell that the address is encumbered. A common payee interface lets several lenders share one revenue address with a
clear order of priority, lets a new lender see existing claims before it lends, and lets an agent move between lenders
without changing where it is paid.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT
RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Interfaces

A payee MUST implement `IRepayFirstPayee` and [ERC-165](./eip-165.md), returning `true` for the interface identifier of
`IRepayFirstPayee` and for `0x01ffc9a7`. A creditor MUST implement `IRepayFirstCreditor`.

```solidity
interface IRepayFirstPayee {
    event CreditorAdded(address indexed creditor, uint16 maxShareBps);
    event CreditorRemoved(address indexed creditor);
    event BeneficiarySet(address indexed beneficiary);
    event Swept(address indexed token, uint256 toCreditors, uint256 forwarded);

    function identityRegistry() external view returns (address);
    function agentId() external view returns (uint256);
    function beneficiary() external view returns (address);
    function creditors() external view returns (address[] memory);
    function maxShareBps(address creditor) external view returns (uint16);
    function addCreditor(address creditor, uint16 maxShareBps) external;
    function removeCreditor(address creditor) external;
    function setBeneficiary(address beneficiary) external;
    function sweep(address token) external returns (uint256 toCreditors, uint256 forwarded);
}

interface IRepayFirstCreditor {
    function amountOwed(uint256 agentId, address token) external view returns (uint256);
    function hasClaim(uint256 agentId) external view returns (bool);
    function collect(uint256 agentId, address token, uint256 amount) external returns (uint256 applied);
}
```

### The payee

- `identityRegistry()` and `agentId()` MUST NOT change. The **owner** is the registry's `ownerOf(agentId())` at the
  time of each call.
- `beneficiary()` MUST return the address last set with `setBeneficiary` while the owner that set it still owns the
  identity, and the owner otherwise (including when none is set or the zero address was set). When the registry cannot
  name an owner (its `ownerOf` reverts, as for a burned identity), it MUST return the address last set, or the zero
  address when none is set, and MUST NOT revert.
- `creditors()` MUST return the creditors in order of seniority: the earliest added first.
- `maxShareBps(creditor)` MUST return the share given when the creditor was added, and `0` for an address that is not a
  creditor.

### Adding and removing creditors

- `addCreditor(creditor, maxShareBps)` MUST revert unless called by the owner, and MUST revert if `creditor` is already
  a creditor, is the zero address, or if `maxShareBps` is `0` or greater than `10000`. It MUST place the new creditor
  after every existing one and emit `CreditorAdded`. A payee MAY cap the number of creditors.
- `removeCreditor(creditor)` MUST succeed when called by `creditor` itself. When called by the owner it MUST revert if
  the creditor's `hasClaim(agentId())` returns `true` or reverts. It MUST revert for any other caller. It MUST keep the
  order of the remaining creditors and emit `CreditorRemoved`.
- A creditor's share and position MUST NOT change while it remains a creditor.
- `setBeneficiary(beneficiary)` MUST revert unless called by the owner, and MUST emit `BeneficiarySet`.

### Sweeping

`sweep(token)` MUST be callable by any account. With `B` the payee's balance of the [ERC-20](./eip-20.md) `token` at the
start of the call, it MUST, for each creditor in order of seniority while some of `B` remains:

1. compute `give` as the least of the creditor's `amountOwed(agentId(), token)`, `B * maxShareBps(creditor) / 10000`
   (rounded down), and what remains of `B`;
2. if `give` is not zero, approve the creditor for exactly `give`, call `collect(agentId(), token, give)`, then set the
   approval back to zero;
3. count as paid to that creditor the decrease of the payee's balance across the call.

Then, unless `beneficiary()` is the zero address, it MUST transfer what remains of `B` to `beneficiary()`; when it is
the zero address, what remains stays in the payee and counts as not forwarded. It MUST emit `Swept` with the totals and
return them. A creditor
whose `amountOwed` or `collect` reverts MUST be treated as owed nothing for that sweep; the sweep MUST go on. A payee
SHOULD call each creditor with a bounded amount of gas, so that one creditor cannot make every sweep fail.

### The creditor

- `amountOwed(agentId, token)` MUST return what the identity owes the creditor in `token` and may be paid now.
- `hasClaim(agentId)` MUST return `true` while the creditor has any claim on the identity, due or not.
- `collect(agentId, token, amount)` MUST take at most `amount` of `token` from the calling payee and apply it to what
  the identity owes; it MUST return the amount taken.

## Rationale

- **Plain transfers in, sweeps out.** HTTP payments signed with ERC-3009 and job payouts are plain token transfers that
  call nothing on the receiver. A payee that acts on arrival would need every payer to change; a payee that anyone can
  sweep needs none to change.
- **Seniority by order of addition.** Each creditor lends knowing who is ahead of it. Allowing the owner to reorder or
  re-share creditors would let it subordinate a lender after the loan was made.
- **A share per creditor.** A lender that takes all revenue can starve the agent of what it needs to keep working. The
  share lets the owner and the lender agree on how much of each payment services the debt.
- **The creditor applies the money.** Only the creditor knows which of its loans a payment repays and how. Approving
  exactly `give` and measuring the balance keeps the payee correct whatever the creditor does.
- **Removal needs no claim.** The owner can drop a creditor it no longer uses, but not one that is still owed, which is
  what makes the payee worth lending against. A creditor whose claim check fails is treated as owed, so it cannot be
  dropped by making it unreachable.
- **A beneficiary lapses with its owner.** If a beneficiary outlived a sale, a seller could set its own wallet just
  before selling and, since anyone may sweep, collect the revenue the buyer earns until the buyer noticed. Tying the
  choice to the owner that made it sends post-sale revenue to the buyer without any action from the buyer.
- **The identity, not the owner.** The payee belongs to the identity; after a transfer the new owner controls it but
  inherits its creditors. Whether a debt follows the identity or its former owner is each creditor's choice, expressed
  through `amountOwed` and `hasClaim`.

## Backwards Compatibility

No backward compatibility issues found. The payee is an ordinary address for payers, so existing payment flows need no
change.

## Test Cases

A conforming payee passes these cases, each for one identity whose owner receives what is forwarded:

- With no creditors, a sweep of 100 units forwards 100 units.
- With one creditor owed 30 units at a share of 10000, a sweep of 100 units pays it 30 units and forwards 70 units.
- With one creditor owed 50 units at a share of 2000, a sweep of 100 units pays it 20 units and forwards 80 units.
- With two creditors owed 60 units each at a share of 10000, a sweep of 100 units pays the first 60 units and the second
  40 units, and forwards nothing.
- A creditor whose calls revert, or that tries to take more than it was approved for, is paid nothing and the rest is
  forwarded; the approval to every creditor is zero after the sweep.
- The owner cannot remove a creditor still owed; it can once the creditor is repaid; a creditor can always remove itself,
  and the others keep their order.
- After the identity is transferred, the new owner is the default beneficiary and cannot remove a creditor still owed.
- An owner sets a beneficiary and then transfers the identity; a sweep of 100 units received afterwards forwards 100
  units to the new owner and nothing to the beneficiary the former owner set.
- After the identity is burned, with no beneficiary set, a sweep of 100 units with one creditor owed 30 units pays it 30
  units, forwards nothing, and leaves 70 units in the payee.

## Reference Implementation

`RepayFirstPayee` and a factory that deploys one payee per identity at a CREATE2 address known before deployment
accompany this proposal with their tests. The payee calls each creditor with a fixed gas budget and holds at most eight
creditors.

## Security Considerations

- **The revenue address can be changed.** Payers pay whatever address the agent advertises. An owner can advertise a
  new address and route future revenue around the payee. Creditors SHOULD check, where the address is on chain (such as
  an ERC-8004 payment wallet), that it still points to the payee before each draw, and price the rest as unsecured.
- **Creditors are trusted with their own figures.** A creditor reports its own `amountOwed`. A creditor the owner added
  can over-report and take up to its share of every sweep. Owners SHOULD add only lenders they borrowed from.
- **Creditor calls.** Creditors are external contracts; a payee MUST approve only `give`, MUST reset the approval, and
  SHOULD bound the gas of each call and guard against re-entry into `sweep`, `addCreditor` and `removeCreditor`.
- **Tokens.** Tokens that take a fee on transfer, rebase, or block addresses change what a sweep can pay. Balances are
  measured, not assumed, so accounting stays correct, but a blocked creditor is skipped.
- **Ownership changes.** A transfer of the identity transfers control of the payee with its creditors, and ends the
  former owner's choice of beneficiary. Buyers SHOULD read `creditors()` and each creditor's `hasClaim` before buying.
- **A burned identity.** With no owner to read, no one can configure the payee. Sweeps still pay the creditors, and
  what is left stays in the payee rather than being sent to the zero address. Owners who may burn an identity SHOULD
  set a beneficiary first.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
