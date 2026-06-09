#!/usr/bin/env bash
# 从 OSS remote state 或本地 prod.disk_id 解析数据盘 ID（换机部署时避免误建新盘）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=terraform-output-safe.sh
source "$SCRIPT_DIR/terraform-output-safe.sh"

TF_DIR="${1:?用法: resolve-disk-id-for-deploy.sh <terraform_dir> [disk_id_file]}"
DISK_FILE="${2:-}"

resolve_data_disk_id "$TF_DIR" "$DISK_FILE"
