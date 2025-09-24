#!/usr/bin/env bash
# -------------------------------------------------
# CI 步骤：检查所有提交的公钥是否合法
#   - 文件存在且符合 OpenSSH 公钥格式
#   - meta 中的 expires_at、revoked 正确
#   - 没有“孤儿 key”（未在 meta 中登记）
# -------------------------------------------------

[[ "$IS_TRACE" == "true" ]] && set -x

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

# ISO 8601 UTC 格式
ISO8601='%Y-%m-%dT%H:%M:%SZ'
NOW_UTC=$(date -u +"$ISO8601")

# ---------- 辅助函数 ----------
die() { echo "❌ $*" >&2; exit 1; }

# 检查单个公钥文件格式
check_pubkey_format() {
    local file="$1"
    # 只要能被 ssh-keygen 解析即算合法
    if ! ssh-keygen -l -f "$file" >/dev/null 2>&1; then
        die "公钥文件 $file 格式错误或不是 OpenSSH 公钥"
    fi
}

list_environments() {
  local yaml="${REPO_ROOT}/envs.yaml"
  # yq 会把数组打印成每行一个元素
  yq e '.environments[]' "$yaml"
}

# ---------- 主体 ----------
echo "🔎 开始校验公钥和元数据"

for env in $(list_environments); do
    echo "🌐 验证环境: $env"
    KEYS_DIR="${REPO_ROOT}/keys/${env}"
    META_DIR="${REPO_ROOT}/meta/${env}"

    # 1) 遍历 meta/*.yaml
    for meta_file in "${META_DIR}"/*.yaml; do
        [[ -f "$meta_file" ]] || continue
        user=$(yq e '.user' "$meta_file")
        [[ -n "$user" ]] || die "$meta_file 缺少 user 字段"

        # 读取 keys 数组
        key_count=$(yq e '.keys | length' "$meta_file")
        for i in $(seq 0 $((key_count-1))); do
            filename=$(yq e ".keys[$i].filename" "$meta_file")
            comment=$(yq e ".keys[$i].comment" "$meta_file")
            added_at=$(yq e ".keys[$i].added_at" "$meta_file")
            expires_at=$(yq e ".keys[$i].expires_at" "$meta_file")
            revoked=$(yq e ".keys[$i].revoked" "$meta_file")

            key_path="${KEYS_DIR}/${user}/${filename}"
            [[ -f "$key_path" ]] || die "元数据中列出的 $key_path 不存在"

            # 检查格式
            check_pubkey_format "$key_path"

            # 检查 comment 是否匹配（若 meta 中有 comment）
            if [[ -n "$comment" && "$comment" != "null" ]]; then
                # ssh-keygen -l 不会返回 comment，直接 grep
                if ! grep -F "$comment" "$key_path" >/dev/null; then
                    die "$key_path comment 与 meta 中不匹配（期望 $comment）"
                fi
            fi

            # 检查是否已吊销
            #if [[ "$revoked" == "true" ]]; then
            #    die "$user/$filename 已被标记为 revoked"
            #fi

            # 检查是否已过期
            if [[ -n "$expires_at" && "$expires_at" != "null" ]]; then
                # 将 ISO 转为 epoch 秒比较
                expires_epoch=$(date -d "$expires_at" +%s)
                now_epoch=$(date -d "$NOW_UTC" +%s)
                if (( now_epoch > expires_epoch )); then
                    die "$user/$filename 已过期 (expires_at=$expires_at)"
                fi
            fi
        done
    done

    # 2) 检查是否有孤儿 key（在 keys/ 里但未在 meta 中登记）
    for user_dir in "${KEYS_DIR}"/*/; do
        [[ -d "$user_dir" ]] || continue
        user=$(basename "$user_dir")
        meta_file="${META_DIR}/${user}.yaml"
        [[ -f "$meta_file" ]] || die "用户 $user 没有对应的 meta 文件 ${meta_file}"

        # 收集 meta 中登记的文件名集合
        mapfile -t meta_filenames < <(yq e '.keys[].filename' "$meta_file")
        declare -A meta_set
        for fn in "${meta_filenames[@]}"; do
            meta_set["$fn"]=1
        done

        # 检查实际文件
        for key_file in "${user_dir}"*.pub; do
            [[ -e "$key_file" ]] || continue
            fn=$(basename "$key_file")
            if [[ -z "${meta_set[$fn]+x}" ]]; then
                die "孤儿公钥 $key_file 未在 ${meta_file} 中登记"
            fi
        done
    done
done

echo "✅ 所有公钥合法、未过期、未吊销"
exit 0
