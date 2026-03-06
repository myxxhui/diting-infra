#!/usr/bin/env bash
# 将所有本地 Git 仓库的修改 add、commit 并 push 到远程
# 使用前请设置: export GITHUB_TOKEN='你的token'
# 或在脚本工作根目录创建 .github_token 文件（第一行写 token，已加入 .gitignore）

set -e

# 脚本所在目录作为工作根目录（其下每个含 .git 的目录视为一个 repo）
ROOT="${1:-$(cd "$(dirname "$0")" && pwd)}"
COMMIT_MSG="${2:-"sync: auto commit and push"}"

# 从环境变量或 .github_token 读取 token（不写入脚本以保证安全且可通过 GitHub 推送）
if [ -n "$GITHUB_TOKEN" ]; then
  TOKEN="$GITHUB_TOKEN"
elif [ -f "$ROOT/.github_token" ]; then
  TOKEN=$(cat "$ROOT/.github_token" | head -1 | tr -d '\r\n')
else
  echo "错误: 未设置 GITHUB_TOKEN 环境变量，且不存在 $ROOT/.github_token"
  echo "请执行: export GITHUB_TOKEN='你的github_pat_...'"
  echo "或在工作根目录创建 .github_token 文件，第一行写入 token"
  exit 1
fi

GITHUB_USER="${GITHUB_USER:-myxxhui}"
# 提交时使用的作者信息（未配置时用 GitHub 用户名，避免 "Author identity unknown" 导致 commit 失败）
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$GITHUB_USER}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-${GITHUB_USER}@users.noreply.github.com}"

# 查找所有包含 .git 的子目录（直接子目录或递归，这里只做直接子目录以匹配 lighthouse-*）
find "$ROOT" -maxdepth 2 -type d -name '.git' 2>/dev/null | while read -r g; do
  REPO_DIR="$(cd "$(dirname "$g")" && pwd)"
  # 跳过工作根目录本身的 .git（若存在）
  [ "$REPO_DIR" = "$ROOT" ] && [ -d "$ROOT/.git" ] && continue
  echo "========== $REPO_DIR =========="
  ( cd "$REPO_DIR" || exit 1
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "  跳过: 不是有效 Git 工作区"
      exit 0
    fi
    # 本仓库内若无 user.name/user.email，用环境变量保证能提交（不写 --global）
    if ! git config user.name >/dev/null 2>&1; then
      git config user.name "$GIT_AUTHOR_NAME"
    fi
    if ! git config user.email >/dev/null 2>&1; then
      git config user.email "$GIT_AUTHOR_EMAIL"
    fi
    git add -A
    if git diff --staged --quiet 2>/dev/null; then
      echo "  无修改，跳过提交与推送"
      exit 0
    fi
    git commit -m "$COMMIT_MSG" || { echo "  提交失败（见上）"; exit 1; }
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
    # 去掉 URL 中可能已有的认证，只保留 owner/repo 部分
    if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+/[^/]+) ]]; then
      REPO_PATH="${BASH_REMATCH[1]}"
      REPO_PATH="${REPO_PATH%.git}"
      AUTH_URL="https://${GITHUB_USER}:${TOKEN}@github.com/${REPO_PATH}.git"
      BRANCH=$(git branch --show-current 2>/dev/null || echo "HEAD")
      if ! git push "$AUTH_URL" "${BRANCH}:refs/heads/${BRANCH}"; then
        echo "  推送失败（见上）"
        exit 1
      fi
    else
      if ! git push; then
        echo "  推送失败（见上）"
        exit 1
      fi
    fi
    echo "  已提交并推送"
  ) || echo "  失败: $REPO_DIR"
done

echo "完成."
