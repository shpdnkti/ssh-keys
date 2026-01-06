# SSH Key Management Repository - AI Agent Instructions

## Project Overview
This repository manages SSH public keys for multiple environments (paas3-dev, bkbase-stage, bk-ctrl). Users submit pull requests to add their keys, which are validated, deployed to `authorized_keys` files, and automatically cleaned up when expired. Public keys are now stored uniformly under `keys/{user}/`, and access environments are configured in the meta files.

## Architecture
- **environments**: Defined in `envs.yaml` as an array of environment names
- **keys**: Stored uniformly in `keys/{user}/{filename}` where filename is `YYYY-MM-DD_{id}_rsa.pub`
- **metadata**: Unified YAML files in `meta/{user}.yaml` containing user info, allowed environments, and key details
- **authorized_keys**: Auto-generated files in `authorized_keys/{env}` with SSH keys and comments

## Key Data Structures
Metadata file example (`meta/adevjoe.yaml`):
```yaml
user: adevjoe
environments:
  - bk-ctrl
keys:
  - filename: 2025-12-18_49599_rsa.pub
    comment: adevjoe@bk-ctrl
    added_at: "2025-12-18T02:20:58Z"
    expires_at: "2026-06-18T14:20:58Z"
    revoked: false
```

Authorized keys format: `ssh-rsa AAAAB3... user:filename`

## Critical Workflows
- **Adding keys**: Place `.pub` file in `keys/{user}/`, create/update `meta/{user}.yaml` with environments list
- **Validation**: Run `scripts/validate_keys.sh` - checks OpenSSH format, metadata completeness, no orphan keys
- **Deployment**: Run `scripts/deploy_keys.sh` - generates `authorized_keys/{env}` from active keys of users allowed in that env
- **Cleanup**: Run `scripts/cleanup_expired.sh` - marks expired keys as `revoked: true` and commits

## Conventions
- Use `yq` for YAML processing (installed in `bin/`)
- Dates in ISO8601 UTC format (`%Y-%m-%dT%H:%M:%SZ`)
- Filenames: `{expires_date}_{random_id}_rsa.pub` (e.g., `2025-12-18_49599_rsa.pub`)
- Comments: `{user}@{env}` in metadata, `{user}:{filename}` in authorized_keys
- Git commits by "GitHub Actions" user for automation

## Automation
- GitHub Actions workflows handle validation on PR, deployment on merge
- Periodic cleanup via scheduled jobs
- All scripts use `set -euo pipefail` for strict error handling

## Common Tasks
- **Add user key**: Create `keys/{user}/{date}_{id}_rsa.pub`, add entry to `meta/{user}.yaml` with environments
- **Revoke key**: Set `revoked: true` in metadata
- **Extend expiration**: Update `expires_at` in metadata
- **Validate changes**: Run `scripts/validate_keys.sh`
- **Deploy**: Run `scripts/deploy_keys.sh` (only on main/master branch)

## Reference Files
- `envs.yaml`: Environment list
- `meta/adevjoe.yaml`: Metadata example
- `scripts/deploy_keys.sh`: Deployment logic
- `scripts/validate_keys.sh`: Validation rules
- `authorized_keys/paas3-dev`: Generated output example