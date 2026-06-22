#!/bin/zsh
# NeatZip をビルドして ~/Applications に反映するローカル開発用インストーラ。
#
# 開発中の「直したのに直らない」を防ぐのが目的（DESIGN.md §13）。LaunchServices に
# 複数の NeatZip.app コピーが登録されると古い実体が参照されるため、配布先 1 つに統一する。
# 署名は配布版と同じ作法（ad-hoc 署名 + Hardened Runtime）。Developer ID は配布時のみ。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="NeatZip"
INSTALL_DIR="$HOME/Applications"
DEST_APP="$INSTALL_DIR/$APP_NAME.app"
DERIVED="$ROOT/build/dd"
BUILT_APP="$DERIVED/Build/Products/Debug/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# LaunchServices に登録済みの NeatZip.app 実体パスを列挙する。
registered_neatzip_apps() { "$LSREGISTER" -dump 2>/dev/null | grep -oE '/[^ ]*/NeatZip\.app' | sort -u; }

echo "▸ 稼働中の NeatZip を終了..."
pkill -f "$DEST_APP" 2>/dev/null || true

echo "▸ プロジェクト生成 (xcodegen)..."
xcodegen generate >/dev/null

echo "▸ ビルド (ad-hoc 署名 + Hardened Runtime + LV 無効化)..."
# ad-hoc は TeamIdentifier を持たないため、Hardened Runtime の Library Validation が
# 同梱 Sparkle.framework(ad-hoc) のロードを拒否し起動時に dyld クラッシュする。dev 専用の
# scripts/dev.entitlements で Library Validation を無効化して本体を署名する（配布版は不要）。
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Debug \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--options runtime" \
  CODE_SIGN_ENTITLEMENTS="$ROOT/scripts/dev.entitlements" \
  ENABLE_DEBUG_DYLIB=NO \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  build >/dev/null

echo "▸ ~/Applications へ差し替え..."
mkdir -p "$INSTALL_DIR"
rm -rf "$DEST_APP"
cp -R "$BUILT_APP" "$DEST_APP"

# ビルド産物（build/dd 内の .app）は配布先へコピー済み。Spotlight/LaunchServices に重複表示
# されないよう産物だけ削除する（中間生成物は incremental ビルド用に温存）。
rm -rf "$BUILT_APP"

# 開発中に増えた全コピーを一旦登録解除し、配布先 1 つに統一する（DESIGN.md §13）。
# Xcode の DerivedData / ローカル derivedDataPath などの古い拡張がロードされるのを防ぐ。
echo "▸ 既存の全 NeatZip.app 登録を掃除..."
registered_neatzip_apps | while read -r p; do "$LSREGISTER" -u "$p" 2>/dev/null || true; done

echo "▸ 配布先のみ LaunchServices へ登録..."
"$LSREGISTER" -f "$DEST_APP"

echo "▸ Services を再登録（右クリックメニュー反映）..."
/System/Library/CoreServices/pbs -update 2>/dev/null || true

echo "▸ 署名と登録状況を確認..."
codesign -dv "$DEST_APP" 2>&1 | grep -iE 'Signature|flags' || true
echo "  登録されている NeatZip.app:"
registered_neatzip_apps | sed 's/^/    /'

echo "✅ 反映完了: $DEST_APP"
