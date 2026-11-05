# pix-vault

A per-network vault designed to deliver PIX on-ramp purchases on EVM chains
from a stablecoin reserve.

> **Status: experimental. Not deployed. Not audited.** Do not use it with real funds.

## What it is

PIX is Brazil's instant payment system. In a PIX on-ramp, a customer pays in
Brazilian reais and receives crypto in their own wallet.

`VelloraPixVault` is designed as the on-chain part of that flow on one EVM
network. The vault holds a **reserve** of the network's stablecoin (USDT, USDG
and so on). After a customer pays, an off-chain **operator** account asks the
vault to buy the requested token with part of the reserve and to deliver it
straight to the customer's address. The swap route is built off-chain (for
example from a DEX router's ABI or an aggregator's API) and passed to the vault
as calldata. The vault does not trust the route: it limits what the route can
spend and checks what the recipient actually received.

The same contract is meant to be deployed once per network, with the same
bytecode everywhere.

- Source: [`src/VelloraPixVault.sol`](src/VelloraPixVault.sol), Solidity 0.8.36.
- Built on OpenZeppelin Contracts 5.6.1 (`Ownable2Step`, `Pausable`,
  `ReentrancyGuard`, `SafeERC20`).
- Compiled with the optimizer (200 runs) for the `cancun` EVM version. The
  runtime code is 5,847 bytes and uses `PUSH0` and `MCOPY`, so the target chain
  must support those opcodes.
- No proxy and no upgrade path. The runtime code has no `DELEGATECALL`,
  `SELFDESTRUCT`, `CREATE` or `CREATE2`.

## Roles

| Role | Can do |
|---|---|
| **Owner** (`Ownable2Step`) | `setReserve`, `setOperator`, `setAllowedTarget`, `setLimits`, `pause`, `unpause`, and `withdraw` any ERC-20 or the native coin (`token = address(0)`) to any non-zero address, also while paused. Ownership moves in two steps (`transferOwnership`, then `acceptOwnership` by the new owner). |
| **Operator** (`isOperator`) | `executeBuy` and `transferReserve`. |
| Anyone else | Send native coin or tokens to the vault. Nothing else. |

## How an order works

```solidity
function executeBuy(
    bytes32 orderId,
    address recipient,
    address tokenOut,   // address(0) = native coin
    uint256 amountIn,   // reserve units the route may use
    uint256 minOut,     // minimum the recipient must receive
    address spender,    // address approved to pull the reserve
    Call[] calldata calls // {target, data} pairs, run in order
) external returns (uint256 delivered, uint256 spent);
```

1. **Checks.** The caller is an operator, the vault is not paused and the call is
   not reentrant. The reserve is set, `recipient` is neither `address(0)` nor the
   vault, `tokenOut` is not the reserve, `spender` is allowlisted and `orderId`
   has not been used. `amountIn` must be non-zero and within the caps.
2. **Snapshot.** The vault records the recipient's `tokenOut` balance (its native
   balance when `tokenOut` is `address(0)`) and its own reserve balance.
3. **Approve.** The vault approves `spender` for exactly `amountIn` of the reserve.
4. **Calls.** Each call runs in order as a plain `CALL` with zero value. Every
   target must be allowlisted and can be neither the reserve token nor the vault.
   If a call fails, the whole order reverts with `CallFailed(index, returnData)`.
5. **Spend.** The approval is reset to zero. The net reserve spend (balance before
   minus balance after) must be greater than zero (`NothingSpent`) and at most
   `amountIn` (`Overspent`).
6. **Delivery.** The recipient's balance change must be greater than zero and at
   least `minOut` (`InsufficientDelivery`).
7. **Event.** `BuyExecuted(orderId, recipient, tokenOut, amountIn, spent, delivered, spender)`.

If anything fails, the order reverts as a whole: nothing moves and `orderId`
stays unused, so the same id can be retried.

A route is usually one or two calls. A Uniswap v3 `SwapRouter02` order is a
single call with `spender` set to the router: `exactInputSingle` or
`exactInput`, or, for native output, a `multicall` that swaps to the wrapped
native coin and ends with `unwrapWETH9`.
A Universal Router order that pays through Permit2 is two calls,
`Permit2.approve(reserve, router, amountIn, expiration)` and then
`router.execute(...)`, with `spender` set to Permit2.
[`test/fork/DexKit.sol`](test/fork/DexKit.sol) has encoders for these routers.

