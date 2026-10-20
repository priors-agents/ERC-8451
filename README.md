# Agent Repay-First Payees (draft ERC)

A revenue address for an agent identity that pays its creditors before its owner. The agent uses the payee as the
address where it is paid (an x402 `payTo`, an ERC-8183 job's provider, an ERC-8004 payment wallet). When anyone sweeps
it, each creditor gets what it is owed, most senior first and up to its agreed share of the sweep, and the rest goes to
the agent's owner. The owner cannot drop a creditor that is still owed, which is what makes the revenue worth lending
against.

An optional section, "Paying holders after creditors", lets an agent pay the holders of an ERC-7254 revenue-sharing
token from what its creditors leave: the token is the payee's beneficiary, never a creditor, and books what a sweep
sends it with `syncFromPayee`, so lenders stay senior and holders come last.

**Status: draft, not submitted.** The text is in
[`ERCS/erc-draft_repay_first_payees.md`](ERCS/erc-draft_repay_first_payees.md). Its `eip: 99902` is a placeholder: the
ERC editors assign the real number when the pull request is opened on ethereum/ERCs. Discussion will open on Ethereum
Magicians first.

## Why

Credit that grows with an agent's income needs repayment from that income, before it can be spent. Lenders build this
one at a time today (Nenrin's taps on Robinhood Chain; Credit Coop's Spigot elsewhere), so only the lender that built a
router can trust it, and nobody else can see that an agent's revenue is already pledged. One interface lets several
lenders share a revenue address in a clear order, and lets payers, explorers and new lenders read the claims.

## What is here

| Path | What |
|---|---|
| `ERCS/erc-draft_repay_first_payees.md` | The ERC text, in the ethereum/ERCs template |
| `src/IRepayFirstPayee.sol` | The payee and creditor interfaces |
| `src/RepayFirstPayee.sol` | A reference payee, and a factory that deploys one per agent at a CREATE2 address (not audited) |
| `test/RepayFirstPayee.t.sol` | Foundry tests, with failing, greedy and gas-burning creditors |
| `src/IHoldersAfterCreditors.sol` | The interface of the optional "Paying holders after creditors" section |
| `src/HoldersAfterCreditorsToken.sol` | A reference ERC-7254 token that is a payee's beneficiary and books what it receives with `syncFromPayee` (not audited) |
| `test/HoldersAfterCreditors.t.sol` | Foundry tests: holders share only what creditors leave, syncs book once, and the token's place after a sale |
| `scripts/lint-erc.sh` | Lints the ERC text with eipw the way the ethereum/ERCs CI does |
| `eipw.toml` | The ethereum/ERCs repository's eipw configuration, copied as is |

## Checks

```bash
forge build
forge test
scripts/lint-erc.sh   # needs eipw: cargo install eipw --version 0.11.0 --locked
```

CI runs all three on every push (`.github/workflows/ci.yml`).

## Related drafts

- Agent Credit Lines: one interface to borrow, repay and default against any lender to agent identities (to be
  published as github.com/priors-agents/erc-agent-credit-lines). A lender implementing it implements a creditor here
  with a few lines.
- Agent Default Registry: lender-reported defaults any contract can check (to be published as
  github.com/priors-agents/erc-agent-default-registry).

## Licence

CC0 1.0 ([LICENSE.md](LICENSE.md)), as the ERC process requires.
