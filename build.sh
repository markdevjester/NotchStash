#!/bin/zsh
# Собирает NotchStash.app (arm64 + Intel).
#   ./build.sh            — собрать build/NotchStash.app
#   ./build.sh --install  — собрать, положить в /Applications и запустить
#   ./build.sh --release  — собрать и упаковать build/NotchStash-<версия>.zip для GitHub
set -e
cd "$(dirname "$0")"
# если лицензия Xcode не принята — собираем через Command Line Tools
if ! xcrun --find swiftc >/dev/null 2>&1 && [[ -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

APP=build/NotchStash.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 Sources/*.swift -o build/obj/NotchStash-$arch
done
lipo -create build/obj/NotchStash-arm64 build/obj/NotchStash-x86_64 -output "$APP/Contents/MacOS/NotchStash"

cp Info.plist "$APP/Contents/Info.plist"
[[ -f Assets/AppIcon.icns ]] && cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Собрано: $APP ($(lipo -archs "$APP/Contents/MacOS/NotchStash"))"

if [[ "$1" == "--install" ]]; then
  pkill -x NotchStash 2>/dev/null || true
  pkill -x Bufer 2>/dev/null || true          # старое имя
  sleep 0.5
  rm -rf /Applications/Bufer.app /Applications/NotchStash.app
  cp -R "$APP" /Applications/NotchStash.app
  open /Applications/NotchStash.app
  echo "Установлено в /Applications и запущено"
fi

if [[ "$1" == "--release" ]]; then
  VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
  ZIP=build/NotchStash-$VER.zip
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Архив: $ZIP"
  shasum -a 256 "$ZIP"
fi
