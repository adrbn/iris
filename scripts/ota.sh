#!/usr/bin/env bash
# Publish a signed Iris.app so the iPhone installs it from anywhere (4G included), no cable,
# no shared Wi-Fi: the IPA is served over HTTPS by a server of yours (on a tailnet, say), and iOS
# installs it through itms-services. Called by `install.sh --ota`.
#
#   ./scripts/install.sh --ota
#
# Set in scripts/local.env: IRIS_OTA_HOST (the HTTPS host iOS downloads from), IRIS_OTA_SSH (where
# to copy, user@host, or "local" for this Mac) and optionally IRIS_OTA_DIR (default /opt/iris-ota).
set -euo pipefail

APP="${1:?usage: ota.sh <Iris.app>}"
HOST="${IRIS_OTA_HOST:?set IRIS_OTA_HOST in scripts/local.env}"
TARGET="${IRIS_OTA_SSH:?set IRIS_OTA_SSH in scripts/local.env}"
DIR="${IRIS_OTA_DIR:-/opt/iris-ota}"
BASE="https://${HOST}/iris"
STAGE="$(dirname "${APP}")/ota"

say() { printf "\033[1m%s\033[0m\n" "$*"; }

rm -rf "${STAGE}"
mkdir -p "${STAGE}/Payload"
cp -R "${APP}" "${STAGE}/Payload/"
(cd "${STAGE}" && zip -qry Iris.ipa Payload)
rm -rf "${STAGE}/Payload"

ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Info.plist")"
STAMP="$(date +%Y%m%d%H%M)"

cat > "${STAGE}/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
  <key>assets</key><array><dict>
    <key>kind</key><string>software-package</string>
    <key>url</key><string>${BASE}/Iris.ipa?${STAMP}</string>
  </dict></array>
  <key>metadata</key><dict>
    <key>bundle-identifier</key><string>${ID}</string>
    <key>bundle-version</key><string>1.0</string>
    <key>kind</key><string>software</string>
    <key>title</key><string>Iris</string>
  </dict>
</dict></array></dict></plist>
PLIST

cat > "${STAGE}/index.html" <<HTML
<!doctype html><html lang="fr"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Iris</title>
<style>
 body{font:17px/1.5 -apple-system,system-ui,sans-serif;margin:0;min-height:100vh;background:#000;color:#fff;
      display:grid;place-content:center;gap:22px;text-align:center;padding:24px}
 a{display:inline-block;padding:16px 34px;border-radius:30px;background:#FF5B1F;color:#000;
   text-decoration:none;font-weight:700}
 p{color:#8A8A8A;margin:0;font-size:15px}
</style>
<div><strong style="font-size:28px">Iris</strong><p>build ${STAMP}</p></div>
<a href="itms-services://?action=download-manifest&amp;url=${BASE}/manifest.plist?${STAMP}">Installer</a>
</html>
HTML

if [[ "${TARGET}" == local ]]; then
  # Asgard off: this Mac serves, on ITS OWN port (443 and 8447 belong to other projects). The
  # App Store Tailscale can't serve files (sandbox) but relays a local port, with the certificate.
  PORT="${IRIS_OTA_PORT:-8449}"
  say "Publication locale dans ${DIR} (port ${PORT})…"
  mkdir -p "${DIR}"
  cp "${STAGE}/Iris.ipa" "${STAGE}/manifest.plist" "${STAGE}/index.html" "${DIR}/"
  pgrep -f "http.server ${PORT}" >/dev/null || (cd "${DIR}" && nohup python3 -m http.server "${PORT}" --bind 127.0.0.1 >/dev/null 2>&1 &)
  /Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg --https="${HOST##*:}" --set-path /iris "${PORT}" >/dev/null
else
  say "Envoi vers ${TARGET}:${DIR}…"
  ssh -o ConnectTimeout=20 "${TARGET}" "mkdir -p '${DIR}'"
  scp -q "${STAGE}/Iris.ipa" "${STAGE}/manifest.plist" "${STAGE}/index.html" "${TARGET}:${DIR}/"
  ssh "${TARGET}" "tailscale serve --bg --https=443 --set-path /iris '${DIR}'" >/dev/null
fi

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${BASE}/manifest.plist")"
[[ "${code}" == 200 ]] || { printf "ÉCHEC : le manifeste répond %s\n" "${code}" >&2; exit 1; }
say "Publié : ${BASE}/"
