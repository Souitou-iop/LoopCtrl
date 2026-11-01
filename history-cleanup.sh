#!/bin/bash
# One-off: scrub two things out of LoopCtrl's published history, then publish
# a fresh release. Delete this file afterwards; it is not meant to be committed.
#
#   1. Patches/altsign-xcode-version.patch — a patch of AltSign's code, which
#      has no license. Removed from every commit.
#   2. Every earlier version of OnDevicePairing.swift (the one that resembled
#      StikPair, which forbids commercial use). Each commit gets the current,
#      rewritten version instead.
#
# Nothing else changes: same 319 commits, same authors, dates and messages, and
# the latest tree is byte-for-byte what main has now (checked before pushing).
# A full mirror of the old history is kept at $BACKUP first, so this is
# reversible: git -C "$BACKUP" push --force <remote> main
set -euo pipefail

REPO=/Volumes/SanDisk/Projects/LoopCtrl
BACKUP=/Volumes/SanDisk/Projects/LoopCtrl-history-backup.git
REMOTE=https://github.com/Souitou-iop/LoopCtrl.git
WORK="$(mktemp -d)/LoopCtrl"

git -C "$REPO" fetch -q origin
OLD=$(git -C "$REPO" rev-parse origin/main)
[ "$(git -C "$REPO" rev-parse main)" = "$OLD" ] || { echo "❌ local main differs from origin/main; sync first"; exit 1; }

echo "📦 Backing up the full history to $BACKUP"
[ -e "$BACKUP" ] || git clone -q --mirror "$REPO" "$BACKUP"

echo "🧹 Rewriting a copy in $WORK"
git clone -q --no-local --single-branch --branch main --no-tags "$REPO" "$WORK"
cd "$WORK"
NEW=$(git hash-object -w LoopCtrlApp/DDI/OnDevicePairing.swift)
export NEW
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --index-filter '
  git rm -q --cached --ignore-unmatch Patches/altsign-xcode-version.patch
  for p in iCTRLApp/DDI/OnDevicePairing.swift LoopCtrlApp/DDI/OnDevicePairing.swift; do
    if git ls-files --error-unmatch "$p" >/dev/null 2>&1; then
      git update-index --cacheinfo 100644,"$NEW","$p"
    fi
  done' -- main >/dev/null

echo "🔎 Checking"
[ "$(git rev-parse "$OLD^{tree}")" = "$(git rev-parse "main^{tree}")" ] || { echo "❌ latest tree changed"; exit 1; }
[ "$(git rev-list --count "$OLD")" = "$(git rev-list --count main)" ] || { echo "❌ commit count changed"; exit 1; }
[ -z "$(git log --oneline main -- Patches/altsign-xcode-version.patch)" ] || { echo "❌ AltSign patch still present"; exit 1; }
for c in $(git rev-list main); do
  git ls-tree "$c" iCTRLApp/DDI/OnDevicePairing.swift LoopCtrlApp/DDI/OnDevicePairing.swift
done | awk '{print $3}' | sort -u | grep -qvx "$NEW" && { echo "❌ an old OnDevicePairing.swift remains"; exit 1; }
echo "   ✅ same tree, same commit count, nothing left of either file"

echo "🚀 Pushing (refused if origin/main moved since $OLD)"
git push --force-with-lease="main:$OLD" "$REMOTE" main

echo "🔁 Pointing the local checkout at the new history (working-tree changes kept)"
cd "$REPO"
git fetch -q origin
git reset -q --soft origin/main
git status --short | head

echo "🏷  Publishing v0.3-beta (Release workflow builds and attaches LoopCtrl.ipa)"
gh workflow run release.yml -R Souitou-iop/LoopCtrl -f tag=v0.3-beta -f version=0.3.0 -f prerelease=true

echo "✅ Done. Backup: $BACKUP. Delete $REPO/history-cleanup.sh when you're happy."
