# imd-batcher-phase1

Phase 1 DeploymentBatcher finalize snapshot for an IMD review. Read-only.

forge-std is vendored at `imd-batcher/lib/forge-std`, pin `7117c90c8cf6c68e5acce4f09a6b24715cea4de6` (`PIN` in that directory).

npm packages from `imd-batcher/package-lock.json` are vendored at `imd-batcher/node_modules`. Do not run `npm ci`. IMD refuses writes under `node_modules`.

From the repository root:

```bash
forge test --match-contract 'DeploymentBatcher(ThreeWaySplitTest|Phase1EndpointPoisoningTest|OVaultRuntimeConfigTest)' --summary
```

That command is the baseline: 23 passed, 0 failed, 0 skipped, on this vendored tree.
