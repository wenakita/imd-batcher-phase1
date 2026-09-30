# Phase 1 batcher finalize

Audit the click's Phase 1 path on `DeploymentBatcher`. Do not change production source. Do not deploy. Do not send transactions.

## Snapshot

- Private tree the bytes were copied from: `wenakita/4626` `d3210be8d6104faefdc4aa7e7bdc2807f298ef66`.
- `DeploymentBatcher.sol` itself last changed in `40852178a522d21da75567c352f041b35d7e145c`. This archive does not include the Raydium UI commits as Solidity.
- Decoded ZIP SHA-256: `e4c8a01de9717bed7f19ee2239a6868d4122e21455b9dd865ea2aae845032947`.
- 18 first-party Solidity files plus the Permit2 interfaces `ISignatureTransfer` and `IEIP712` (copied so the import resolves). Permit2 is not in scope.
- Compiler: solc 0.8.30, via-IR, cancun, `optimizer_runs = 200`, `bytecode_hash = none`.
- Dependencies, exact: OpenZeppelin contracts 5.4.0, oapp-evm 0.4.1, oft-evm 4.0.1, lz-evm-protocol-v2 3.0.159, lz-evm-messagelib-v2 3.0.159, `@uniswap/v4-core` 1.0.2, solidity-bytes-utils 0.8.4, forge-std `7117c90c8cf6c68e5acce4f09a6b24715cea4de6`.

## Baseline

Measured on the same two test files before the archive was built, and again after extracting this archive.

Command:

```bash
forge test --match-contract 'DeploymentBatcher(ThreeWaySplitTest|Phase1EndpointPoisoningTest|OVaultRuntimeConfigTest)' --summary
```

Exit code 0. 23 passed, 0 failed, 0 skipped.

| Suite | Passed |
| --- | --- |
| `DeploymentBatcherOVaultRuntimeConfigTest` | 4 |
| `DeploymentBatcherPhase1EndpointPoisoningTest` | 4 |
| `DeploymentBatcherThreeWaySplitTest` | 15 |

## What the click runs

Live batcher `0x9326942e6feEDbEED1C7816b9B77eEE05C2DfBdc` on Base. Phase 1 module `0x4074E61403819dA28DC90D06250dabc6B9Eb7409`. Its core is `0xB49D1FEbb49d81C5CC2497e28dA2C682eaDA50a6`.

`deployPhase1CoreWithSalt` and `finalizePhase1WithSalt` call `_requireOwner`, then `delegatecall` the Phase 1 module. `_requireOwner` allows `msg.sender == params.owner` or `authorizedPhaseCallers[msg.sender]`. For `v1.26.0-vodfevf`, `params.owner` is the CSW `0xAb6d5C10b03300326CD7fAb7267Ae192842967b5`. The registry owner `0xB05Cf01231cF2fF99499682E64D3780d57c80FdD` is not that owner.

The module checks `address(this) != batcher` and reverts `NotBatcherContext`. Under delegatecall, `address(this)` is the shell.

`finalizePhase1Split` then:

- deploys ShareOFT, or adopts a CREATE2 occupant only when `vault()` is `address(0)` or already this vault (`Phase1ShareOFTAlreadyBound` otherwise)
- `setShareOFT`, `setRegistry(address(registry))`, `setVault`, `setWrapper`
- `setMinter(wrapper, true)` once
- `setHubConfig(true, 0, address(0))`
- `setWhitelist` and `setTrustedAdapter` for the wrapper and for `address(this)` (the batcher)
- the same two calls for `vaultActivationBatcher` when that address is nonzero

`shareOftSaltOverride` of zero uses the derived salt. Any other value must equal `deriveShareOftSalt`. A free-form salt reverts `InvalidShareOftSaltOverride`.

Phase 1 does not write the app registry `0x777968CB7F302f3d02C094b119a67DCA9E0b4626`. `setRegistry` receives the shell's own `registry()`, which on this batcher is `0x7773767b72Ea5c7d768E91212f024FD920fC4626`.

Predicted addresses, still empty code: vault `0x4626f92eB5D1775E63bb4e8b1DDf04334b6729be`, wrapper `0x24b5000437273d2238223E72422931Aa7A9c6b6A`, ShareOFT `0x7c3850C2182bC10434C61bDD49518E8507834626`.

## Review priorities

1. Owner. A caller who is not `params.owner` and not an authorized phase caller cannot deploy or finalize. The module cannot be used as a standalone finalizer for the shell.
2. Minter. Finalize grants `setMinter` only to the wrapper. A second minter is the ShareOFT backing bug from job `3ed2b921` (F-1). Do not add a minter in a suggested fix.
3. Trusted adapter. Finalize marks the wrapper, the batcher, and a nonzero `vaultActivationBatcher`. Confirm a third-party deposit to the wrapper is the case the adapter flag is meant to cover, and confirm the flag is actually set on the vault the click deploys.
4. Registry. `setRegistry` targets the batcher registry, not the app registry. Phase 1 must not call `setVault`, `setWrapperForToken`, or `setShareOFTForToken` on `0x777968CB…`.
5. Salt. A nonzero override that is not the derived ShareOFT salt reverts. A colliding ShareOFT bound to a different vault is not adopted.
6. Delegatecall. `phase1Module` is set by the shell owner. Review whether a later `setPhase1Module` can point finalize at a module that skips `setMinter` or `setTrustedAdapter`.

## Out of scope

- Edits to vault, wrapper, or ShareOFT creation code. Those void the three predicted addresses.
- Job `3ed2b921` findings F-1, F-2, and F-3, except where finalize's `setMinter` and `setTrustedAdapter` calls are the control.
- Lottery manager, FriendKey, Ajna implementation, Permit2, Uniswap v4, Raydium, and the app-registry rebind.
- A full Phase 2 or Phase 3 audit. `DeploymentBatcherThreeWaySplitTest` includes deposit bounds, role policy, and a phase 3 weight check because they share the test file. Do not widen the job to those systems.
- `DeploymentBatcherOVaultRuntimeConfigTest` is in the endpoint-poisoning file. It is shell config, not the finalize minter path.

## Tests you may add

Add tests under `imd-batcher/test/imd/`. Keep upstream files unchanged. Useful cases: stranger finalize reverts `NotOwner`; `setMinter` is not granted to a second address; free-form salt reverts; a ShareOFT already bound to another vault reverts; `setRegistry` is the batcher registry.

Record commands, exit codes, and whether a second reviewer seat was available.
