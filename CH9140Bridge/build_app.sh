#!/bin/bash
# 构建 CH9140Bridge.app (Release) 并做 ad-hoc 签名
# 蓝牙权限(TCC)要求 App 必须带 Info.plist 的 Bundle 形式运行
set -e
cd "$(dirname "$0")"

echo "==> swift build -c release"
swift build -c release

APP="CH9140Bridge.app"
echo "==> 打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CH9140Bridge "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# 版本号: 优先取 git tag(v*), 失败回退 Info.plist 中的值; build 号取提交数
# (注意: set -e 下命令替换失败会终止脚本, git 命令必须 || true 兜底)
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
PLIST_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
VERSION=$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)
VERSION=${VERSION#v}
if [ -z "$VERSION" ]; then VERSION="$PLIST_VERSION"; fi
BUILD=$(git rev-list --count HEAD 2>/dev/null || true)
if [ -z "$BUILD" ] || [ "$BUILD" -le 0 ] 2>/dev/null; then BUILD="$PLIST_BUILD"; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
                        -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
echo "==> 版本 $VERSION (build $BUILD)"

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP" || echo "警告: 签名失败(不影响本机调试运行)"

echo ""
echo "构建完成: $(pwd)/$APP"
echo "运行: open $APP"
echo ""
echo "首次运行请在 系统设置 > 隐私与安全性 > 蓝牙 中允许 CH9140Bridge。"
