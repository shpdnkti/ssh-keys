#!/usr/bin/env bash
# -------------------------------------------------
# 自动标记过期密钥为 revoked 并提交 PR
# -------------------------------------------------
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ISO8601='%Y-%m-%dT%H:%M:%SZ'
NOW_UTC=$(date -u +"$ISO8601")

# 设置 Git 用户信息（GitHub Actions 需要）
git config user.email "actions@github.com"
git config user.name "GitHub Actions"

# 辅助函数
list_environments() { yq e '.environments[]' "$REPO_ROOT/envs.yaml"; }

# 创建新分支
BRANCH="auto-revoke-$(date -u +%Y%m%d%H%M%S)"
git checkout -b "$BRANCH"

# 主逻辑
declare -a revoked_keys
for env in $(list_environments); do
  echo "🧹 清理环境: $env"
  META_DIR="$REPO_ROOT/meta/$env"

  for meta_file in "$META_DIR"/*.yaml; do
    [[ -f "$meta_file" ]] || continue
    user=$(yq e '.user' "$meta_file")
    
    # 使用 yq 直接修改文件（原地更新）
    yq e -i "with(.keys[]; 
      select(.revoked != true and .expires_at != null and 
      now > (fromdate(.expires_at))) | 
      .revoked = true | .revoked_at = \"$NOW_UTC\")" "$meta_file"
    
    # 收集被吊销的密钥
    while IFS= read -r key; do
      revoked_keys+=("$env/$user: $(jq -r '.filename' <<< "$key")")
    done < <(yq e '.keys[] | select(.revoked == true)' "$meta_file" -o json | jq -c .)
  done
done

# 提交变更
if git diff --quiet; then
  echo "✅ 无过期密钥"
  exit 0
else
  git add meta/
  git commit -m "CI: Auto-revoke expired keys"
  git push origin "$BRANCH"

  # 生成 PR 描述
  PR_BODY=$(
    echo "以下密钥因过期被自动吊销:"
    printf -- "- %s\n" "${revoked_keys[@]}"
    echo "请检查后合并。"
  )

  # 创建 PR（GitHub CLI）
  gh pr create \
    --title "自动吊销过期密钥 ($(date -u +%Y-%m-%d))" \
    --body "$PR_BODY" \
    --base main \
    --head "$BRANCH" \
    --label "automation,security"

  echo "✅ 已提交吊销 PR"
fi