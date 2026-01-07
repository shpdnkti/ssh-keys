#!/usr/bin/env bash
# -------------------------------------------------
# 生成 authorized_keys 并提交（仅在 main / master 分支）
# -------------------------------------------------

[[ "$IS_TRACE" == "true" ]] && set -x

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

ISO8601='%Y-%m-%dT%H:%M:%SZ'
NOW_UTC=$(date -u +"$ISO8601")

# 设置 Git 用户信息（GitHub Actions 需要）
git config user.email "actions@github.com"
git config user.name "GitHub Actions"

list_environments() {
  local yaml="${REPO_ROOT}/envs.yaml"
  # yq 会把数组打印成每行一个元素
  yq e '.environments[]' "$yaml"
}

for env in $(list_environments); do
    echo "🚀 正在生成 authorized_keys for 环境: $env"

    KEYS_DIR="${REPO_ROOT}/keys"
    META_DIR="${REPO_ROOT}/meta"
    OUTPUT_FILE="${REPO_ROOT}/authorized_keys/${env}"

    declare -a lines   # 用来收集最终的 key 行

    # 遍历所有 meta 文件
    for meta_file in "${META_DIR}"/*.yaml; do
        [[ -f "$meta_file" ]] || continue
        user=$(yq e '.user' "$meta_file")
        key_count=$(yq e '.keys | length' "$meta_file")
        for i in $(seq 0 $((key_count-1))); do
            filename=$(yq e ".keys[$i].filename" "$meta_file")
            revoked=$(yq e ".keys[$i].revoked" "$meta_file")
            expires_at=$(yq e ".keys[$i].expires_at" "$meta_file")
            # 检查是否允许访问当前环境
            if ! yq e ".keys[$i].environments[] | select(. == \"$env\" or . == \"all\")" "$meta_file" | grep -q .; then continue; fi
            # 跳过已吊销
            if [[ "$revoked" == "true" ]]; then continue; fi
            # 跳过已过期
            if [[ -n "$expires_at" && "$expires_at" != "null" ]]; then
                expires_epoch=$(date -d "$expires_at" +%s)
                now_epoch=$(date -d "$NOW_UTC" +%s)
                if (( now_epoch > expires_epoch )); then continue; fi
            fi

            key_path="${KEYS_DIR}/${user}/${filename}"
            [[ -f "$key_path" ]] || { echo "⚠️  $key_path 不存在，跳过" >&2; continue; }

            # 读取原始 key 行，追加统一 comment 便于后期审计
            raw=$(cat "$key_path")
            # 统一 comment形式：<user>:<filename>
            comment="${user}:${filename}"
            # 如果原始行已有 comment，保留后面追加
            if [[ "$raw" =~ ^([^[:space:]]+[[:space:]]+[^[:space:]]+)([[:space:]]+.*)?$ ]]; then
                key_body="${BASH_REMATCH[1]}"
                lines+=("${key_body} ${comment}")
            else
                # 极端情况，直接使用原始内容 + comment
                lines+=("${raw} ${comment}")
            fi
        done
    done

    # 写入文件（如果内容没有变化则不提交）
    if [ ! -f $OUTPUT_FILE ]; then
        mkdir -p "$(dirname "$OUTPUT_FILE")"
        touch "$OUTPUT_FILE"
    fi
    {
        echo "# === AUTO‑GENERATED authorized_keys for ${env} ==="
        echo "# 生成时间: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        for l in "${lines[@]}"; do echo "$l"; done
    } > "$OUTPUT_FILE"


    # 判断文件是否在 Git 中已跟踪
    if git ls-files --error-unmatch "$OUTPUT_FILE" >/dev/null 2>&1; then
        # 文件已跟踪，检查是否有修改
        if git diff --quiet "$OUTPUT_FILE"; then
            echo "✅ authorized_keys for $env 未改变，跳过提交"
            continue
        fi
    else
        # 文件未跟踪，视为有改动
        echo "🆕 检测到新文件 $OUTPUT_FILE"
    fi

    # 执行提交操作
    git add "$OUTPUT_FILE"
    git commit -m "CI: Update authorized_keys for $env (generated $(date -u +"%Y-%m-%d"))"
    git push origin HEAD
    echo "✅ authorized_keys for $env 已更新并提交"
    unset lines
done
