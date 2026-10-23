#!/bin/sh
set -eu
cd "$(dirname "$0")"
: "${USB_PROFILE:?Set USB_PROFILE to a macOS provisioning profile with Accessory Access enabled}"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to the matching Apple Development or Developer ID identity}"
[ "$SIGN_IDENTITY" != - ] || { echo 'USB requires profile-backed signing, not ad-hoc signing.' >&2; exit 1; }
[ -f "$USB_PROFILE" ] || { echo 'USB_PROFILE does not exist.' >&2; exit 1; }
mkdir -p bin
stage=$(mktemp -d "$PWD/bin/.usb-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
security cms -D -i "$USB_PROFILE" -o "$stage/profile.plist"
plist=/usr/libexec/PlistBuddy
usb=$($plist -c 'Print :Entitlements:com.apple.developer.accessory-access.usb' "$stage/profile.plist" 2>/dev/null || true)
[ "$usb" = true ] || { echo 'The profile does not authorize Accessory Access.' >&2; exit 1; }
app_id=$($plist -c 'Print :Entitlements:com.apple.application-identifier' "$stage/profile.plist" 2>/dev/null || true)
[ -n "$app_id" ] || { echo 'A macOS app provisioning profile is required.' >&2; exit 1; }
team_id=$($plist -c 'Print :Entitlements:com.apple.developer.team-identifier' "$stage/profile.plist")
bundle_id=${app_id#*.}
case "$bundle_id" in *[!A-Za-z0-9.-]*|'') echo 'Use an explicit App ID (no wildcard).' >&2; exit 1;; esac
case "$team_id" in *[!A-Za-z0-9]*|'') echo 'Invalid team identifier.' >&2; exit 1;; esac
make
app="$stage/VMControlUSB.app"
mkdir -p "$app/Contents/MacOS"
cp bin/vmctld "$app/Contents/MacOS/vmctld"
cp USBApp/Info.plist "$app/Contents/Info.plist"
$plist -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
cp "$USB_PROFILE" "$app/Contents/embedded.provisionprofile"
cp vmctld.entitlements "$stage/usb.entitlements"
$plist -c 'Add :com.apple.developer.accessory-access.usb bool true' "$stage/usb.entitlements"
$plist -c "Add :com.apple.application-identifier string $app_id" "$stage/usb.entitlements"
$plist -c "Add :com.apple.developer.team-identifier string $team_id" "$stage/usb.entitlements"
# Downloaded profiles carry quarantine/WhereFroms attributes that fail strict verification.
xattr -cr "$app"
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$stage/usb.entitlements" "$app"
codesign --verify --strict "$app"
# Keep the executable inode of an existing daemon intact during upgrades.
if [ -e bin/VMControlUSB.app ]; then mv bin/VMControlUSB.app "$stage/previous.app"; fi
if ! mv "$app" bin/VMControlUSB.app; then
    if [ -e "$stage/previous.app" ]; then mv "$stage/previous.app" bin/VMControlUSB.app; fi
    exit 1
fi
echo 'Built bin/VMControlUSB.app. Stop the VM and quit the old supervisor once; the next vmctl command starts this bundle.'
