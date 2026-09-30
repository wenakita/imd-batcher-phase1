# imd-batcher-phase1

Phase 1 DeploymentBatcher finalize snapshot for an IMD review. Read-only.

forge-std is vendored at `imd-batcher/lib/forge-std`, pin `7117c90c8cf6c68e5acce4f09a6b24715cea4de6` (`PIN` in that directory). npm packages are not vendored.

Before `forge test`, from `imd-batcher/`:

```bash
npm ci --ignore-scripts
```

Then, from the repository root:

```bash
forge test --match-contract 'DeploymentBatcher(ThreeWaySplitTest|Phase1EndpointPoisoningTest|OVaultRuntimeConfigTest)' --summary
```

That command is the baseline: 23 passed, 0 failed, 0 skipped, after this forge-std pin and `npm ci --ignore-scripts`.
