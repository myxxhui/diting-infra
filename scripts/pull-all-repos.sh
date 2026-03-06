#!/bin/bash
# 一键拉取当前目录下所有 Git 仓库的脚本
# 使用前请设置: export GITHUB_TOKEN='你的token' 或在脚本同目录创建 .github_token（第一行写 token）

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_USER="${GITHUB_USER:-myxxhui}"
# Token 仅从环境变量或 .github_token 读取，不写死在脚本中
if [ -n "$GITHUB_TOKEN" ]; then
  :
elif [ -f "$SCRIPT_DIR/.github_token" ]; then
  GITHUB_TOKEN=$(cat "$SCRIPT_DIR/.github_token" | head -1 | tr -d '\r\n')
else
  echo "错误: 请设置 export GITHUB_TOKEN='你的token' 或在 $SCRIPT_DIR 创建 .github_token"
  exit 1
fi
cd "$SCRIPT_DIR"

echo "=========================================="
echo "一键拉取目录下所有 Git 仓库"
echo "工作目录: $SCRIPT_DIR"
echo "=========================================="

success_count=0
fail_count=0
skip_count=0

for dir in */; do
  [ -d "$dir" ] || continue
  dir_path="${SCRIPT_DIR}/${dir%/}"
  if [ -d "${dir_path}/.git" ]; then
    echo ""
    echo ">>> 正在处理: $dir"
    (
      cd "$dir_path"
      remote_url=$(git remote get-url origin 2>/dev/null || true)
      if [ -z "$remote_url" ]; then
        echo "    跳过（无 origin 远程）"
        exit 2
      fi
      # 构建带 token 的 HTTPS URL（支持 github.com）
      if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)? ]]; then
        owner="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
        auth_url="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${owner}/${repo}.git"
        git pull "$auth_url" 2>&1 && echo "    完成" || { echo "    拉取失败"; exit 1; }
      else
        git pull 2>&1 && echo "    完成" || { echo "    拉取失败"; exit 1; }
      fi
    )
    ret=$?
    if [ $ret -eq 0 ]; then
      ((success_count++)) || true
    elif [ $ret -eq 2 ]; then
      ((skip_count++)) || true
    else
      ((fail_count++)) || true
    fi
  fi
done

# 若当前目录本身是 git 仓库，也拉取
if [ -d "${SCRIPT_DIR}/.git" ]; then
  echo ""
  echo ">>> 正在处理: 当前目录 (.)"
  (
    cd "$SCRIPT_DIR"
    remote_url=$(git remote get-url origin 2>/dev/null || true)
    if [ -n "$remote_url" ] && [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)? ]]; then
      owner="${BASH_REMATCH[1]}"
      repo="${BASH_REMATCH[2]}"
      auth_url="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${owner}/${repo}.git"
      git pull "$auth_url" 2>&1 && echo "    完成" || { echo "    拉取失败"; exit 1; }
    else
      git pull 2>&1 && echo "    完成" || { echo "    拉取失败"; exit 1; }
    fi
  )
  [ $? -eq 0 ] && ((success_count++)) || ((fail_count++))
fi

echo ""
echo "=========================================="
echo "汇总: 成功 $success_count, 失败 $fail_count, 跳过 $skip_count"
echo "=========================================="
