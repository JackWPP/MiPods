#!/bin/bash
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/../../app/MiPods" && pwd)"
OUT="$PROJ/.build/MiPods.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$PROJ/.build/debug/MiPods" "$OUT/Contents/MacOS/MiPods"
cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>            <string>MiPods</string>
	<key>CFBundleDisplayName</key>     <string>小米耳机</string>
	<key>CFBundleIdentifier</key>      <string>com.mipods.menubar</string>
	<key>CFBundleExecutable</key>      <string>MiPods</string>
	<key>CFBundlePackageType</key>     <string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>CFBundleVersion</key>         <string>1</string>
	<key>LSMinimumSystemVersion</key>  <string>14.0</string>
	<!-- 菜单栏 App：无 Dock 图标 -->
	<key>LSUIElement</key>             <true/>
	<!-- CoreBluetooth 必需，缺失会导致蓝牙静默失败 -->
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>小米耳机需要蓝牙权限来读取耳机电量并切换降噪模式。</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>小米耳机需要蓝牙权限来读取耳机电量并切换降噪模式。</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$OUT" 2>&1 | tail -2
echo "BUILT $OUT"