For a purchase of the reserve stablecoin itself there is no swap: the operator
calls `transferReserve(orderId, recipient, amount)`. It goes through the same
operator, pause, reentrancy, order-id and cap checks, then transfers the reserve
(`ReserveTransferred`).

## Safety properties

What the contract enforces on-chain:

- Only operators can run orders. Only the owner can configure, pause or withdraw.
- Each `orderId` can succeed once per deployment.
- The vault's own code grants a single ERC-20 allowance: on the reserve, to the
  order's allowlisted `spender`, for exactly `amountIn`, reset to zero before
  `executeBuy` returns. (Calls to allowlisted targets run as the vault, so they
  can create other approvals, such as the Permit2 one in a Universal Router
  route. See the trust model.)
- Calls carry no native value, and the reserve token and the vault itself are
  never valid call targets, even if allowlisted.
- The net reserve spend is measured as a balance change, so no route can take
  more than `amountIn`, whichever contract pulls the funds.
- Delivery is measured at the recipient, as a balance change. For a
  fee-on-transfer token it is the amount actually received, net of the fee.
- `minOut` is enforced by the vault itself, independently of the router's own
  minimum. A zero delivery always reverts, even with `minOut = 0`.
- Per-order cap, optional daily cap and pause. Pause blocks `executeBuy` and
  `transferReserve`; the owner's admin functions keep working.
- `executeBuy` and `transferReserve` share one reentrancy lock.

## Trust model

- The **operator** chooses every parameter of an order: recipient, `tokenOut`,
  `amountIn`, `minOut`, `spender` and the calls. The checks above protect against
  a misbehaving route or call target. They do **not** protect against a
  compromised operator key: with one, an attacker can send up to
  `maxAmountPerOrder` per order and up to `dailyCap` per UTC day to any address
  (with no daily bound at all when `dailyCap` is 0). The owner can stop this with
  `pause` or `setOperator(operator, false)`.
- The **owner** can withdraw everything at any time. Use a multisig.
- The **allowlist** is the main safety boundary. A single list covers both
  spenders and call targets. If the owner allowlists a token contract, or a
  generic executor that acts on its caller's balance, an operator can move assets
  the vault holds other than the reserve.

## Known limitations

- `maxAmountPerOrder = 0` blocks every order, and it starts at 0. `dailyCap = 0`
  means no daily limit.
- The daily window is a fixed UTC calendar day that resets on the first order
  of a new day, so up to twice `dailyCap` can leave within seconds around 00:00
  UTC. Until that first order, `spentToday()` still shows the previous day's total.
- Caps are charged with `amountIn`, not the measured spend, in raw units of the
  reserve token. `setReserve` does not rescale them, so update the caps when
  switching to a token with different decimals.
- `setReserve` only works while the vault holds none of the current reserve, so
  a dust transfer of that token can make it revert until the owner withdraws again.
- `renounceOwnership()` is inherited from OpenZeppelin and not disabled. One call
  leaves the vault without an owner while existing operators keep working within
  the caps.
- The vault has no deadline of its own. A delayed transaction still executes as
  long as the delivery meets `minOut`, unless the route's calldata carries a
  deadline. In the test encoders, the PancakeSwap v2 and Universal Router calls
  set one (`block.timestamp + 600`); the `SwapRouter02`-style calls do not.
- `orderId` is an opaque `bytes32` that is not bound to the order's parameters.
- A net inflow of reserve during the calls, or a drop in the recipient's balance,
  reverts with an arithmetic panic (`0x11`) instead of a named error.

## What it deliberately does not do

- No token or route registry: routes arrive as calldata.
- No price oracle and no calldata decoding.
- No fees.
- No user deposits and no per-user accounting.
- No signed orders (EIP-712) and no EIP-1271: the operator is the trust root.
- No chain-specific logic: the contract never reads `block.chainid`.
- No upgradeability.

## Networks covered by the fork tests

