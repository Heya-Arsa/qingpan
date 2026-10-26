#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/清盘.app"
SDK="$(xcrun --show-sdk-path)"

mkdir -p "$BUILD"

# 1) 图标
if [ ! -f "$BUILD/AppIcon.icns" ]; then
  echo "▸ 生成图标…"
  /Users/xueyatao/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3 \
    "$ROOT/tools/gen_icon.py" "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi

# 2) 编译
echo "▸ 编译…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -fobjc-arc -O2 \
  -isysroot "$SDK" \
  -mmacosx-version-min=12.0 \
  -framework Cocoa -framework WebKit \
  "$ROOT/App/Sources/main.m" \
  -o "$APP/Contents/MacOS/DiskSweeper"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/App/Resources/index.html" "$APP/Contents/Resources/index.html"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✅ 构建完成: $APP"
