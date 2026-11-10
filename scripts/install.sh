#!/usr/bin/env bash
# Build Iris and install it on a paired iPhone, without the Xcode iOS platform.
#
#   ./scripts/install.sh            # first reachable device, installs only
#   ./scripts/install.sh <UDID>     # a specific one
#   ./scripts/install.sh --launch   # …and open it, which you almost never want
#   ./scripts/install.sh --ipa      # no iPhone, no profile: an unsigned Iris.ipa to sideload
#
# Pair a device first: Xcode > Window > Devices and Simulators > select the iPhone >
# tick "Connect via network". It must be unlocked and on the same network.
#
# ## Why this does not call xcodebuild
#
# Xcode 26 ships the simulator runtime and the device support as one "iOS platform"
# component. Delete the runtime to reclaim disk — `xcrun simctl runtime delete all` —
# and xcodebuild stops offering *any* iOS destination, physical iPhones included:
# "iOS 26.5 is not installed", even though `xcodebuild -showsdks` still lists
# iphoneos26.5. Getting it back is an 8.5 GB download.
#
# None of that is needed. The SDK inside Xcode.app is enough: swiftc compiles the
# sources, actool compiles the icon, codesign signs against a development profile
# already on the Mac, and devicectl installs. It is also faster than xcodebuild.
set -euo pipefail

BUNDLE_ID="com.adrbn.iris"
DISPLAY_NAME="Iris"
DEPLOYMENT_TARGET="26.0"

LAUNCH="no"
OTA="no"
IPA="no"
ARGS=()
for arg in "$@"; do
  if [[ "${arg}" == "--launch" ]]; then LAUNCH="yes"
  elif [[ "${arg}" == "--ipa" ]]; then IPA="yes"   # AltStore / Sideloadly sign it with the user's own Apple ID
  elif [[ "${arg}" == "--ota" ]]; then OTA="yes"   # build, then publish for an install from anywhere (scripts/ota.sh)
  else ARGS+=("${arg}"); fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
# Your own defaults (Mac remote, Ollama, OTA host), kept out of git: see scripts/local.env.example.
# Never read for --ipa, so a public build carries none of them.
if [[ "${IPA}" == "no" && -f scripts/local.env ]]; then set -a; . scripts/local.env; set +a; fi
BUILD="${ROOT}/.build/device"
APP="${BUILD}/${DISPLAY_NAME}.app"

say() { printf "\033[1m%s\033[0m\n" "$*"; }
die() { printf "\033[1merreur:\033[0m %s\n" "$*" >&2; exit 1; }

if [[ "${IPA}" == "no" ]]; then
# --- device ------------------------------------------------------------------

DEVICES="$(xcrun devicectl list devices 2>/dev/null || true)"
UDID="${1:-}"
if [[ -z "${UDID}" ]]; then
  UDID="$(printf '%s\n' "${DEVICES}" \
    | awk '$0 !~ /simulated/ && $0 !~ /unavailable/ && ($0 ~ /connected/ || $0 ~ /available/) {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) {print $i; exit}}')"
fi

if [[ -z "${UDID}" && "${OTA}" == "yes" ]]; then
  # Unreachable is fine for OTA: any paired iPhone the profile lists installs from anywhere.
  UDID="$(printf '%s\n' "${DEVICES}" | awk '$0 !~ /simulated/ && $0 ~ /physical/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) {print $i; exit}}')"
fi
if [[ -z "${UDID}" ]]; then
  KNOWN="$(printf '%s\n' "${DEVICES}" | awk '$0 !~ /simulated/ && $0 ~ /physical/ {print}')"
  if [[ -n "${KNOWN}" ]]; then
    cat >&2 <<MSG

Aucun iPhone joignable, mais un appareil est déjà appairé :

${KNOWN}

Il est hors de portée : éteint, verrouillé, hors du réseau, ou « Connect via
network » décoché. Déverrouille-le et mets-le sur le même Wi-Fi, ou branche-le
en USB, puis relance.
MSG
  else
    cat >&2 <<'MSG'

Aucun iPhone appairé.

  1. Branche l'iPhone en USB, déverrouille-le, accepte « Faire confiance ».
  2. Xcode > Window > Devices and Simulators > sélectionne l'iPhone >
     coche « Connect via network ». Ensuite l'USB n'est plus nécessaire.

MSG
  fi
  die "RIEN N'A ÉTÉ INSTALLÉ."
fi

