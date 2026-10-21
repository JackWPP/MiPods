# MiPods —— 构建与运行
#
# 必须用 Xcode 工具链：Command Line Tools 缺 SwiftUI 宏插件
# （libSwiftUIMacros.dylib），`@State` / `#Preview` 会直接编译失败。
# 本机装了 Xcode 27.1，但 xcode-select 指向 CLT，所以这里显式覆盖 DEVELOPER_DIR。

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

SWIFT   := swift
APP     := MiPods.app
PRODUCT := .build/out/Products/Debug/MiPods
BUNDLE_ID ?= com.mipods.menubar

.PHONY: all build app test run demo stop clean install

all: app

build:
	$(SWIFT) build

# 这些测试钉住了真机抓包字节；挂掉就说明 App 会连不上耳机。
test:
	$(SWIFT) test

# 打成 .app 是必需的：裸可执行文件没有 Info.plist，CoreBluetooth 会静默失败，
# 系统也不会为它分配菜单栏图标。
app: build
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp "$(PRODUCT)" "$(APP)/Contents/MacOS/MiPods"
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>CFBundleExecutable</key><string>MiPods</string>' \
	  '  <key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string>' \
	  '  <key>CFBundleName</key><string>MiPods</string>' \
	  '  <key>CFBundleDisplayName</key><string>小米耳机</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>CFBundleShortVersionString</key><string>0.1.0</string>' \
	  '  <key>CFBundleVersion</key><string>1</string>' \
	  '  <key>LSMinimumSystemVersion</key><string>14.0</string>' \
	  '  <key>LSUIElement</key><true/>' \
	  '  <key>NSBluetoothAlwaysUsageDescription</key><string>MiPods 需要蓝牙来读取小米耳机的电量并切换降噪模式。</string>' \
	  '</dict></plist>' > "$(APP)/Contents/Info.plist"
	@codesign --force --deep --sign - "$(APP)" 2>/dev/null || true
	@echo "built $(APP)"

run: app
	@open "$(APP)"

# 开发用：带演示模式（自动打开面板并弹 HUD），便于截图。
demo: app
	@MIPODS_DEMO=1 "$(APP)/Contents/MacOS/MiPods"

stop:
	@pkill -f "$(APP)/Contents/MacOS" 2>/dev/null || true
	@echo stopped

clean:
	@rm -rf .build "$(APP)"
	@echo cleaned

# 把 App 装到 /Applications
install: app
	@rm -rf "/Applications/$(APP)"
	@cp -R "$(APP)" /Applications/
	@echo "installed to /Applications/$(APP)"
