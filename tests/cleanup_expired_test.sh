#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "❌ $*" >&2
  exit 1
}

setup_fixture() {
  FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cleanup-expired-test.XXXXXX")"
  REPO="$FIXTURE_ROOT/repo"
  REMOTE="$FIXTURE_ROOT/remote.git"

  git init -q -b main "$REPO"
  git init -q --bare "$REMOTE"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Cleanup Test"
  git -C "$REPO" remote add origin "$REMOTE"

  mkdir -p "$REPO/bin" "$REPO/keys/alice" "$REPO/meta" "$REPO/scripts"
  cp "$PROJECT_ROOT/scripts/cleanup_expired.sh" "$REPO/scripts/cleanup_expired.sh"
  cp "$PROJECT_ROOT/tests/helpers/yq" "$REPO/bin/yq"
  cp "$PROJECT_ROOT/tests/helpers/date" "$REPO/bin/date"
  chmod +x "$REPO/bin/yq" "$REPO/bin/date"

  printf 'placeholder\n' > "$REPO/keys/alice/live.pub"

  cat > "$REPO/meta/alice.yaml" <<'YAML'
user: alice
keys:
  - filename: missing.pub
    comment: alice@missing
    added_at: "2026-01-01T00:00:00Z"
    expires_at: "2099-01-01T00:00:00Z"
    revoked: false
    environments:
      - test
  - filename: live.pub
    comment: alice@live
    added_at: "2026-01-01T00:00:00Z"
    expires_at: "2099-01-01T00:00:00Z"
    revoked: false
    environments:
      - test
YAML

  git -C "$REPO" add .
  git -C "$REPO" commit -q -m "fixture"
  git -C "$REPO" push -q -u origin main
}

assert_metadata_filenames() {
  local expected="$1"
  local actual
  actual="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("keys").map { |key| key.fetch("filename") }.join(",")' "$REPO/meta/alice.yaml")"
  [[ "$actual" == "$expected" ]] ||
    fail "元数据文件名不匹配：期望 '$expected'，实际 '$actual'"
}

test_removes_metadata_when_public_key_is_missing() {
  setup_fixture
  trap 'rm -rf "$FIXTURE_ROOT"' RETURN

  (cd "$REPO" && PATH="$REPO/bin:$PATH" bash scripts/cleanup_expired.sh)

  assert_metadata_filenames "live.pub"
  [[ -f "$REPO/keys/alice/live.pub" ]] || fail "有效公钥不应被删除"
  [[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "清理提交后工作区应保持干净"
}

test_removes_expired_metadata_and_public_keys() {
  setup_fixture
  trap 'rm -rf "$FIXTURE_ROOT"' RETURN

  printf 'placeholder\n' > "$REPO/keys/alice/expired.pub"
  printf 'placeholder\n' > "$REPO/keys/alice/revoked-expired.pub"

  cat > "$REPO/meta/alice.yaml" <<'YAML'
user: alice
keys:
  - filename: expired.pub
    comment: alice@expired
    added_at: "2019-01-01T00:00:00Z"
    expires_at: "2020-01-01T00:00:00Z"
    revoked: false
    environments:
      - test
  - filename: revoked-expired.pub
    comment: alice@revoked-expired
    added_at: "2019-01-01T00:00:00Z"
    expires_at: "2020-01-01T00:00:00Z"
    revoked: true
    environments:
      - test
  - filename: live.pub
    comment: alice@live
    added_at: "2026-01-01T00:00:00Z"
    expires_at: "2099-01-01T00:00:00Z"
    revoked: false
    environments:
      - test
YAML

  git -C "$REPO" add .
  git -C "$REPO" commit -q -m "expired fixture"
  git -C "$REPO" push -q

  (cd "$REPO" && PATH="$REPO/bin:$PATH" bash scripts/cleanup_expired.sh)

  assert_metadata_filenames "live.pub"
  [[ ! -e "$REPO/keys/alice/expired.pub" ]] || fail "已过期公钥应被删除"
  [[ ! -e "$REPO/keys/alice/revoked-expired.pub" ]] || fail "已撤销且过期的公钥应被删除"
  [[ -f "$REPO/keys/alice/live.pub" ]] || fail "未过期公钥不应被删除"
  [[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "清理提交后工作区应保持干净"
}

test_removes_metadata_when_public_key_is_missing
test_removes_expired_metadata_and_public_keys
echo "✅ cleanup_expired tests passed"