# The hardware UDID, which is what a provisioning profile lists. It differs from
# the identifier devicectl uses, so both are needed.
HARDWARE_UDID="$(xcrun devicectl device info details --device "${UDID}" 2>/dev/null \
  | awk -F': *' '/identifier|Identifier/ && $2 ~ /^000/ {print $2; exit}')"

say "Appareil : ${UDID}"

# --- signing -----------------------------------------------------------------

say "Recherche d'un profil de développement…"
# Tab-separated: profile paths contain spaces, so the default IFS would split them.
IFS=$'\t' read -r PROFILE IDENTITY TEAM <<<"$(
  HARDWARE_UDID="${HARDWARE_UDID}" BUNDLE_ID="${BUNDLE_ID}" python3 - <<'PY'
import glob, os, plistlib, re, subprocess, sys

bundle = os.environ["BUNDLE_ID"]
device = os.environ.get("HARDWARE_UDID") or ""

# Codesigning identities the keychain will actually sign with, by SHA-1.
listing = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                         capture_output=True, text=True).stdout
usable = set(re.findall(r"\b([0-9A-F]{40})\b", listing))
revoked = {sha for sha, line in
           ((m, l) for l in listing.splitlines() for m in re.findall(r"\b([0-9A-F]{40})\b", l))
           if "REVOKED" in line}
usable -= revoked

best = None
for directory in ("~/Library/Developer/Xcode/UserData/Provisioning Profiles",
                  "~/Library/MobileDevice/Provisioning Profiles"):
    for path in glob.glob(os.path.expanduser(directory) + "/*.mobileprovision"):
        raw = subprocess.run(["security", "cms", "-D", "-i", path],
                             capture_output=True).stdout
        if not raw:
            continue
        try:
            profile = plistlib.loads(raw)
        except Exception:
            continue

        app_id = profile.get("Entitlements", {}).get("application-identifier", "")
        team, _, suffix = app_id.partition(".")
        if suffix not in ("*", bundle):
            continue
        if device and device not in profile.get("ProvisionedDevices", []):
            continue
        if not profile.get("Entitlements", {}).get("get-task-allow"):
            continue

        for der in profile.get("DeveloperCertificates", []):
            sha = subprocess.run(["openssl", "x509", "-inform", "DER", "-noout",
                                  "-fingerprint", "-sha1"],
                                 input=der, capture_output=True).stdout.decode()
            sha = sha.strip().split("=")[-1].replace(":", "")
            if sha in usable:
                # An exact bundle match beats a wildcard; otherwise take the first.
                score = 1 if suffix == bundle else 0
                if best is None or score > best[0]:
                    best = (score, path, sha, team)
                break

if best is None:
    sys.exit("aucun profil de développement ne couvre "
             f"{bundle} pour cet appareil avec un certificat valide")
print("\t".join((best[1], best[2], best[3])))
PY
)"
[[ -n "${PROFILE:-}" ]] || die "profil introuvable."
say "Profil  : $(basename "${PROFILE}")"
fi

# --- compile -----------------------------------------------------------------

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
[[ -d "${SDK}" ]] || die "SDK iPhoneOS introuvable."

rm -rf "${BUILD}"
mkdir -p "${APP}"

say "Compilation…"
# shellcheck disable=SC2046
xcrun -sdk iphoneos swiftc \
  -target "arm64-apple-ios${DEPLOYMENT_TARGET}" \
  -sdk "${SDK}" \
  -module-name Iris \
  -parse-as-library \
  -O \
  -o "${APP}/${DISPLAY_NAME}" \
  $(find Iris -name '*.swift')