| Network | Chain ID | Reserve in the tests | Routers exercised |
|---|---|---|---|
| BNB Smart Chain | 56 | USDT (18 decimals) | PancakeSwap v3 SmartRouter, PancakeSwap v2 router, Uniswap v3 SwapRouter02 |
| Ethereum | 1 | USDT | Uniswap v3 SwapRouter02 |
| Polygon PoS | 137 | USDT0 | Uniswap v3 SwapRouter02 |
| OP Mainnet | 10 | USDT | Uniswap v3 SwapRouter02 |
| Arbitrum One | 42161 | USD₮0 | Uniswap v3 SwapRouter02 |
| Base | 8453 | USDT | Uniswap v3 SwapRouter02 |
| Avalanche C-Chain | 43114 | USDt | Uniswap v3 SwapRouter02 |
| Robinhood Chain | 4663 | USDG | Uniswap v3 SwapRouter02, Universal Router 2.1.1 (paying through Permit2) |

Every reserve except BSC USDT has 6 decimals. The symbols differ between
networks, so match the reserve by address, not by symbol. The tests never read
the chain ID; the column is for reference. The addresses are in
[`test/fork/`](test/fork/).

Each fork setUp deploys a fresh vault and funds it with 1,000 units of the
reserve. Swap orders use 100 units, with `minOut` set to 97% of the network's
own on-chain quote (QuoterV2 or `getAmountsOut`); the impossible and too-high
`minOut` cases use twice the quote. Every successful swap asserts that the
delivery covers `minOut`, that the spend is at most `amountIn` and that the
reserve allowance to the spender is back to zero. The `transferReserve` tests
send 50 units and check the recipient's balance.

- **Uniswap v3 suite** (`UniV3ForkSuite`, 6 tests on each of the 8 networks):
  reserve to wrapped native; reserve to native coin (multicall + `unwrapWETH9`);
  reserve to wrapped native to a third token (two hops, using the first candidate
  token with a pool and a quote; Robinhood Chain has no candidate configured, so
  there the test logs a message and returns early, and Foundry reports it as a
  pass); an impossible `minOut` reverts without moving the reserve;
  `transferReserve`; and `tokenOut == reserve` is rejected.
- **PancakeSwap on BSC** (`Fork_bsc`, 7 tests): v3 single hop, multi-hop and
  native output; v2 to a token and to native BNB; `transferReserve`; and a
  too-high `minOut` reverts with the reserve untouched.
- **Universal Router 2.1.1 on Robinhood Chain** (`Fork_robinhood_ur`, 3 tests):
  the 2.1.1 input layout (with its extra `minHopPriceX36` array, all zeros) to
  WETH and to native ETH, and a check that the older 1.2/2.0 layout reverts.

That is 58 fork cases in total. The fork tests read live chain state and are not
pinned to a block, so their results can change as liquidity moves. They are not
run in CI.

The fork tests are compiled with via-IR, so they deploy a via-IR build of the
vault (`VelloraPixVault.via-ir` in `forge build --sizes`, with a 4,802-byte
runtime). The unit tests and the deployment script use the default build
described above.

