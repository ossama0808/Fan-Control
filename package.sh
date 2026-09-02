#!/bin/bash
# Builds a double-clickable installer: Fan-Control-<version>.pkg
#
# A .pkg rather than a .dmg because the app is only half the install. Changing a
# fan speed needs root, so a small setuid helper has to land in
# /usr/local/libexec with the right ownership — something a drag-to-Applications
# .dmg cannot do, and something a user should not have to do in a terminal.
# The installer runs as root, so it can.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-$(cat VERSION)}"
APP_NAME="Fan Control"
DIST="dist"
STAGE="$DIST/pkgroot"
SCRIPTS="$DIST/pkgscripts"
OUT="$DIST/Fan-Control-$VERSION.pkg"

echo "==> building $VERSION"
./build.sh --no-install >/dev/null

rm -rf "$STAGE" "$SCRIPTS"
mkdir -p "$STAGE/Applications" "$STAGE/usr/local/libexec" "$SCRIPTS"

# ditto rather than cp, with --noextattr/--norsrc, so no extended attributes
# ride along into the payload. (pkgbuild still emits its own ._ entries for the
# directories it creates; those carry directory metadata and are normal.)
ditto --noextattr --norsrc "$DIST/$APP_NAME.app" "$STAGE/Applications/$APP_NAME.app"
ditto --noextattr --norsrc "$DIST/smcwrite" "$STAGE/usr/local/libexec/fancontrol-smcwrite"
chmod 4755 "$STAGE/usr/local/libexec/fancontrol-smcwrite"

cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/bash
# The installer runs as root, which is the whole reason this is a .pkg: it can
# give the helper the ownership and setuid bit it needs without the user ever
# opening a terminal.
set -e
HELPER=/usr/local/libexec/fancontrol-smcwrite
chown root:wheel "$HELPER"
chmod 4755 "$HELPER"

# Launch as the logged-in user, not as root.
USER_NAME=$(stat -f "%Su" /dev/console)
if [ -n "$USER_NAME" ] && [ "$USER_NAME" != "root" ]; then
    sudo -u "$USER_NAME" open "/Applications/Fan Control.app" || true
fi
exit 0
POST
chmod +x "$SCRIPTS/postinstall"

echo "==> building package"
pkgbuild --root "$STAGE" \
         --scripts "$SCRIPTS" \
         --identifier com.local.fancontrol.installer \
         --version "$VERSION" \
         --install-location / \
         "$OUT" >/dev/null

rm -rf "$STAGE" "$SCRIPTS"
echo
echo "Installer: $OUT"
echo "Size: $(du -h "$OUT" | cut -f1)"
