#!/bin/bash
# Places the Wine loader inside an .app bundle so macOS treats every Windows game
# as a real game app: Game Mode, proper Dock presence, game-controller entitlement.
# The runtime puts $ENGINE_DIR/lib/wine on WINEDLLPATH so the relocated loader
# still finds ntdll.so (same trick CrossOver uses for its hosted-app bundle).
source "$(dirname "$0")/common.sh"

APP="$ENGINE_DIR/RunMyGames Engine.app"
[[ -x "$ENGINE_DIR/bin/wine" ]] || die "engine not built: $ENGINE_DIR"

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ENGINE_DIR/bin/wine" "$APP/Contents/MacOS/wine"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>wine</string>
    <key>CFBundleIdentifier</key><string>dev.runmygames.engine</string>
    <key>CFBundleName</key><string>RunMyGames Engine</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>LSSupportsGameMode</key><true/>
    <key>GCSupportsControllerUserInteraction</key><true/>
    <key>GCSupportedGameControllers</key>
    <array>
        <dict><key>ProfileName</key><string>ExtendedGamepad</string></dict>
    </array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
codesign -f -s - "$APP" 2>/dev/null || warn "ad-hoc signing of engine bundle failed"
log "Engine bundle: $APP"
