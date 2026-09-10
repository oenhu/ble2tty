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

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP" || echo "警告: 签名失败(不影响本机调试运行)"

echo ""
echo "构建完成: $(pwd)/$APP"
echo "运行: open $APP"
echo ""
echo "首次运行请在 系统设置 > 隐私与安全性 > 蓝牙 中允许 CH9140Bridge。"