On 5 November 2026 (23:35–23:38 UTC) all 58 fork cases passed against forks of
the live networks, through the public RPC fallbacks and with the same forge and
anvil commands as under [Fork tests](#fork-tests). On Robinhood Chain, the
reserve to wrapped native to token case passed as the early return described
above. Because `minOut` comes from the route's own quote, a pass shows that the
vault's checks hold, not that the route found a good price.

## Running the tests

Requirements: [Foundry](https://getfoundry.sh) (CI uses v1.7.1) and Node.js with
npm (CI uses Node 22). npm only installs OpenZeppelin Contracts into
`node_modules/`.

```bash
npm ci
forge build
forge test --no-match-path 'test/fork/*'
```

The last command runs the 12 unit tests, which use mock tokens and a mock DEX and
need no RPC. `forge build` also compiles the fork tests with via-IR (see
`foundry.toml`), which takes longer.

### Fork tests

Each fork suite selects its network in `setUp` from an environment variable and
falls back to a public RPC endpoint when the variable is unset:

`BSC_RPC_URL`, `ETH_RPC_URL`, `POL_RPC_URL`, `OP_RPC_URL`, `ARB_RPC_URL`,
`BASE_RPC_URL`, `AVAX_RPC_URL`, `ROBINHOOD_RPC_URL`

```bash
./run-fork-battery.sh
FOUNDRY_PROFILE=fork forge test --match-contract Fork_robinhood_ur \
  --fork-url "${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}" -vv
```

`run-fork-battery.sh` needs `anvil` and `cast`. It runs `Fork_bsc` and the
Uniswap v3 suite one network at a time, prints the PASS/FAIL lines and writes
full logs to `$LOG_DIR` (default `/tmp/pix-vault-fork`). For OP Mainnet and Base
it starts local anvil forks with `--chain-id 1` and passes them as `--fork-url`.
That anvil instance only gives forge a starting chain that is not an OP Stack
chain: each setUp still forks the network's own RPC, and that is the state the
tests read. It works around a Foundry 1.7.1 failure after the Isthmus upgrade
(`Missing operator fee scalar for isthmus L1 Block`), which appears when the OP
Mainnet or Base RPC is passed directly as `--fork-url`. Because each setUp
selects its own fork, running those two suites without `--fork-url` also
avoids it.

Keep in mind:

- the script exits with status 0 even when a test fails, so read its output;
- when it finishes it kills every process matching `anvil --fork-url`;
- it does not run `Fork_robinhood_ur`, hence the second command above.

## Deployment

[`script/DeployVelloraPixVault.s.sol`](script/DeployVelloraPixVault.s.sol)
deploys through the canonical CREATE2 deployer
`0x4e59b44847b379578588920cA78FbF26c0B4956C`. The salt is `keccak256(SALT)`
(default `SALT` is `vellora-pix-vault-v1`) and the init code is the creation code
followed by `abi.encode(OWNER)`.

```bash
# Dry run: simulates the deployment and prints the predicted address; nothing is sent.
OWNER=0x... forge script script/DeployVelloraPixVault.s.sol --rpc-url <rpc>
# Deploy: add --broadcast and your signer options.
```

- If code already exists at the predicted address, the script stops there.
- The address depends on the owner, the salt and every byte of the init code.
  That includes the metadata hash of the sources, so any source change (even a
  comment), compiler setting or import path gives a different address.
- The reserve is set after deployment (`setReserve`), so the init code is
  identical on every network.
- Before the first order the owner must call `setReserve`, `setOperator` and
  `setLimits`, plus `setAllowedTarget` for every router or spender the routes use.

## Repository layout

| Path | Contents |
|---|---|
| `src/VelloraPixVault.sol` | The vault |
| `script/DeployVelloraPixVault.s.sol` | CREATE2 deployment script |
| `test/unit/` | Unit tests with mock tokens and a mock DEX |
| `test/fork/` | Mainnet fork tests (one or two contracts per network) and the `DexKit` calldata encoders |
| `run-fork-battery.sh` | Runs the fork suites network by network |
| `lib/forge-std/` | Vendored forge-std 1.16.2: upstream commit 5cf980e, the v1.16.2 tag plus one Dependabot commit that only bumps action pins in forge-std's own CI workflow |

## Status

Experimental. The contract has not been deployed to any network and has not been
audited. Known test gaps include:

- no test triggers `Overspent`: in the overspend unit test, the mock reserve
  token's `transferFrom` (called by the mock DEX) fails on the 10-unit
  allowance first, and the test catches the resulting `CallFailed` with a bare
  `expectRevert`;
- no test triggers `ReserveNotSet`, `InvalidRecipient`, `AmountZero` or
  `NativeTransferFailed`; `CallFailed` is reached only under a bare
  `expectRevert`, and no test asserts an event;
- no test uses a fee-on-transfer token (the fee-on-transfer encoders in
  `test/fork/DexKit.sol` are currently unused);
- `InvalidTokenOut` is checked only in the fork tests;
- no test withdraws the native coin or checks that `pause` blocks
  `transferReserve`;
- the fork tests are not pinned to a block.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## History

Written in September 2026 inside Vellora's private repositories and open-sourced
in November 2026. Before publication the history was redacted of internal
references. The first two commits keep their original author dates (7 and 8
September 2026, Brasília time, UTC−3), with internal-only files, lines and
commit-message passages removed. The commits after them were made on 5 November
2026 to trim test fixtures, translate, license and document the code, and set up
CI; each message says what it changes. All committer dates are from 5 November
2026 (Brasília time), when the history was rewritten, and the first seven
November commits share one author time because they were re-created together.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). The vendored
`lib/forge-std` keeps its own license (MIT OR Apache-2.0). Every commit before
the one that adds `LICENSE` (the two September commits and the first five
November commits) still carries `MIT` SPDX headers, and their `package.json`
says ISC, the npm default; the Apache-2.0 headers start with the commit that
adds `LICENSE`.
