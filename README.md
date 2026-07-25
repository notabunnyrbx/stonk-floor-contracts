# Stonk Floor Contracts

Public Solidity contracts used by Stonk Floor.

## AgentExecutor

`AgentExecutor` lets an owner-designated agent submit tightly constrained token
swaps for a StonkBroker token-bound account. The owner controls:

- The agent address and pause state.
- The allowed input and output tokens.
- Per-trade and per-day token limits.
- A trade cooldown and maximum daily trade count.
- Recovery of tokens held temporarily by the executor.

The executor verifies deadlines, token policies, limits, and minimum output. It
uses Permit2 for router allowance and returns held input and output tokens to
the broker account after a router call.

## Build

Requires Node.js 22 or later.

```sh
pnpm install --frozen-lockfile
pnpm test
```

The compiler is pinned to Solidity `0.8.26`, with optimization enabled and 200
runs. Generated artifacts are written to `artifacts/` and are not committed.

## Deployment

- Network: Robinhood Chain Mainnet
- Chain ID: `4663`
- Current AgentExecutor:
  [`0x9D107E3954B3D88546D74d6b688edec393Abd780`](https://robinhoodchain.blockscout.com/address/0x9D107E3954B3D88546D74d6b688edec393Abd780)

Verify deployed bytecode and constructor arguments against the explorer before
integrating.

## Security

No audit report is included with this release. Do not assume the contract has
been independently audited. Review the source and test your integration before
placing assets under its control. Report vulnerabilities privately as described
in [SECURITY.md](SECURITY.md).

## License

MIT
