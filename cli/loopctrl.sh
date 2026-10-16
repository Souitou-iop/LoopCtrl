#!/bin/sh
# Entry point for the bundled LoopCtrl CLI.
#
# Run it as `sh loopctrl.sh`, which needs no exec bit itself. Two ways the binary
# next to it can still refuse to run, both seen in Minis:
#
#   - it arrived without the exec bit (the skill importer writes every file
#     0644 and never chmods) — fixed by chmod;
#   - it sits on a filesystem that ignores the exec bit altogether, such as
#     /var/minis/workspace: chmod "succeeds" and exec still fails with
#     "Permission denied", however often it is retried.
#
# For the second case the binary is copied to ~/.loopctrl/bin (next to the key in
# ~/.loopctrl/token.json, on an executable filesystem) and run from there. That is
# also the location the skill tells agents to install to, so later sessions find
# it instead of downloading another copy.
#
# Usage: sh loopctrl.sh [--host HOST:PORT] <command> [args...]
#        sh loopctrl.sh update [SKILL_DIR]   refresh the client (and SKILL.md in
#                                         SKILL_DIR) from the device

dir=$(cd "$(dirname "$0")" && pwd)
bin="$dir/loopctrl"
home_dir="${HOME:-/root}/.loopctrl/bin"

# update: pull the client and the skill from the device itself, so they always
# match the running build. Everything is written to a temp file and renamed into
# place — sh reads this script while running it, so overwriting it in place
# would corrupt the run doing the update.
if [ "$1" = "update" ]; then
    base="http://${LOOPCTRL_HOST:-127.0.0.1:8200}"
    fetch() { wget -qO "$2.new" "$base$1" && [ -s "$2.new" ] && mv "$2.new" "$2" || { rm -f "$2.new"; echo "loopctrl.sh: could not fetch $base$1" >&2; exit 1; }; }
    if [ -n "$2" ] && [ ! -d "$2" ]; then echo "loopctrl.sh: $2 is not a directory" >&2; exit 1; fi
    mkdir -p "$home_dir" || exit 1
    fetch /skill/clients/cli "$home_dir/loopctrl"
    fetch /skill/clients/cli.sh "$home_dir/loopctrl.sh"
    chmod +x "$home_dir/loopctrl" 2>/dev/null
    echo "updated client in $home_dir"
    if [ -n "$2" ]; then
        fetch /skill "$2/SKILL.md"
        [ -f "$2/loopctrl" ] && cp "$home_dir/loopctrl" "$2/loopctrl"
        [ -f "$2/loopctrl.sh" ] && cp "$home_dir/loopctrl.sh" "$2/loopctrl.sh"
        echo "updated $2/SKILL.md to $(sed -n 's/^skill_version: *//p' "$2/SKILL.md" | tr -d '"') — re-read it now"
    fi
    exit 0
fi

if [ ! -f "$bin" ]; then
    echo "loopctrl.sh: $bin not found — download it: wget -qO $bin http://127.0.0.1:8200/skill/clients/cli" >&2
    exit 1
fi

[ -x "$bin" ] || chmod +x "$bin" 2>/dev/null || true

# Probe with a no-op command: an unknown subcommand prints usage and exits 2
# without touching the network. 126/127 mean the kernel refused to run it.
runs() {
    "$1" __probe >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 126 ] && [ "$rc" -ne 127 ]
}

if runs "$bin"; then
    exec "$bin" "$@"
fi

mkdir -p "$home_dir" || exit 1
cmp -s "$bin" "$home_dir/loopctrl" 2>/dev/null || cp "$bin" "$home_dir/loopctrl" || exit 1
chmod +x "$home_dir/loopctrl"
[ "$dir" = "$home_dir" ] || cp "$0" "$home_dir/loopctrl.sh" 2>/dev/null
if ! runs "$home_dir/loopctrl"; then
    echo "loopctrl.sh: cannot execute $home_dir/loopctrl either — is HOME on a noexec filesystem?" >&2
    exit 126
fi
echo "loopctrl.sh: binaries can't run from $dir (the filesystem ignores the exec bit);" \
     "using $home_dir/loopctrl — call sh $home_dir/loopctrl.sh from now on" >&2
exec "$home_dir/loopctrl" "$@"
