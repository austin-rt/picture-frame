#!/usr/bin/env bash
# Build the kiosk APK using Android SDK command-line tools.
# No Gradle, no Android Studio — just aapt, javac, d8, apksigner.
set -eu

KIOSK_DIR="$(cd "$(dirname "$0")" && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BUILD_TOOLS="$ANDROID_HOME/build-tools/34.0.0"
PLATFORM="$ANDROID_HOME/platforms/android-34/android.jar"

AAPT="$BUILD_TOOLS/aapt"
D8="$BUILD_TOOLS/d8"
APKSIGNER="$BUILD_TOOLS/apksigner"
ZIPALIGN="$BUILD_TOOLS/zipalign"

OUT="$KIOSK_DIR/build"
rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/classes" "$OUT/dex"

echo "=== Compiling resources ==="
"$AAPT" package -f -m -S "$KIOSK_DIR/res" -J "$OUT/gen" -M "$KIOSK_DIR/AndroidManifest.xml" -I "$PLATFORM"

echo "=== Compiling Java ==="
javac -source 1.8 -target 1.8 -classpath "$PLATFORM" -d "$OUT/classes" -sourcepath "$KIOSK_DIR/src:$OUT/gen" "$KIOSK_DIR/src/com/frame/kiosk/KioskActivity.java" "$KIOSK_DIR/src/com/frame/kiosk/BootReceiver.java"

echo "=== Converting to DEX ==="
"$D8" --release --output "$OUT/dex" --lib "$PLATFORM" "$OUT/classes/com/frame/kiosk/"*.class

echo "=== Packaging APK ==="
"$AAPT" package -f -S "$KIOSK_DIR/res" -M "$KIOSK_DIR/AndroidManifest.xml" -I "$PLATFORM" -F "$OUT/kiosk-unsigned.apk"

# Add DEX to APK
cd "$OUT/dex"
"$AAPT" add "$OUT/kiosk-unsigned.apk" classes.dex
cd "$KIOSK_DIR"

echo "=== Signing APK ==="
# Local debug signing key; the keystore itself is gitignored. Override the
# password with KIOSK_KEYSTORE_PASS if you generate your own.
KEYSTORE="$KIOSK_DIR/debug.keystore"
KS_PASS="${KIOSK_KEYSTORE_PASS:-framekiosk}"
if [ ! -f "$KEYSTORE" ]; then
    keytool -genkey -v -keystore "$KEYSTORE" -alias frame -keyalg RSA -keysize 2048 -validity 36500 -storepass "$KS_PASS" -keypass "$KS_PASS" -dname "CN=Frame,O=Frame,L=Home,ST=Home,C=US"
fi

"$ZIPALIGN" -f 4 "$OUT/kiosk-unsigned.apk" "$OUT/kiosk-aligned.apk"

"$APKSIGNER" sign --ks "$KEYSTORE" --ks-key-alias frame --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" --out "$OUT/kiosk.apk" "$OUT/kiosk-aligned.apk"

echo "=== Done ==="
ls -la "$OUT/kiosk.apk"
echo "Install with: adb install $OUT/kiosk.apk"
