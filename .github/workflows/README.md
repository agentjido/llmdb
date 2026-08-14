# GitHub Actions Workflows

This directory contains automated workflows for managing LLM model metadata updates and releases.

## Workflows

### 1. CI (`ci.yml`)

Runs on every push and pull request to ensure code quality.

**Triggers:**
- Push to `main` branch
- Pull requests to `main` branch

**Jobs:**
- NPM package spike job: build and check `@agentjido/llmdb` on the supported Node.js versions
- Lint job: format check, compile with warnings as errors, Credo, Dialyzer, unused dependency check, Hex audit
- Test job: compile and run the test suite across the supported Elixir/OTP matrix
- Build check job: verify the packaged snapshot is up to date and check history drift

**Matrix Testing:**
- Node.js versions: 22.14, 24
- Elixir versions: 1.18, 1.19
- OTP versions: 27, 28

### 2. Publish Snapshot Catalog (`build-metadata.yml`)

Automatically pulls latest upstream metadata, publishes a content-addressed
snapshot release, and rebuilds the published history bundle from the snapshot
store.

**Triggers:**
- **Schedule**: Daily at 00:00 UTC
- **Manual**: Via workflow_dispatch in GitHub Actions UI

**Jobs:**
1. Pull latest metadata using `mix llm_db.pull`
2. Build the packaged snapshot from refreshed metadata
3. Validate the packaged snapshot with `mix llm_db.build --check --install`, `mix test`, and `mix quality`
4. Commit refreshed metadata inputs back to `main` when they changed
5. Publish the current canonical snapshot using `mix llm_db.snapshot.publish`
6. Rebuild and publish `history.tar.gz` from the published snapshot chain using `mix llm_db.history.rebuild --publish`
7. Validate the published history bundle

**Output:**
- Updated immutable `snapshot-<snapshot_id>` release assets
- Updated immutable `history-<snapshot_id>` release assets for the latest published snapshot

### 3. Release to Hex and NPM (`release.yml`)

Prepares one release from the committed snapshot on `main`, then publishes the
same version to Hex.pm and NPM.

**Triggers:**
- Manual workflow dispatch

**Jobs:**
1. Validate the committed snapshot with `mix llm_db.build --check --install`
2. Run tests and quality checks
3. Synchronize the Elixir and NPM package versions to the current CalVer release
4. Generate the changelog and tag using `git_ops`
5. Validate both release packages without publishing
6. Push release commits and tags
7. Publish to Hex.pm
8. Publish `@agentjido/llmdb` to NPM with trusted publishing
9. Create a GitHub release after both registry publishes succeed

**Version Format:**
- Date-based CalVer: `YYYY.M.N` (for example, `2026.5.1`)

## Setup Instructions

### 1. Required Secrets

Configure this secret in your GitHub repository settings:

#### `HEX_API_KEY`

Your Hex.pm API key for publishing packages.

**How to get it:**
1. Login to [hex.pm](https://hex.pm)
2. Go to Settings → API keys
3. Create a new key with publish permissions
4. Copy the key

**Add to GitHub:**
1. Go to repository Settings → Secrets and variables → Actions
2. Click "New repository secret"
3. Name: `HEX_API_KEY`
4. Value: Your Hex API key
5. Click "Add secret"

NPM publishing does not use an `NPM_TOKEN`. Configure NPM Trusted Publishing
for `@agentjido/llmdb` with these values:

- Provider: GitHub Actions
- Organization: `agentjido`
- Repository: `llmdb`
- Workflow filename: `release.yml`
- Allowed action: `npm publish`

Configure it from an authenticated maintainer workstation with:

```bash
npx npm@11.19.0 trust github @agentjido/llmdb \
  --repo agentjido/llmdb \
  --file release.yml \
  --allow-publish \
  --yes
```

The NPM publish job uses a short-lived GitHub OIDC identity and creates package
provenance automatically.

### 2. Permissions

The release workflow uses `GITHUB_TOKEN` with these permissions:
- `contents: write` - Create release commits, tags, and the GitHub release
- `id-token: write` - Request the short-lived NPM trusted-publishing identity

These are configured in each workflow file and should work automatically.

### 3. Optional Configuration

#### Cron Schedule

To change the update frequency, edit `build-metadata.yml`:

```yaml
on:
  schedule:
    - cron: '0 0 * * 1'  # Every Monday at 00:00 UTC
```

Cron examples:
- `'0 0 * * *'` - Daily at midnight UTC
- `'0 0 * * 0'` - Weekly on Sunday
- `'0 0 1 * *'` - Monthly on the 1st

## Manual Operations

### Manually Trigger Snapshot Publish

1. Go to Actions tab in GitHub
2. Select "Publish Snapshot Catalog" workflow
3. Click "Run workflow"
4. Select branch (usually `main`)
5. Click "Run workflow"

### Manually Create a Release

Releases package the committed snapshot. To manually release:

1. Ensure the latest snapshot has been published: `mix llm_db.snapshot.publish`
2. Rebuild the published history bundle if needed: `mix llm_db.history.rebuild --publish`
3. Prepare release: `mix llm_db.release prepare`
4. Review version in `mix.exs`
5. Commit and push to main
6. Run the "Release to Hex and NPM" workflow on `main`
7. The workflow publishes the same immutable version to Hex.pm and NPM

## Workflow Scripts

Helper scripts in `.github/workflows/scripts/`:

### `generate_summary.sh`

Generates PR description for metadata updates with:
- Provider and model counts
- Snapshot publication details
- Generated timestamp
- Review checklist

### `generate_release_notes.sh`

Generates GitHub release notes with:
- Snapshot version and statistics
- Provider breakdown
- Installation instructions

## Troubleshooting

### Workflow Not Triggering

**Problem:** Update workflow doesn't run on schedule

**Solutions:**
1. Check workflow is enabled in Actions tab
2. Verify cron syntax is correct
3. Note: Scheduled workflows may be delayed during high GitHub load
4. Try manual trigger to test

### Release Not Publishing

**Problem:** Publish workflow doesn't trigger after metadata merge

**Solutions:**
1. Verify provider metadata or generated artifacts were actually modified
2. Check commit message contains "Update model metadata"
3. Review workflow logs in Actions tab
4. Ensure `HEX_API_KEY` secret is set correctly

### Test Failures

**Problem:** CI fails on specific Elixir/OTP combinations

**Solutions:**
1. Review test output in Actions logs
2. Check matrix exclusions in `ci.yml`
3. Test locally with same Elixir/OTP versions
4. Update matrix if version is no longer supported

### Permission Errors

**Problem:** Workflow can't create branches or PRs

**Solutions:**
1. Verify workflow has `contents: write` and `pull-requests: write` permissions
2. Check repository settings → Actions → General → Workflow permissions
3. Ensure "Allow GitHub Actions to create and approve pull requests" is enabled

## Best Practices

1. **Review All Metadata PRs**: Always review automated PRs before merging
2. **Test Before Release**: CI runs automatically, but check test results
3. **Monitor Releases**: Check Hex.pm after publish to verify release
4. **Keep Secrets Secure**: Rotate `HEX_API_KEY` periodically
5. **Update Dependencies**: Keep actions versions current (e.g., `@v4` → `@v5`)

## Development

To test workflow changes:

1. Create a branch with workflow modifications
2. Push to GitHub
3. Workflows won't run on branches, but you can:
   - Use `workflow_dispatch` for manual testing
   - Create a PR to see CI in action
   - Merge to main to test full pipeline

## Support

For issues or questions:
1. Check workflow logs in Actions tab
2. Review this README
3. Check GitHub Actions documentation
4. Open an issue in the repository
