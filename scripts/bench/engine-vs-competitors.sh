#!/bin/zsh
# deflate エンジン（zlib/libdeflate/並列 pigz）と zip 競合（zip/ditto=Finder相当）を横並び計測。
# NeatZip の「自前実装で何倍」「競合に何倍勝てる」を裏付ける数字を出す（DESIGN §5）。
#
#   実行: zsh scripts/bench/engine-vs-competitors.sh   （libdeflate/pigz は brew install を自動実行）
#
# 参考実測（2026-06-21, M系 10コア, 168MB 中圧縮）:
#   gzip(zlib single) 47MB/s / libdeflate(single) 158MB/s=3.3x / pigz(zlib x10) 308MB/s=6.5x
#   zip -r 45MB/s / ditto(Finder相当) 47MB/s  ← 競合は現状 NeatZip と横並び＝差別化ゼロ
set -euo pipefail
zmodload zsh/datetime

echo "▸ ツール準備 (libdeflate, pigz)..."
brew list libdeflate &>/dev/null || brew install libdeflate
brew list pigz &>/dev/null || brew install pigz

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/src"; mkdir -p "$SRC"

echo "▸ 中圧縮データ生成 (40×4MB base64(urandom))..."
for i in $(seq 1 40); do head -c $((3*1024*1024)) /dev/urandom | base64 > "$SRC/f$i.txt"; done
tar cf "$WORK/src.tar" -C "$SRC" .
BYTES=$(stat -f%z "$WORK/src.tar")
MB=$(( BYTES / 1000000.0 ))
CORES=$(sysctl -n hw.ncpu)
printf "  入力: %.1f MB / %d cores\n\n" $MB $CORES

run() {  # label  cmd...
  local label="$1"; shift
  local best=1e9 d out=""
  for _ in 1 2; do
    local s=$EPOCHREALTIME
    out=$(eval "$@" 2>/dev/null)
    d=$(( EPOCHREALTIME - s ))
    (( d < best )) && best=$d
  done
  printf "  %-28s %7.3f s   %7.1f MB/s\n" "$label" $best $(( MB / best ))
}

echo "── deflate エンジン速度（tar を圧縮 → /dev/null）──"
run "gzip (zlib, single)"        "gzip -6 -c '$WORK/src.tar' | wc -c"
run "libdeflate (single)"        "libdeflate-gzip -6 -c '$WORK/src.tar' | wc -c"
run "pigz (zlib, parallel x$CORES)" "pigz -6 -p $CORES -c '$WORK/src.tar' | wc -c"
echo "── zip コンテナ（競合：現状 NeatZip 相当）──"
run "zip -r (Info-ZIP, single)"  "rm -f '$WORK/o.zip'; zip -r -6 -q '$WORK/o.zip' '$SRC'; echo done"
run "ditto -c -k (Finder相当)"    "rm -f '$WORK/o2.zip'; ditto -c -k '$SRC' '$WORK/o2.zip'; echo done"
echo
echo "※ MB/s は入力 $(printf '%.0f' $MB)MB 基準。pigz は並列 deflate の実ツール裏取り、libdeflate はライブラリ差し替えゲイン。"
