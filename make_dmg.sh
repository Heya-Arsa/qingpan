#!/bin/bash
# 生成可分发的 .dmg 安装包
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/清盘.app"
PLIST="$ROOT/Info.plist"
VOL="清盘"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || echo "1.0.0")
OUT="$BUILD/DiskSweeper-$VERSION.dmg"
STAGE="$BUILD/dmg-stage"
RW="$BUILD/rw.dmg"

cleanup() {
  hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
  rm -rf "$STAGE" "$RW"
}
trap cleanup EXIT

# 1) 确保 App 已构建
if [ ! -d "$APP" ]; then
  echo "▸ 未找到 App，先构建…"
  "$ROOT/build.sh"
fi

# 2) 准备内容：App + 应用程序快捷方式（拖拽安装）
echo "▸ 准备 DMG 内容…"
rm -rf "$STAGE" "$OUT" "$RW"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 3) 先做读写镜像，便于写入卷图标
echo "▸ 生成镜像…"
hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -quiet -format UDRW -fs HFS+ "$RW"
hdiutil attach "$RW" -readwrite -noverify -noautoopen -quiet >/dev/null

for _ in $(seq 1 25); do
  [ -d "/Volumes/$VOL" ] && break
  sleep 0.2
done

if [ -d "/Volumes/$VOL" ] && command -v SetFile >/dev/null 2>&1; then
  cp "$BUILD/AppIcon.icns" "/Volumes/$VOL/.VolumeIcon.icns"
  SetFile -a C "/Volumes/$VOL" || true
fi

sync
hdiutil detach "/Volumes/$VOL" -quiet

# 4) 压缩为只读镜像
echo "▸ 压缩…"
hdiutil convert "$RW" -format UDZO -o "$OUT" -quiet
rm -f "$RW"

# 5) 校验
hdiutil verify "$OUT" >/dev/null
echo "✅ $OUT  ($(du -h "$OUT" | awk '{print $1}'))"
