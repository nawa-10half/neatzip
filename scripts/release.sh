#!/bin/zsh
# NeatZip を Developer ID で配布用にビルド→署名→公証→ステープルし、配布 .dmg を作る。
# （Mac App Store 版ではない。MAS は将来 §12 / 別ビルド分岐で対応）
#
# ── 一度だけの準備（あなたのアカウントで） ───────────────────────────────
#   1. Apple Developer Program に加入（$99/年）
#   2. 「Developer ID Application」証明書を作成し、ログイン キーチェーンに入れる
#        確認: security find-identity -v -p codesigning | grep "Developer ID Application"
#   3. 公証用の認証情報をキーチェーンに保存（App 用パスワードは appleid.apple.com で発行）:
#        xcrun notarytool store-credentials neatzip-notary \
#          --apple-id "<APPLE_ID>" --team-id "<TEAM_ID>" --password "<APP_SPECIFIC_PW>"
#
# ── 使い方 ───────────────────────────────────────────────────────────────
#   TEAM_ID=XXXXXXXXXX ./scripts/release.sh
#   （任意）SIGN_ID="Developer ID Application: Your Name (XXXXXXXXXX)" で証明書を明示
#   （任意）NOTARY_PROFILE=neatzip-notary  公証プロファイル名（既定 neatzip-notary）
#   （任意）SKIP_NOTARIZE=1  署名と .dmg 作成までで止める（公証はしない＝動作確認用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="NeatZip"
SCHEME="NeatZip"
SIGN_ID="${SIGN_ID:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-neatzip-notary}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
DERIVED="$ROOT/build/release-dd"
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DIST="$ROOT/build/dist"
VERSION="$(grep -E 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

die() { print -r -- "❌ $*" >&2; exit 1; }

# ── プリフライト ──────────────────────────────────────────────────────────
[[ -n "${TEAM_ID:-}" ]] || die "TEAM_ID が未設定です。例: TEAM_ID=XXXXXXXXXX ./scripts/release.sh"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  die "キーチェーンに「Developer ID Application」証明書がありません（準備 step 2 を実施）"
fi
print -r -- "▸ バージョン $VERSION / Team $TEAM_ID / 署名 '$SIGN_ID'"

# ── ビルド + 署名（Hardened Runtime + secure timestamp、分離 dylib は無効）──
print -r -- "▸ Release ビルド + Developer ID 署名..."
rm -rf "$DERIVED"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_ID" DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  ENABLE_DEBUG_DYLIB=NO PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build >/dev/null
[[ -d "$APP" ]] || die "ビルド成果物が見つかりません: $APP"

# ── Sparkle のネスト XPC/ヘルパーを Developer ID + Hardened Runtime で再署名 ──
# xcodebuild の build 経路（archive/export を使わない）は Sparkle.framework 本体は
# 署名し直すが、内部の XPCServices/ヘルパーは ad-hoc 署名のまま残る。このままだと
# 公証で「nested code は Developer ID + hardened runtime で署名されていない」と弾かれる。
# Sparkle 公式手順どおり内側→外側へ手で署名する（--deep は使わない・§10）。
SPK="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPK" ]]; then
  print -r -- "▸ Sparkle のネストコンポーネントを再署名..."
  V="$SPK/Versions/$(readlink "$SPK/Versions/Current")"   # 通常 B（バージョン記号に依存しない）
  codesign -f -s "$SIGN_ID" --timestamp -o runtime "$V/XPCServices/Installer.xpc"
  # Downloader.xpc はサンドボックス＋ネットワーク権限を持つので entitlements を保持する
  codesign -f -s "$SIGN_ID" --timestamp -o runtime --preserve-metadata=entitlements "$V/XPCServices/Downloader.xpc"
  codesign -f -s "$SIGN_ID" --timestamp -o runtime "$V/Autoupdate"
  codesign -f -s "$SIGN_ID" --timestamp -o runtime "$V/Updater.app"
  codesign -f -s "$SIGN_ID" --timestamp -o runtime "$SPK"
  # ネストを差し替えたので本体の封印（CodeResources）を再計算する。--deep は使わず本体のみ。
  # 明示 entitlements は無いので get-task-allow は注入されない（§10 の落とし穴対策と整合）。
  codesign -f -s "$SIGN_ID" --timestamp -o runtime "$APP"
fi

# ── 署名検証（本体・ネスト全体が Developer ID + hardened か）────────────────
print -r -- "▸ 署名を検証..."
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
codesign -dv --verbose=4 "$APP" 2>&1 | grep -iE 'Authority=Developer ID|flags=.*runtime' | head -2 \
  || die "本体が Developer ID + hardened runtime で署名されていません"

# ── 配布 .dmg を作る（/Applications シンボリックリンク同梱）──────────────────
print -r -- "▸ .dmg を作成..."
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$SIGN_ID" --timestamp --identifier "app.neatzip.NeatZip.dmg" "$DMG"
print -r -- "  $DMG"

