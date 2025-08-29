#!/usr/bin/env bash
# -------------------------------------------------
# 自动标记过期密钥为 revoked 并提交 PR
# -------------------------------------------------

[[ "$IS_TRACE" == "true" ]] && set -x
set -euo pipefail

# ------------------- 环境变量 -------------------
REPO_ROOT="$(git rev-parse --show-toplevel)"
ISO8601='%Y-%m-%dT%H:%M:%SZ'

# 当前 UTC 时间（ISO8601）以及 epoch 秒数，后者用于比较
NOW_UTC=$(date -u +"$ISO8601")
NOW_EPOCH=$(date -u +%s)

# GitHub Actions 必须的用户信息
git config user.email "actions@github.com"
git config user.name "GitHub Actions"

# ------------------- 辅助函数 -------------------
list_environments() { yq e '.environments[]' "$REPO_ROOT/envs.yaml"; }

# ------------------- 创建分支 -------------------
BRANCH=main
# BRANCH="auto-revoke-$(date -u +%Y%m%d%H%M%S)"
# git checkout -b "$BRANCH"

# ------------------- 主逻辑 -------------------
declare -a revoked_keys   # 用于 PR body

for env in $(list_environments); do
  echo "🧹 清理环境: $env"
  META_DIR="$REPO_ROOT/meta/$env"

  for meta_file in "$META_DIR"/*.yaml; do
    [[ -f "$meta_file" ]] || continue
    user=$(yq e '.user' "$meta_file")
    
    # 获取密钥数量
    key_count=$(yq e '.keys | length' "$meta_file")
    
    # 遍历所有密钥
    for ((i=0; i<key_count; i++)); do
      # 检查密钥是否已撤销或没有过期时间
      revoked=$(yq e ".keys[$i].revoked" "$meta_file")
      expires_at=$(yq e ".keys[$i].expires_at" "$meta_file")
      
      # 跳过已撤销或没有过期时间的密钥
      [[ "$revoked" == "true" || -z "$expires_at" || "$expires_at" == "null" ]] && continue
      
      # 获取文件名
      filename=$(yq e ".keys[$i].filename" "$meta_file")
      
      # 把 ISO8601 转成 epoch 秒
      expires_epoch=$(date -u -d "$expires_at" +%s 2>/dev/null || echo 0)
      
      # 如果解析失败（返回 0）直接跳过
      (( expires_epoch == 0 )) && continue
      
      # 已过期 → 需要撤销
      if (( expires_epoch <= NOW_EPOCH )); then
        # 用 yq 原地修改对应下标的键
        yq e -i "
          .keys[$i].revoked = true |
          .keys[$i].revoked_at = \"$NOW_UTC\"
        " "$meta_file"
        
        # 记录到数组，供后面 PR Body 使用
        revoked_keys+=("$env/$user: $filename")
      fi
    done
  done
done

# ------------------- 提交 & PR -------------------
if git diff --quiet; then
  echo "✅ 无过期密钥需要撤销"
  exit 0
else
  git add meta/
  git commit -m "CI: Auto-revoke expired keys \n$(printf -- "- %s\n" "${revoked_keys[@]}")"
  git push origin "$BRANCH"

  # # 生成 PR 描述
  # PR_BODY=$(
  #   echo "以下密钥因过期被自动吊销:"
  #   printf -- "- %s\n" "${revoked_keys[@]}"
  #   echo -e "\n请检查后合并。"
  # )

  # # 创建 PR（GitHub CLI）
  # gh pr create \
  #   --title "自动吊销过期密钥 ($(date -u +%Y-%m-%d))" \
  #   --body "$PR_BODY" \
  #   --base main \
  #   --head "$BRANCH" \
  #   --label "auto‑merge"

  # echo "✅ 已提交吊销 PR"
fi