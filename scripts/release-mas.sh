#!/bin/zsh
# NeatZip の Mac App Store 版を archive → export(.pkg) して、アップロード可能な署名済み
# インストーラを作る。Developer ID 直配布は scripts/release.sh（別系統）。
#
# 設計: docs/DESIGN.md §12（MAS は App Sandbox 必須・Sparkle 非同梱・出力は保存パネル固定）。
# Developer ID 版が「元の隣にその場書き込み（Manual 署名・公証・Sparkle）」なのに対し、
# MAS 版は archive/export（automatic 署名）で .pkg を作り App Store Connect へ上げる二段構え。
#
# ── 一度だけの準備（あなたのアカウントで）───────────────────────────────────
#   1. Apple Developer Program 加入済み（$99/年）
#   2. Xcode に Account Holder の Apple ID をサインイン（Xcode → Settings → Accounts）。
#      automatic 署名が「Apple Distribution」証明書 と Mac App Store provisioning profile、
#      .pkg 用の「Mac Installer Distribution」証明書を -allowProvisioningUpdates で自動生成する。
#   3. App Store Connect で アプリレコードを作成（バンドルID app.neatzip.NeatZip を登録）。
#      ※ レコードが無くても archive/export と --validate-app までは通る場合があるが、
#         実アップロード（--upload-app）は ASC 側にレコードが必要。
#
# ── 使い方 ───────────────────────────────────────────────────────────────────
#   ./scripts/release-mas.sh                 # archive → export → build/mas/export/NeatZip.pkg
#   TEAM_ID=XXXXXXXXXX ./scripts/release-mas.sh   # チームID を明示（既定は証明書から自動検出）
#   SKIP_EXPORT=1 ./scripts/release-mas.sh    # archive まで（.xcarchive）で止める
#
#   アップロード（App Store Connect API キー方式・パスワード不要・任意）:
#     VALIDATE=1 ASC_KEY_ID=XXXX ASC_ISSUER_ID=xxxxxxxx-... ./scripts/release-mas.sh
#       → export 後に altool で検証だけ実行（アップロードはしない）
#     UPLOAD=1   ASC_KEY_ID=XXXX ASC_ISSUER_ID=xxxxxxxx-... ./scripts/release-mas.sh
#       → 検証 + 実アップロード。API キー(.p8)は ~/.appstoreconnect/private_keys/ か
#         ~/private_keys/ に AuthKey_<KEY_ID>.p8 として置くと altool が自動で見つける。
#         （App Store Connect → Users and Access → Integrations → App Store Connect API で発行）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="NeatZip"
SCHEME="NeatZip-MAS"
OUT="$ROOT/build/mas"
DERIVED="$OUT/dd"
ARCHIVE="$OUT/$SCHEME.xcarchive"
EXPORT_DIR="$OUT/export"
EXPORT_OPTS="$OUT/ExportOptions.plist"
PKG="$EXPORT_DIR/$APP_NAME.pkg"
VERSION="$(grep -E 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD_NUM="$(grep -E 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"

die() { print -r -- "❌ $*" >&2; exit 1; }

# ── チームID（env 優先・既定は Developer ID 証明書から自動検出）─────────────────
# ハードコードを避け、キーチェーンの証明書 CN 末尾 "(XXXXXXXXXX)" から導出する。
if [[ -z "${TEAM_ID:-}" ]]; then
  TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Developer ID Application' | sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/')"
fi
[[ -n "${TEAM_ID:-}" && "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
  || die "TEAM_ID を特定できません。例: TEAM_ID=XXXXXXXXXX ./scripts/release-mas.sh"

print -r -- "▸ MAS リリース: v$VERSION (build $BUILD_NUM) / Team $TEAM_ID / scheme $SCHEME"

# ── プロジェクト生成 ─────────────────────────────────────────────────────────
print -r -- "▸ プロジェクト生成 (xcodegen)..."
xcodegen generate >/dev/null

# ── archive（ユニバーサル・automatic 署名・プロビジョニング自動更新）────────────
# App Store では Hardened Runtime は署名時に無視される（project.yml の YES は無害）。
# CODE_SIGN_STYLE=Automatic + DEVELOPMENT_TEAM + -allowProvisioningUpdates で
# 証明書 / provisioning profile / App ID 登録を Xcode に任せる。
print -r -- "▸ archive（arm64 + x86_64・automatic 署名）..."
rm -rf "$ARCHIVE" "$DERIVED"
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO ENABLE_DEBUG_DYLIB=NO \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates
[[ -d "$ARCHIVE" ]] || die "archive が生成されませんでした: $ARCHIVE"
print -r -- "  $ARCHIVE"

if [[ "${SKIP_EXPORT:-0}" == "1" ]]; then
  print -r -- "⏭  SKIP_EXPORT=1 のため export はスキップ。"
  exit 0
fi

# ── ExportOptions.plist を生成（App Store・automatic）────────────────────────
# method=app-store-connect は Xcode 16+ の正式値（旧 app-store は非推奨）。
# teamID はハードコードせず実行時に注入（build/ は .gitignore 対象）。
mkdir -p "$EXPORT_DIR"
cat > "$EXPORT_OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>export</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>stripSwiftSymbols</key>
	<true/>
</dict>
</plist>
PLIST

# ── export（署名済み .pkg を生成）────────────────────────────────────────────
print -r -- "▸ export（App Store 署名済み .pkg を生成）..."
rm -f "$PKG"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates
[[ -f "$PKG" ]] || die "export 後に .pkg が見つかりません: $PKG（DistributionSummary.plist を確認）"
print -r -- "✅ 生成: $PKG"

# ── 任意: 検証 / アップロード（App Store Connect API キー方式）─────────────────
if [[ "${VALIDATE:-0}" == "1" || "${UPLOAD:-0}" == "1" ]]; then
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]] \
    || die "VALIDATE/UPLOAD には ASC_KEY_ID と ASC_ISSUER_ID が必要です（API キー方式）"
  print -r -- "▸ altool で検証（--validate-app）..."
  xcrun altool --validate-app -f "$PKG" -t macos \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
    || die "検証に失敗しました（上記メッセージの issues を修正）"
  if [[ "${UPLOAD:-0}" == "1" ]]; then
    print -r -- "▸ altool でアップロード（--upload-app）..."
    xcrun altool --upload-app -f "$PKG" -t macos \
      --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
      || die "アップロードに失敗しました"
    print -r -- "🎉 アップロード完了。App Store Connect の TestFlight/ビルド欄に反映されるまで数分待つ。"
  fi
else
  print -r -- ""
  print -r -- "▸ 次のいずれかでアップロード:"
  print -r -- "    (a) Transporter.app に $PKG をドラッグ"
  print -r -- "    (b) UPLOAD=1 ASC_KEY_ID=XXXX ASC_ISSUER_ID=xxxx-... ./scripts/release-mas.sh"
fi
