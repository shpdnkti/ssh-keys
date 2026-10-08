#!/usr/bin/env bash
# Publish a validated generation; rebuild from fresh main on concurrent updates.
set -euo pipefail

main() {
    local base next attempt status output
    local max_attempts=3
    cd "$(git rev-parse --show-toplevel)"
    # This helper discards only its own unpublished commits when retrying.
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Refusing publication with an unclean working tree" >&2
        return 1
    fi
    base=$(git rev-parse refs/remotes/origin/main)
    export SKIP_PUSH=true

    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        status=0
        output=$(git push --porcelain origin HEAD:main 2>&1) || status=$?
        printf '%s\n' "$output"
        if (( status == 0 )); then return 0; fi

        # Authentication, hooks, permissions and transport failures are not races.
        if ! grep -Eq '^!.*\[rejected\] \((fetch first|non-fast-forward)\)$' <<< "$output"; then
            echo "Publication failed without a concurrent-update rejection; not retrying" >&2
            return "$status"
        fi
        if (( attempt == max_attempts )); then
            echo "Publication exhausted $max_attempts attempts because main kept advancing" >&2
            return 1
        fi
        git fetch --no-tags origin refs/heads/main:refs/remotes/origin/main
        next=$(git rev-parse refs/remotes/origin/main)
        if [[ "$next" == "$base" ]] || ! git merge-base --is-ancestor "$base" "$next"; then
            echo "Remote main did not advance from the publication base; refusing retry" >&2
            return 1
        fi
        echo "Main advanced; rebuilding validated output (attempt $((attempt + 1))/$max_attempts)"
        git reset --hard "$next"
        base=$next
        bash scripts/cleanup_expired.sh
        bash scripts/validate_keys.sh
        bash scripts/deploy_keys.sh
    done
}

main "$@"
