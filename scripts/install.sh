#!/bin/zsh
# NeatZip をビルドして ~/Applications に反映するローカル開発用インストーラ。
#
# 開発中の「直したのに直らない」を防ぐのが目的（DESIGN.md §13）。LaunchServices に
# 複数の NeatZip.app コピーが登録されると古い拡張がロードされるため、配布先 1 つに統一する。
# 署名は配布版と同じ作法（ad-hoc 署名 + Hardened Runtime）。Developer ID は配布時のみ。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="NeatZip"
EXT_ID="app.neatzip.NeatZip.FinderExtension"
INSTALL_DIR="$HOME/Applications"
DEST_APP="$INSTALL_DIR/$APP_NAME.app"
DERIVED="$ROOT/build/dd"
BUILT_APP="$DERIVED/Build/Products/Debug/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

echo "▸ 稼働中の NeatZip を終了..."
pkill -f "$DEST_APP" 2>/dev/null || true

echo "▸ プロジェクト生成 (xcodegen)..."
xcodegen generate >/dev/null

echo "▸ ビルド (ad-hoc 署名 + Hardened Runtime)..."
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Debug \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--options runtime" \
  ENABLE_DEBUG_DYLIB=NO \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  build >/dev/null

echo "▸ ~/Applications へ差し替え..."
mkdir -p "$INSTALL_DIR"
rm -rf "$DEST_APP"
cp -R "$BUILT_APP" "$DEST_APP"

# 開発中に増えた全コピーを一旦登録解除し、配布先 1 つに統一する（DESIGN.md §13）。
# Xcode の DerivedData / ローカル derivedDataPath などの古い拡張がロードされるのを防ぐ。
echo "▸ 既存の全 NeatZip.app 登録を掃除..."
"$LSREGISTER" -dump 2>/dev/null | grep -oE '/[^ ]*/NeatZip\.app' | sort -u \
  | while read -r p; do "$LSREGISTER" -u "$p" 2>/dev/null || true; done

echo "▸ 配布先のみ LaunchServices へ登録..."
"$LSREGISTER" -f "$DEST_APP"

echo "▸ Finder 拡張を有効化..."
pluginkit -e use -i "$EXT_ID" 2>/dev/null || true

echo "▸ 署名と登録状況を確認..."
codesign -dv "$DEST_APP" 2>&1 | grep -iE 'Signature|flags' || true
echo "  登録されている NeatZip.app:"
"$LSREGISTER" -dump 2>/dev/null | grep -oE '/[^ ]*/NeatZip\.app' | sort -u | sed 's/^/    /'

echo "✅ 反映完了: $DEST_APP"
