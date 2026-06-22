#!/bin/zsh
# MAS（サンドボックス）版をローカルに署名インストールする検証用インストーラ（DESIGN §12）。
#
# 目的＝crux 実機検証: サンドボックスは「署名時のみ」強制されるので、署名済みの NeatZip-MAS を
# 入れて、Finder 右クリック（Services cleanZip:）/「開く」/ D&D で渡る選択ファイルを
# サンドボックス下で読めるか・保存パネル出力が通るかを確認する。GUI 自動化は不可なので
# 右クリック自体は手動（[[neatzip-project]] の検証作法）。
#
# 署名: ad-hoc（`-`）+ App/NeatZip-MAS.entitlements（app-sandbox + user-selected.read-write）。
#   MAS 版は Sparkle 非同梱なので install.sh の Library Validation 無効化（dev.entitlements）は不要。
#   Hardened Runtime は MAS では不要なので OFF（実 App Store 環境に近い・LV エッジを避ける）。
#
# 検証後に通常の dev ビルドへ戻すには scripts/install.sh を実行。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="NeatZip"
SCHEME="NeatZip-MAS"
INSTALL_DIR="$HOME/Applications"
DEST_APP="$INSTALL_DIR/$APP_NAME.app"
DERIVED="$ROOT/build/dd-mas"
BUILT_APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
ENTITLEMENTS="$ROOT/App/NeatZip-MAS.entitlements"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

registered_neatzip_apps() { "$LSREGISTER" -dump 2>/dev/null | grep -oE '/[^ ]*/NeatZip\.app' | sort -u; }

echo "▸ 稼働中の NeatZip を終了..."
pkill -f "$DEST_APP" 2>/dev/null || true

echo "▸ プロジェクト生成 (xcodegen)..."
xcodegen generate >/dev/null

echo "▸ ビルド (MAS / ad-hoc 署名 + App Sandbox・Hardened Runtime OFF)..."
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=NO \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  build >/dev/null

echo "▸ ~/Applications へ差し替え..."
mkdir -p "$INSTALL_DIR"
rm -rf "$DEST_APP"
cp -R "$BUILT_APP" "$DEST_APP"
rm -rf "$BUILT_APP"

echo "▸ 既存の全 NeatZip.app 登録を掃除（古い build/ コピー含む）..."
registered_neatzip_apps | while read -r p; do "$LSREGISTER" -u "$p" 2>/dev/null || true; done

echo "▸ MAS 版のみ LaunchServices へ登録..."
"$LSREGISTER" -f "$DEST_APP"

echo "▸ Services を再登録（右クリックメニュー反映）..."
/System/Library/CoreServices/pbs -update 2>/dev/null || true

echo "▸ サンドボックス entitlements を確認..."
codesign -d --entitlements - --xml "$DEST_APP" 2>/dev/null \
  | plutil -convert xml1 -o - - 2>/dev/null \
  | grep -A1 -E 'app-sandbox|user-selected' | sed 's/^/    /' || true
echo "  登録されている NeatZip.app:"; registered_neatzip_apps | sed 's/^/    /'

echo "✅ MAS 版インストール完了: $DEST_APP"
echo "   → Finder で Test/NeatZip-デモ などを右クリック →「Clean ZIP with NeatZip…」で検証。"
echo "   → 戻すには: zsh scripts/install.sh"
