#!/bin/bash
#
# build.sh - assemble, link, bundle, sign and package hello.s for iOS.
#
#   ./build.sh device    signed .app + .ipa for a real iPhone   (default)
#   ./build.sh sim       .app for the iOS Simulator, then run it
#
# The only thing that ever touches hello.s is the assembler. There is no
# compiler in this pipeline.
#
set -euo pipefail

MODE="${1:-device}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
APP_NAME="HelloASM"
BUNDLE_ID="com.craigglendenning.helloasm"
MIN_IOS="14.0"
TEAM_ID="MCALPSQ5P5"
SIGN_ID="Apple Development: Craig Glendenning (BJ5WFMAG3A)"
PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/e09d5074-9bd7-42de-87d5-0e712660f19c.mobileprovision"
SIM_UDID="289C5299-5026-434E-B5C8-05737E9EBDBA"

if [ "$MODE" = "sim" ]; then
    SDK_NAME="iphonesimulator"; TARGET="arm64-apple-ios${MIN_IOS}-simulator"
    PLATFORM="ios-simulator";   PLIST_PLATFORM="iPhoneSimulator"
else
    SDK_NAME="iphoneos";        TARGET="arm64-apple-ios${MIN_IOS}"
    PLATFORM="ios";             PLIST_PLATFORM="iPhoneOS"
fi

SDK="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
SDK_VER="$(xcrun --sdk "$SDK_NAME" --show-sdk-version)"
STAGE="$OUT/$MODE"
APP="$STAGE/$APP_NAME.app"

rm -rf "$STAGE"; mkdir -p "$APP"

# --- 1. assemble: hello.s -> hello.o (mnemonics -> machine code, 1:1) -------
xcrun --sdk "$SDK_NAME" clang -x assembler -c \
    -target "$TARGET" -isysroot "$SDK" \
    -o "$OUT/hello-$MODE.o" "$ROOT/hello.s"

# --- 2. link: resolve UIKit / libobjc imports, emit the Mach-O executable ---
#   -e _main        entry point (LC_MAIN)
#   -dead_strip     drop anything unreachable
#   -no_data_const  fold __DATA_CONST into __DATA, saving one 16K page
#   -x              omit local symbols from the symbol table
xcrun --sdk "$SDK_NAME" ld \
    -arch arm64 -platform_version "$PLATFORM" "$MIN_IOS" "$SDK_VER" \
    -syslibroot "$SDK" \
    -lSystem -lobjc \
    -framework UIKit -framework Foundation -framework CoreFoundation -framework QuartzCore \
    -e _main -dead_strip -no_data_const -x \
    -o "$APP/$APP_NAME" "$OUT/hello-$MODE.o"

# --- 3. Info.plist ----------------------------------------------------------
cat > "$APP/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>Hello ASM</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleVersion</key><string>3</string>
	<key>CFBundleShortVersionString</key><string>1.2</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$PLIST_PLATFORM</string></array>
	<key>MinimumOSVersion</key><string>$MIN_IOS</string>
	<key>UIDeviceFamily</key><array><integer>1</integer></array>
	<key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
	<key>UILaunchScreen</key><dict/>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>DTPlatformName</key><string>$SDK_NAME</string>
	<key>DTSDKName</key><string>$SDK_NAME$SDK_VER</string>
</dict></plist>
EOF
plutil -lint "$APP/Info.plist" > /dev/null

# --- 4. simulator: install and run ------------------------------------------
if [ "$MODE" = "sim" ]; then
    xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM_UDID" -b > /dev/null
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$SIM_UDID" "$APP"
    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"
    echo "running on simulator $SIM_UDID"
    exit 0
fi

# --- 5. embed the provisioning profile and sign -----------------------------
cp "$PROFILE" "$APP/embedded.mobileprovision"

cat > "$OUT/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>application-identifier</key><string>$TEAM_ID.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>
	<key>get-task-allow</key><true/>
	<key>keychain-access-groups</key><array><string>$TEAM_ID.$BUNDLE_ID</string></array>
</dict></plist>
EOF

codesign --force --sign "$SIGN_ID" \
    --entitlements "$OUT/entitlements.plist" \
    --timestamp=none --generate-entitlement-der \
    "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 6. package the IPA -----------------------------------------------------
rm -rf "$STAGE/Payload" "$OUT/$APP_NAME.ipa"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
( cd "$STAGE" && zip -qrX "$OUT/$APP_NAME.ipa" Payload )

echo
echo "executable : $(stat -f%z "$APP/$APP_NAME") bytes"
echo "ipa        : $(stat -f%z "$OUT/$APP_NAME.ipa") bytes"
echo "ipa path   : $OUT/$APP_NAME.ipa"