if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  print -r -- "⏭  SKIP_NOTARIZE=1 のため公証はスキップ。配布前に必ず公証してください。"
  exit 0
fi

# ── 公証 + ステープル ──────────────────────────────────────────────────────
print -r -- "▸ 公証を申請（notarytool・完了まで待機）..."
# 注意: notarytool submit --wait は status が Invalid でも exit 0 を返すため、出力で判定する。
SUBMIT_OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
print -r -- "$SUBMIT_OUT"
SUB_ID="$(print -r -- "$SUBMIT_OUT" | awk '/id:/{print $2; exit}')"
if ! print -r -- "$SUBMIT_OUT" | grep -q "status: Accepted"; then
  [[ -n "$SUB_ID" ]] && xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | head -40
  die "公証が通りませんでした（上記ログの issues を修正）"
fi
print -r -- "▸ ステープル..."
xcrun stapler staple "$DMG" || die "ステープル失敗"

# ── 最終検証（Gatekeeper 評価）─────────────────────────────────────────────
print -r -- "▸ Gatekeeper 評価..."
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | tail -2 || true
xcrun stapler validate "$DMG" && print -r -- "✅ 配布物の公証・ステープル OK"

# ── Sparkle appcast を生成（EdDSA 署名つき）─────────────────────────────────
# 秘密鍵は Keychain（一度だけ `generate_keys` で生成済み）。配布 .dmg を updates フォルダに
# 集約し、generate_appcast が各更新に EdDSA 署名を付けて appcast.xml を出力する。
# 配信は GitHub Releases:
#   ・enclosure(dmg) URL は当該バージョンのタグ付きアセット URL（DOWNLOAD_URL_PREFIX）。
#     remote から owner/repo を自動導出し v$VERSION を既定にする（環境変数で上書き可）。
#   ・appcast.xml は dmg と一緒に Release アセットとしてアップロードする（SUFeedURL=
#     .../releases/latest/download/appcast.xml が常に最新を指す）。
#   ・SKIP_APPCAST=1 でこの工程だけ省略可。
# owner/repo を remote URL から導出（BSD sed 互換: 遅延量指定子を使わず2段で）。
REPO_SLUG="$(git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
DEFAULT_PREFIX="${REPO_SLUG:+https://github.com/$REPO_SLUG/releases/download/v$VERSION/}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-$DEFAULT_PREFIX}"
GEN_APPCAST="$(find "$DERIVED/SourcePackages/artifacts" -name generate_appcast -type f 2>/dev/null | head -1)"
if [[ "${SKIP_APPCAST:-0}" != "1" && -n "$GEN_APPCAST" ]]; then
  print -r -- "▸ appcast を生成（enclosure 接頭辞: ${DOWNLOAD_URL_PREFIX:-未設定}）..."
  UPDATES="$DIST/updates"
  mkdir -p "$UPDATES"
  cp -f "$DMG" "$UPDATES/"
  # 過去バージョンの dmg も $UPDATES に置いておくと累積 appcast を再生成できる（履歴を残す）。
  # zsh はクォート無しのパラメータ展開を単語分割しないため、任意オプションは配列で渡す
  # （関数外なので local は使わない）。
  PREFIX_ARG=()
  [[ -n "${DOWNLOAD_URL_PREFIX:-}" ]] && PREFIX_ARG=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
  "$GEN_APPCAST" "${PREFIX_ARG[@]}" "$UPDATES"
  if [[ -f "$UPDATES/appcast.xml" ]]; then
    cp -f "$UPDATES/appcast.xml" "$DIST/appcast.xml"
    print -r -- "  $DIST/appcast.xml"
    [[ -z "${DOWNLOAD_URL_PREFIX:-}" ]] && \
      print -r -- "  ⚠️ DOWNLOAD_URL_PREFIX 未設定のため enclosure URL は暫定（remote 未検出）。"
  fi
elif [[ -z "$GEN_APPCAST" ]]; then
  print -r -- "⏭  generate_appcast が見つからないため appcast 生成はスキップ。"
fi

print -r -- "🎉 完成: $DMG"
# ── 公開（GitHub Release を作成して dmg + appcast.xml をアップロード）────────
# 公証済み dmg と appcast.xml を v$VERSION タグの Release として公開する（手動実行）:
if [[ -f "$DIST/appcast.xml" ]]; then
  print -r -- "▸ 次のコマンドで公開（タグ v$VERSION の Release を作成）:"
  print -r -- "    gh release create v$VERSION \"$DMG\" \"$DIST/appcast.xml\" \\"
  print -r -- "      --repo ${REPO_SLUG:-<owner/repo>} --title \"NeatZip $VERSION\" --notes \"...\""
fi
