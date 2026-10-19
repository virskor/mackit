#!/bin/bash
# Install the repository's git hooks into .git/hooks/.
#
# .git/hooks is not versioned with the repository, so re-run this script once
# after cloning to another machine.
# Currently only pre-commit is installed: it scans the staged area before a
# commit to block PEM private key material (.gitignore cannot stop git add -f;
# see the comments in Scripts/git-hooks/pre-commit).
#
# Usage: Scripts/install-git-hooks.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_SRC="$ROOT/Scripts/git-hooks"
HOOKS_DST="$ROOT/.git/hooks"

if [ ! -d "$HOOKS_DST" ]; then
    echo "找不到 $HOOKS_DST，当前目录不是 git 仓库？" >&2
    exit 1
fi

for hook in "$HOOKS_SRC"/*; do
    [ -f "$hook" ] || continue
    name="$(basename "$hook")"
    install -m 755 "$hook" "$HOOKS_DST/$name"
    echo "已安装 $name"
done

echo "完成。"
