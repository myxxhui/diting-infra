#!/usr/bin/env bash
# 读取并校验 prod.disk_id（剥离 ANSI、拒绝 terraform 警告污染）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=terraform-output-safe.sh
source "$SCRIPT_DIR/terraform-output-safe.sh"

DISK_FILE="${1:?用法: read-disk-id-safe.sh <disk_id_file>}"
read_disk_id_safe "$DISK_FILE"
