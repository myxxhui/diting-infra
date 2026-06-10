#!/usr/bin/env bash
# 安全读取 terraform output：禁用颜色、剥离 ANSI、校验格式，避免警告框写入 prod.conn / prod.disk_id
# 用法: source scripts/terraform-output-safe.sh

_strip_ansi() {
  printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\r'
}

_is_valid_public_ip() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

_is_valid_disk_id() {
  [[ "$1" =~ ^d-[a-z0-9]+$ ]]
}

_is_terraform_garbage() {
  local val="$1"
  [ -z "$val" ] && return 0
  case "$val" in
    *Warning:*|*"No outputs found"*|*"Please define an output"*|*"terraform console"*) return 0 ;;
  esac
  # terraform 彩色警告框常见前缀（UTF-8 U+2577）
  case "$(printf '%s' "$val" | head -c 3)" in
    $'\xe2\x95\xb7'|$'\xe2\x94\x82'|$'\xe2\x95\xb5') return 0 ;;
  esac
  return 1
}

sanitize_tf_value() {
  local val
  val="$(_strip_ansi "$1")"
  _is_terraform_garbage "$val" && val=""
  printf '%s' "$val"
}

tf_output_raw_safe() {
  local tf_dir="$1" output_name="$2"
  local val
  [ -d "$tf_dir" ] || return 0
  val=$(cd "$tf_dir" && TF_IN_AUTOMATION=1 terraform output -no-color -raw "$output_name" 2>/dev/null || true)
  sanitize_tf_value "$val"
}

read_disk_id_safe() {
  local disk_file="$1"
  local val
  [ -f "$disk_file" ] || return 1
  val=$(sanitize_tf_value "$(cat "$disk_file")")
  _is_valid_disk_id "$val" || return 1
  printf '%s' "$val"
}

public_ip_from_deploy_state() {
  local state_file="$1"
  [ -f "$state_file" ] || return 1
  command -v python3 &>/dev/null || return 1
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
ip = d.get('cluster_ctx', {}).get('PublicIP', '')
if ip:
    print(ip)
" "$state_file" 2>/dev/null
}

public_ip_from_kubeconfig() {
  local kubeconfig="$1"
  local server
  [ -f "$kubeconfig" ] || return 1
  server=$(grep -E '^\s*server:' "$kubeconfig" 2>/dev/null | head -1 | sed -E 's/.*https?:\/\/([^:/]+).*/\1/')
  _is_valid_public_ip "$server" || return 1
  printf '%s' "$server"
}

resolve_public_ip() {
  local tf_dir="$1" engine_root="$2" project="$3" env="$4"
  local val kubeconfig state_file

  val=$(tf_output_raw_safe "$tf_dir" public_ip)
  _is_valid_public_ip "$val" && { printf '%s' "$val"; return 0; }

  state_file="${engine_root}/deploy-engine/.deploy/state-${project}-${env}.json"
  val=$(public_ip_from_deploy_state "$state_file")
  _is_valid_public_ip "$val" && { printf '%s' "$val"; return 0; }

  kubeconfig="${HOME}/.kube/config-${project}-${env}"
  val=$(public_ip_from_kubeconfig "$kubeconfig")
  _is_valid_public_ip "$val" && { printf '%s' "$val"; return 0; }

  return 1
}

resolve_data_disk_id() {
  local tf_dir="$1" disk_file="$2"
  local val alt_file

  val=$(tf_output_raw_safe "$tf_dir" data_disk_id)
  _is_valid_disk_id "$val" && { printf '%s' "$val"; return 0; }

  val=$(read_disk_id_safe "$disk_file" || true)
  _is_valid_disk_id "$val" && { printf '%s' "$val"; return 0; }

  alt_file="${disk_file}.new-disk-managed-by-tf"
  val=$(read_disk_id_safe "$alt_file" || true)
  _is_valid_disk_id "$val" && { printf '%s' "$val"; return 0; }

  return 1
}

# ── CLI（合并原 read-disk-id-safe / resolve-disk-id-for-deploy / tf-output-safe）──
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _TF_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../deploy-engine/deploy/terraform/alicloud" && pwd)"
  case "${1:-}" in
    read-disk-id)
      read_disk_id_safe "${2:?用法: terraform-output-safe.sh read-disk-id <disk_id_file>}"
      ;;
    resolve-disk-id)
      resolve_data_disk_id "${2:?用法: terraform-output-safe.sh resolve-disk-id <tf_dir> [disk_file]}" "${3:-}"
      ;;
    output)
      tf_output_raw_safe "${3:-$_TF_DEFAULT}" "${2:?用法: terraform-output-safe.sh output <name> [tf_dir]}"
      ;;
    -h|--help)
      echo "用法:"
      echo "  source scripts/terraform-output-safe.sh   # 函数库"
      echo "  terraform-output-safe.sh read-disk-id <file>"
      echo "  terraform-output-safe.sh resolve-disk-id <tf_dir> [disk_file]"
      echo "  terraform-output-safe.sh output <name> [tf_dir]"
      ;;
    *)
      echo "未知子命令: ${1:-}" >&2
      exit 2
      ;;
  esac
fi
