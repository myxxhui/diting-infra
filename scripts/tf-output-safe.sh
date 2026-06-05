#!/usr/bin/env bash
# 安全执行 terraform output -raw（禁用颜色 + 校验）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=terraform-output-safe.sh
source "$SCRIPT_DIR/terraform-output-safe.sh"

OUTPUT_NAME="${1:?用法: tf-output-safe.sh <output_name> [tf_dir]}"
TF_DIR="${2:-$(cd "$SCRIPT_DIR/../deploy-engine/deploy/terraform/alicloud" && pwd)}"
tf_output_raw_safe "$TF_DIR" "$OUTPUT_NAME"
