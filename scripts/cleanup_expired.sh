#!/usr/bin/env bash
# -------------------------------------------------
# 生成 authorized_keys 并提交（仅在 main / master 分支）
# -------------------------------------------------
[[ "$IS_TRACE" == "true" ]] && set -x

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
KEYS_DIR="${REPO_ROOT}/keys"
META_DIR="${REPO_ROOT}/meta"
OUTPUT_FILE="${REPO_ROOT}/authorized_keys"

ISO8601='%Y-%m-%dT%H:%M:%SZ'
NOW_UTC=$(date -u +"$ISO8601")

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
{
    echo "# === AUTO‑GENERATED authorized_keys ==="
    echo "# 生成时间: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    for l in "${lines[@]}"; do
        echo "$l"
    done
} > "$OUTPUT_FILE"

# 判断是否真的有改动
if git diff --quiet "$OUTPUT_FILE"; then
    echo "✅ authorized_keys 未改变，跳过提交"
else
    git add "$OUTPUT_FILE"
    git commit -m "CI: Update authorized_keys (generated $(date -u +"%Y-%m-%d"))"
    git push origin HEAD
    echo "✅ authorized_keys 已更新并提交"
fi
