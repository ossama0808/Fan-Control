#!/bin/bash
# Installs the privileged fan-write helper. Run with sudo.
#
# The helper is setuid root because writing an SMC key requires root and
# nothing else in this app does. Its argument parser accepts only a fan index
# and an RPM value, so it cannot write arbitrary SMC keys even if invoked
# directly by another local process.
set -euo pipefail

DEST="/usr/local/libexec/fancontrol-smcwrite"

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer must run as root:  sudo $0" >&2
    exit 1
fi

# Locate the helper: next to this script (app bundle) or in ./dist (repo).
HERE="$(cd "$(dirname "$0")" && pwd)"
for candidate in "$HERE/smcwrite" "$HERE/dist/smcwrite" "$HERE/../Resources/smcwrite"; do
    if [ -f "$candidate" ]; then SRC="$candidate"; break; fi
done
if [ -z "${SRC:-}" ]; then
    echo "Cannot find the smcwrite binary next to this script. Run ./build.sh first." >&2
    exit 1
fi

install -d -o root -g wheel -m 755 /usr/local/libexec
install -o root -g wheel -m 4755 "$SRC" "$DEST"

echo "Installed $DEST"
ls -l "$DEST"
echo
"$DEST" status
