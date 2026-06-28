# Deploying a Feature Branch to Staging

Use this workflow to test a branch on the staging server without merging it into `staging` and without standing up a separate environment. The staging server, deploy path, and systemd service are all shared with normal staging deploys.

## When to use this

- You want broader testing of a feature branch before merging
- You want to avoid merge noise on `staging` (easy to revert)
- You do not need a second server or environment

## Prerequisites

The branch tip must have a version tag. Use a suffixed tag to distinguish it from a release tag:

```
vX.Y.Z-branch-name
```

For example:
```
v0.8.0-eval-in-client
```

This format is intentional: Capistrano names release directories with a timestamp prefix (`2026-06-28_12.34.56__vX.Y.Z-suffix`), so sort order is preserved and the suffixed tag does not interfere with normal release history.

### Tag the branch

```bash
git tag -a v0.8.0-eval-in-client -m "Release 0.8.0-eval-in-client"
```

### Push the branch and tag to the server remote

The deploy script pushes the tag automatically, but the server's bare repo must have the branch objects. Push the branch explicitly first if it has not been pushed to `paula-poundstone` before:

```bash
git push paula-poundstone eval-in-client
```

## Deploy the branch

```bash
bin/deploy staging --branch eval-in-client
```

The script:
1. Finds the version tag at the tip of `eval-in-client`
2. Validates the tag exists locally
3. Pushes the tag to `paula-poundstone` and `origin`
4. Runs `cap staging deploy` with `DEPLOY_TAG=v0.8.0-eval-in-client`

Capistrano checks out the tagged commit and writes the tag name to the `VERSION` file in the release directory.

## Revert to the staging branch

Revert by running a normal staging deploy — no flags needed:

```bash
bin/deploy staging
```

This deploys the tip of `staging` (its current `vX.Y.Z` tag) and symlinks `current` to that release. The branch-deploy release remains in the `releases` directory until it ages out of the `keep_releases` window.

For an immediate rollback without a new deploy, use Capistrano directly:

```bash
bundle exec cap staging deploy:rollback
```

## Tag format reference

| Pattern | Used for |
|---|---|
| `vX.Y.Z` | Normal releases from `staging` or `main` |
| `vX.Y.Z-suffix` | Feature branch deploys to staging |

The `--branch` flag accepts any tag matching `vX.Y.Z` or `vX.Y.Z-suffix`. It is not available for production deploys.
