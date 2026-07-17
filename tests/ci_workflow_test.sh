#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$PROJECT_ROOT/.github/workflows/ci.yml"
YQ="$PROJECT_ROOT/tests/helpers/yq"

fail() {
  echo "❌ $*" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local description="$3"
  [[ "$actual" == "$expected" ]] ||
    fail "${description}：期望 '$expected'，实际 '$actual'"
}

assert_contains() {
  local expected="$1"
  local actual="$2"
  local description="$3"
  [[ "$actual" == *"$expected"* ]] ||
    fail "${description}：未找到 '$expected'"
}

workflow_value() {
  "$YQ" e "$1" "$WORKFLOW"
}

test_manual_cleanup_does_not_run_regular_validate_or_deploy() {
  assert_equal \
    "github.event_name == 'push' || github.event_name == 'pull_request'" \
    "$(workflow_value '.jobs.validate.if')" \
    "validate 事件条件不正确"

  assert_equal \
    "github.event_name == 'push' && github.ref == 'refs/heads/main'" \
    "$(workflow_value '.jobs.deploy.if')" \
    "deploy 事件条件不正确"
}

test_cleanup_validates_and_deploys_only_after_a_change() {
  local cleanup_run
  cleanup_run="$(workflow_value '.jobs.cleanup.steps[] | select(.id == "cleanup") | .run')"

  assert_equal \
    "main" \
    "$(workflow_value '.jobs.cleanup.steps[] | select(.uses == "actions/checkout@v4") | .with.ref')" \
    "cleanup 必须 checkout main"

  assert_contains 'before="$(git rev-parse HEAD)"' "$cleanup_run" "cleanup 缺少变更前提交记录"
  assert_contains 'bash scripts/cleanup_expired.sh' "$cleanup_run" "cleanup 未运行清理脚本"
  assert_contains 'if [[ "$(git rev-parse HEAD)" != "$before" ]]; then' "$cleanup_run" "cleanup 未比较前后提交"
  assert_contains 'echo "changed=true" >> "$GITHUB_OUTPUT"' "$cleanup_run" "cleanup 未输出变更状态"

  assert_equal \
    "steps.cleanup.outputs.changed == 'true'" \
    "$(workflow_value '.jobs.cleanup.steps[] | select(.name == "Validate cleaned repository") | .if')" \
    "清理后校验条件不正确"

  assert_equal \
    "steps.cleanup.outputs.changed == 'true'" \
    "$(workflow_value '.jobs.cleanup.steps[] | select(.name == "Regenerate authorized_keys") | .if')" \
    "清理后部署条件不正确"
}

test_main_writers_are_serialized() {
  assert_equal \
    "ssh-keys-main-writer" \
    "$(workflow_value '.jobs.deploy.concurrency.group')" \
    "deploy 写入锁不正确"

  assert_equal \
    "ssh-keys-main-writer" \
    "$(workflow_value '.jobs.cleanup.concurrency.group')" \
    "cleanup 写入锁不正确"

  assert_equal \
    "false" \
    "$(workflow_value '.jobs.deploy.concurrency.cancel-in-progress')" \
    "deploy 不应取消正在进行的写入"

  assert_equal \
    "false" \
    "$(workflow_value '.jobs.cleanup.concurrency.cancel-in-progress')" \
    "cleanup 不应取消正在进行的写入"
}

test_manual_cleanup_does_not_run_regular_validate_or_deploy
test_cleanup_validates_and_deploys_only_after_a_change
test_main_writers_are_serialized
echo "✅ ci workflow tests passed"
