#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/validate-keys-test.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT
REPO="$FIXTURE_ROOT/repo"
mkdir -p "$REPO/scripts" "$REPO/bin" "$REPO/meta" "$REPO/keys/alice"
cp "$PROJECT_ROOT/scripts/validate_keys.sh" "$REPO/scripts/validate_keys.sh"

fail() {
  echo "❌ $*" >&2
  exit 1
}

# Every external repository/key interaction is a local fixture or mock. Never
# copy or execute the real repository's bin/yq, keys, or Git configuration.
cat > "$REPO/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'rev-parse --show-toplevel' ]] || exit 2
printf '%s\n' "$VALIDATOR_TEST_REPO"
MOCK
cat > "$REPO/bin/ssh-keygen" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 3 && "$1" == '-l' && "$2" == '-f' ]]
[[ "$3" == "$VALIDATOR_TEST_REPO/keys/alice/fixture_rsa.pub" ]]
MOCK
cat > "$REPO/bin/yq" <<'MOCK'
#!/usr/bin/env python3
import json
import os
import signal
import sys
import time

if len(sys.argv) != 4 or sys.argv[1] != "e":
    sys.exit("unsupported mock yq invocation")
expression, path = sys.argv[2:]
with open(path, encoding="utf-8") as stream:
    data = json.load(stream)

if expression == ".environments[]":
    mode = os.environ.get("VALIDATOR_TEST_PRODUCER", "normal")
    # Match a native producer's SIGPIPE exit status instead of Python's
    # BrokenPipeError handling. The tail is larger than pipe capacity, so the
    # legacy early-exit grep must break the pipe regardless of scheduling.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    for environment in data["environments"]:
        os.write(1, (environment + "\n").encode())
    if mode == "slow":
        time.sleep(0.05)
        for _ in range(512):
            os.write(1, b"unrelated-environment\n" * 1024)
    elif mode == "error":
        sys.stderr.write("fixture environment producer failed\n")
        sys.exit(23)
    elif mode != "normal":
        sys.exit("unknown producer mode")
    sys.exit(0)

key = data["keys"][0]
values = {
    ".user": data["user"],
    ".keys | length": len(data["keys"]),
    ".keys[].filename": key["filename"],
    ".keys[0].environments | length": len(key["environments"]),
    ".keys[0].environments[0]": key["environments"][0],
}
values.update({f".keys[0].{name}": key[name] for name in
               ("filename", "comment", "added_at", "expires_at", "revoked")})
if expression not in values:
    sys.exit("unsupported mock yq expression: " + expression)
value = values[expression]
print("null" if value is None else str(value).lower() if isinstance(value, bool) else value)
MOCK
chmod +x "$REPO/bin/git" "$REPO/bin/ssh-keygen" "$REPO/bin/yq"
printf 'fixture only; not a public key\n' > "$REPO/keys/alice/fixture_rsa.pub"

write_fixture() {
  local requested="$1"
  shift
  python3 - "$REPO" "$requested" "$@" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
metadata = {
    "user": "alice",
    "keys": [{
        "filename": "fixture_rsa.pub",
        "comment": None,
        "added_at": "2026-01-01T00:00:00Z",
        "expires_at": None,
        "revoked": False,
        "environments": [sys.argv[2]],
    }],
}
# JSON is valid YAML; the small mock deliberately supports only these fixtures.
(root / "meta/alice.yaml").write_text(json.dumps(metadata), encoding="utf-8")
(root / "envs.yaml").write_text(json.dumps({"environments": sys.argv[3:]}), encoding="utf-8")
PY
}

run_validator() {
  local script="${1:-validate_keys.sh}"
  STATUS=0
  (cd "$REPO" && VALIDATOR_TEST_REPO="$REPO" IS_TRACE=false \
    PATH="$REPO/bin:$PATH" bash "scripts/$script") > "$FIXTURE_ROOT/output" 2>&1 || STATUS=$?
}

assert_valid() {
  run_validator
  [[ "$STATUS" == 0 ]] || { cat "$FIXTURE_ROOT/output" >&2; fail "$1"; }
  grep -F '✅' "$FIXTURE_ROOT/output" >/dev/null || fail "validator did not finish: $1"
}

assert_invalid_environment() {
  run_validator "${2:-validate_keys.sh}"
  [[ "$STATUS" == 1 ]] || fail "$1: expected exit 1, got $STATUS"
  grep -F '不在 envs.yaml 中定义' "$FIXTURE_ROOT/output" >/dev/null ||
    { cat "$FIXTURE_ROOT/output" >&2; fail "$1: failed for an unrelated reason"; }
}

export VALIDATOR_TEST_PRODUCER=normal
write_fixture prod stage prod development
assert_valid 'existing environment must pass'
write_fixture missing stage prod development
assert_invalid_environment 'missing environment must fail'
write_fixture prod prod-blue
assert_invalid_environment 'partial environment name must not match'
write_fixture 'prod[blue]' 'prod[blue]'
assert_valid 'regex metacharacters must match literally'
write_fixture 'prod.east' prod-east
assert_invalid_environment 'regex dot must not match a different character'
write_fixture 'prod.*' prod-east
assert_invalid_environment 'regex wildcard must not match another name'
write_fixture '--prod' stage '--prod'
assert_valid 'leading dash must not be parsed as a grep option'

# Verify the regression fixture actually reproduces the previous SIGPIPE, then
# run both old and fixed validators against that exact producer and first match.
write_fixture prod prod
export VALIDATOR_TEST_PRODUCER=slow
producer_status=0
"$REPO/bin/yq" e '.environments[]' "$REPO/envs.yaml" |
  grep -q '^prod$' || producer_status=$?
[[ "$producer_status" == 141 ]] ||
  fail "legacy pipeline must reproduce SIGPIPE (141), got $producer_status"
python3 - "$REPO/scripts/validate_keys.sh" "$REPO/scripts/legacy_validate_keys.sh" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
fixed = 'grep -Fx -- "$env" >/dev/null'
if source.count(fixed) != 1:
    sys.exit("expected exactly one fixed environment check")
pathlib.Path(sys.argv[2]).write_text(source.replace(fixed, 'grep -q "^$env$"'), encoding="utf-8")
PY
assert_invalid_environment 'legacy validator must reject a valid first match after SIGPIPE' legacy_validate_keys.sh
assert_valid 'fixed validator must drain the slow producer and accept its first match'

export VALIDATOR_TEST_PRODUCER=error
assert_invalid_environment 'producer failure must still fail validation even after a match'
grep -F 'fixture environment producer failed' "$FIXTURE_ROOT/output" >/dev/null ||
  fail 'producer failure fixture was not exercised'
write_fixture all prod
assert_valid 'all must retain its environment-list bypass'

echo '✅ validate_keys tests passed (including legacy SIGPIPE reproduction)'