say "Widgets…"
APPEX="${APP}/PlugIns/IrisWidgets.appex"
mkdir -p "${APPEX}"
# -e _NSExtensionMain: Xcode enters every app extension there, not at main. Without it iOS never
# registered the widgets (no gallery entry, black Dynamic Island, 09/11).
xcrun -sdk iphoneos swiftc \
  -target "arm64-apple-ios${DEPLOYMENT_TARGET}" \
  -sdk "${SDK}" \
  -module-name IrisWidgets \
  -parse-as-library \
  -application-extension \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -O \
  -o "${APPEX}/IrisWidgets" \
  Widgets/*.swift Iris/GlassesStatus.swift Iris/Theme.swift

say "Icône…"
xcrun actool Iris/AppIcon.icon \
  --compile "${APP}" --platform iphoneos --minimum-deployment-target "${DEPLOYMENT_TARGET}" \
  --app-icon AppIcon --output-partial-info-plist "${BUILD}/icon.plist" \
  --output-format human-readable-text >/dev/null 2>&1 || true

# --- bundle ------------------------------------------------------------------

SDK_NAME="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null | sed 's/^/iphoneos/')"
SDK_BUILD="$(xcrun --sdk iphoneos --show-sdk-build-version 2>/dev/null)"
XCODE_VER="$(xcodebuild -version 2>/dev/null | awk 'NR==1{split($2,v,"."); printf "%d%d%d", v[1], v[2], v[3]}')"
XCODE_BUILD="$(xcodebuild -version 2>/dev/null | awk 'NR==2{print $3}')"
XCODE_STAMP="$(printf '{"DTCompiler":"com.apple.compilers.llvm.clang.1_0","DTPlatformBuild":"%s","DTSDKBuild":"%s","DTPlatformVersion":"%s","DTXcode":"%s","DTXcodeBuild":"%s","BuildMachineOSBuild":"%s"}' \
  "${SDK_BUILD}" "${SDK_BUILD}" "$(xcrun --sdk iphoneos --show-sdk-version)" "${XCODE_VER}" "${XCODE_BUILD}" "$(sw_vers -buildVersion)")"
export XCODE_STAMP
BUNDLE_ID="${BUNDLE_ID}" DISPLAY_NAME="${DISPLAY_NAME}" \
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" SDK_NAME="${SDK_NAME}" \
APP="${APP}" BUILD="${BUILD}" python3 - <<'PY'
import json, os, plistlib

app, build = os.environ["APP"], os.environ["BUILD"]
info = {
    "CFBundleDevelopmentRegion": "fr",
    "CFBundleDisplayName": os.environ["DISPLAY_NAME"],
    "CFBundleExecutable": os.environ["DISPLAY_NAME"],
    "CFBundleIdentifier": os.environ["BUNDLE_ID"],
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": os.environ["DISPLAY_NAME"],
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "DTPlatformName": "iphoneos",
    "DTSDKName": os.environ.get("SDK_NAME") or "iphoneos",
    # What Xcode stamps on every bundle; the widget extension had none and its Dynamic Island stayed
    # black (09/11) while Xcode-built widgets render. Cheap to match.
    **json.loads(os.environ.get("XCODE_STAMP") or "{}"),
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": os.environ["DEPLOYMENT_TARGET"],
    "UIDeviceFamily": [1],
    "UILaunchScreen": {},
    "UIRequiredDeviceCapabilities": ["arm64"],
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    "NSBluetoothAlwaysUsageDescription":
        "Iris se connecte à vos lunettes en Bluetooth pour recevoir leurs photos.",
    "NSLocationWhenInUseUsageDescription": "Le guide cherche sur Wikipédia les lieux autour de toi.",
    "NSMicrophoneUsageDescription": "Le traducteur écoute la conversation avec le micro de l'iPhone.",
    "NSSpeechRecognitionUsageDescription": "Iris transcrit ce que tu dis dans le micro des lunettes, sur l'iPhone.",
    "NSLocalNetworkUsageDescription":
        "Iris peut parler à un modèle d'IA qui tourne sur un ordinateur de votre réseau.",
    "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    "UIBackgroundModes": ["bluetooth-central"],
    "NSSupportsLiveActivities": True,
    "UIFileSharingEnabled": True,
    # Personal defaults from scripts/local.env; empty in a public build.
    **{k: os.environ[v] for k, v in (("IrisMacRemote", "IRIS_MAC_REMOTE"), ("IrisOllamaURL", "IRIS_OLLAMA_URL"))
       if os.environ.get(v)},
    "LSSupportsOpeningDocumentsInPlace": True,
}

icons = os.path.join(build, "icon.plist")
if os.path.exists(icons):
    with open(icons, "rb") as handle:
        # The ~ipad variants would advertise an iPad build this app is not.
        info.update({k: v for k, v in plistlib.load(handle).items()
                     if not k.endswith("~ipad")})

with open(os.path.join(app, "Info.plist"), "wb") as handle:
    plistlib.dump(info, handle)

widget = {k: info[k] for k in ("CFBundleDevelopmentRegion", "CFBundleInfoDictionaryVersion",
                               "CFBundleShortVersionString", "CFBundleVersion", "CFBundleSupportedPlatforms",
                               "DTPlatformName", "DTSDKName", "MinimumOSVersion", "UIDeviceFamily",
                               *[k for k in info if k.startswith("DT") or k == "BuildMachineOSBuild"],
                               "UIRequiredDeviceCapabilities")}
widget.update({
    "CFBundleDisplayName": "Iris",
    "CFBundleExecutable": "IrisWidgets",
    "CFBundleIdentifier": info["CFBundleIdentifier"] + ".widgets",
    "CFBundleName": "IrisWidgets",
    "CFBundlePackageType": "XPC!",
    "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
})
with open(os.path.join(app, "PlugIns", "IrisWidgets.appex", "Info.plist"), "wb") as handle:
    plistlib.dump(widget, handle)
PY

if [[ "${IPA}" == "yes" ]]; then
  # Ad-hoc only: the sideloading tool re-signs with its own team and entitlements.
  codesign -f -s - "${APPEX}" && codesign -f -s - "${APP}"
  rm -rf "${BUILD}/Payload" "${BUILD}/Iris.ipa"
  mkdir "${BUILD}/Payload" && cp -R "${APP}" "${BUILD}/Payload/"
  (cd "${BUILD}" && zip -qry Iris.ipa Payload)
  say "IPA : ${BUILD}/Iris.ipa"
  exit 0
fi

cp "${PROFILE}" "${APP}/embedded.mobileprovision"

cat > "${BUILD}/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>application-identifier</key><string>${TEAM}.${BUNDLE_ID}</string>
  <key>com.apple.developer.team-identifier</key><string>${TEAM}</string>
  <key>get-task-allow</key><true/>
  <key>keychain-access-groups</key><array><string>${TEAM}.${BUNDLE_ID}</string><string>${TEAM}.${BUNDLE_ID}.shared</string></array>
$(security cms -D -i "${PROFILE}" 2>/dev/null | grep -q HotspotConfiguration \
  && echo '  <key>com.apple.developer.networking.HotspotConfiguration</key><true/>')
</dict>
</plist>
EOF

# The widget extension: signed first, with the wildcard dev profile (its own bundle id).
WIDGET_PROFILE="$(TEAM="${TEAM}" python3 - <<'PY'
import glob, os, plistlib, subprocess
for path in glob.glob(os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles/*.mobileprovision")) + \
            glob.glob(os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision")):
    raw = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True).stdout
    try:
        ent = plistlib.loads(raw).get("Entitlements", {})
    except Exception:
        continue
    if ent.get("application-identifier") == os.environ["TEAM"] + ".*" and ent.get("get-task-allow"):
        print(path)
        break
PY
)"
[[ -n "${WIDGET_PROFILE}" ]] || die "profil générique (*) introuvable pour les widgets."
cp "${WIDGET_PROFILE}" "${APPEX}/embedded.mobileprovision"
cat > "${BUILD}/widget-entitlements.plist" <<WENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>application-identifier</key><string>${TEAM}.${BUNDLE_ID}.widgets</string>
  <key>com.apple.developer.team-identifier</key><string>${TEAM}</string>
  <key>get-task-allow</key><true/>
  <key>keychain-access-groups</key><array><string>${TEAM}.${BUNDLE_ID}.shared</string></array>
</dict>
</plist>
WENT

say "Signature…"
codesign -f -s "${IDENTITY}" --entitlements "${BUILD}/widget-entitlements.plist" \
  --generate-entitlement-der --timestamp=none "${APPEX}"
codesign -f -s "${IDENTITY}" \
  --entitlements "${BUILD}/entitlements.plist" \
  --generate-entitlement-der \
  --timestamp=none \
  "${APP}"

# --- install -----------------------------------------------------------------

if [[ "${OTA}" == "yes" ]]; then
  exec "${ROOT}/scripts/ota.sh" "${APP}"
fi

say "Installation…"
if ! xcrun devicectl device install app --device "${UDID}" "${APP}"; then
  die "installation refusée. L'iPhone doit être DÉVERROUILLÉ (écran allumé) et le
Mode développeur actif : Réglages > Confidentialité et sécurité > Mode développeur."
fi

# Not launched unless --launch: relaunching an app under someone's fingers looks like a crash.
if [[ "${LAUNCH:-no}" == "yes" ]]; then
  say "Lancement…"
  xcrun devicectl device process launch --device "${UDID}" "${BUNDLE_ID}" >/dev/null || \
    say "Lancement impossible, ouvre Iris à la main."
fi

say "Installé. Ouvre Iris quand tu veux."
