#!/bin/sh
# Render loopctrl-relay.service from the template next to this script.
#
#   BINARY=/usr/local/bin/loopctrl-relay ENV_FILE=/etc/loopctrl-relay/relay.env \
#   STATE_DIR=/var/lib/loopctrl-relay connect/relay/systemd/render-unit.sh > /etc/systemd/system/loopctrl-relay.service
#
# Variables (defaults in brackets):
#   BINARY     the relay, built with `go build` in connect/relay  [/usr/local/bin/loopctrl-relay]
#   ENV_FILE   relay.env with the operator token                  [/etc/loopctrl-relay/relay.env]
#   STATE_DIR  directory holding state.json (written in place)    [/var/lib/loopctrl-relay]
#   LISTEN     listen address                                     [127.0.0.1:8787]
#   USER_NAME  service user; must own STATE_DIR                   [root]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
BINARY=${BINARY:-/usr/local/bin/loopctrl-relay}
ENV_FILE=${ENV_FILE:-/etc/loopctrl-relay/relay.env}
STATE_DIR=${STATE_DIR:-/var/lib/loopctrl-relay}
LISTEN=${LISTEN:-127.0.0.1:8787}
USER=${USER_NAME:-root}

[ -x "$BINARY" ] || { echo "render-unit.sh: $BINARY is not an executable" >&2; exit 1; }

sed -e "s|@BINARY@|$BINARY|g" -e "s|@ENV_FILE@|$ENV_FILE|g" \
    -e "s|@STATE_DIR@|$STATE_DIR|g" -e "s|@LISTEN@|$LISTEN|g" -e "s|@USER@|$USER|g" \
    "$here/loopctrl-relay.service.in"
