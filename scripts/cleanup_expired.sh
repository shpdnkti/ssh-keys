#!/usr/bin/env bash
# -------------------------------------------------
# 自动清理无公钥文件或已过期的密钥元数据并提交
# -------------------------------------------------

[[ "$IS_TRACE" == "true" ]] && set -x
set -euo pipefail

# ------------------- 环境变量 -------------------
REPO_ROOT="$(git rev-parse --show-toplevel)"
ISO8601='%Y-%m-%dT%H:%M:%SZ'

# 优先使用工程 bin 目录下的 yq
if [[ -x "${REPO_ROOT}/bin/yq" ]]; then
  YQ="${REPO_ROOT}/bin/yq"
else
  YQ="yq"
fi

# 当前 UTC 时间（ISO8601）以及 epoch 秒数，后者用于比较
NOW_UTC=$(date -u +"$ISO8601")
NOW_EPOCH=$(date -u +%s)

# GitHub Actions 必须的用户信息
git config user.email "actions@github.com"
git config user.name "GitHub Actions"

# ------------------- 辅助函数 -------------------
list_environments() { $YQ e '.environments[]' "$REPO_ROOT/envs.yaml"; }

# ------------------- 创建分支 -------------------
BRANCH=main
# BRANCH="auto-revoke-$(date -u +%Y%m%d%H%M%S)"
# git checkout -b "$BRANCH"

# ------------------- 主逻辑 -------------------
declare -a cleaned_keys

META_DIR="$REPO_ROOT/meta"

for meta_file in "$META_DIR"/*.yaml; do
    [[ -f "$meta_file" ]] || continue
    user=$($YQ e '.user' "$meta_file")
    
    # 获取密钥数量
    key_count=$($YQ e '.keys | length' "$meta_file")
    
    # 倒序遍历，删除数组元素时不会影响尚未处理的下标
    for ((i=key_count-1; i>=0; i--)); do
      filename=$($YQ e ".keys[$i].filename" "$meta_file")
      key_path="$REPO_ROOT/keys/$user/$filename"

      # 元数据引用的公钥不存在时，直接删除该条元数据
      if [[ ! -f "$key_path" ]]; then
        $YQ e -i "del(.keys[$i])" "$meta_file"
        cleaned_keys+=("$user: $filename (missing public key)")
        continue
      fi

      # 没有过期时间的密钥不做处理
      expires_at=$($YQ e ".keys[$i].expires_at" "$meta_file")
      [[ -z "$expires_at" || "$expires_at" == "null" ]] && continue
      
      # 把 ISO8601 转成 epoch 秒
      expires_epoch=$(date -u -d "$expires_at" +%s 2>/dev/null || echo 0)
      
      # 如果解析失败（返回 0）直接跳过
      (( expires_epoch == 0 )) && continue
      
      # 已过期：删除元数据以及对应公钥文件
      if (( expires_epoch <= NOW_EPOCH )); then
        $YQ e -i "del(.keys[$i])" "$meta_file"
        rm -f -- "$key_path"
        cleaned_keys+=("$user: $filename (expired)")
      fi
    done
  done

# ------------------- 提交 & PR -------------------
if git diff --quiet; then
  echo "✅ 无缺失公钥或过期元数据需要清理"
  exit 0
else
  git add -A -- meta/ keys/
  git commit -m "CI: Cleanup invalid SSH key metadata \n$(printf -- "- %s\n" "${cleaned_keys[@]}")"
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
