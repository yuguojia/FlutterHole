#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" != "main" ]]; then
  echo "Error: expected branch 'main', got '$current_branch'." >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Error: working tree is dirty. Commit or stash changes first." >&2
  exit 1
fi

remote_url="$(git remote get-url origin 2>/dev/null || true)"
repo_name="$(basename "${remote_url%.git}")"
base_href="${BASE_HREF:-/}"
if [[ -z "${BASE_HREF:-}" ]]; then
  if [[ "$repo_name" == *.github.io ]]; then
    base_href="/"
  elif [[ -n "$repo_name" ]]; then
    base_href="/$repo_name/"
  fi
fi

echo "Building Flutter web with base-href: $base_href"
flutter build web --release --base-href "$base_href"

worktree_dir="$(mktemp -d)"
cleanup() {
  git worktree remove "$worktree_dir" >/dev/null 2>&1 || true
  rm -rf "$worktree_dir"
}
trap cleanup EXIT

git worktree add "$worktree_dir" -B gh-pages >/dev/null

if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --exclude .git build/web/ "$worktree_dir/"
else
  rm -rf "$worktree_dir"/*
  cp -a build/web/. "$worktree_dir/"
fi

git -C "$worktree_dir" add -A
commit_msg="Deploy Flutter web build $(date +%Y-%m-%d)"
git -C "$worktree_dir" commit -m "$commit_msg" >/dev/null
git -C "$worktree_dir" push origin gh-pages

echo "Done. gh-pages updated."
