#!/bin/zsh
# 出荷時の本番エンジン（CleanZip.make()）を Finder 相当(ditto) とヘッドツーヘッドで計測し、
# 見出し数字「対 Finder 何倍」を同一機・同一コーパスで取り直す（DESIGN.md §5 #11）。
#
#   実行: zsh scripts/bench/vs-finder.sh [corpus_dir]
#   corpus_dir 省略時は prototype/corpus を使う（無ければ gen_corpus.py で seed42 生成）。
#
# 参考実測（2026-06-21, 旧10コア機, 433.7MB/2060ファイル, 対 ditto）:
#   無AES 並列 563MB/s=16x / AES-256 並列 381MB/s=11x （プロト bench.c・end-to-end）
set -euo pipefail
zmodload zsh/datetime

ROOT="${0:A:h}/../.."          # リポジトリルート
CORPUS="${1:-$ROOT/prototype/corpus}"
PKG="$ROOT/Packages/CleanZipKit"
PW="benchpass"

# コーパスが無ければ決定論的に生成（seed42・~425MB/2060ファイル）。
if [[ ! -d "$CORPUS" ]] || [[ $(find "$CORPUS" -type f 2>/dev/null | wc -l) -lt 1 ]]; then
  echo "▸ コーパス生成 (seed42, ~425MB/2060ファイル)..."
  python3 "$ROOT/prototype/gen_corpus.py" "$CORPUS"
fi

echo "▸ CleanZipBench (release) ビルド..."
swift build --package-path "$PKG" -c release --product CleanZipBench >/dev/null
BENCH="$(swift build --package-path "$PKG" -c release --product CleanZipBench --show-bin-path)/CleanZipBench"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CORES=$(sysctl -n hw.ncpu)
CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model)
INMB=$(( $(find "$CORPUS" -type f -exec stat -f%z {} + | awk '{s+=$1} END{print s}') / 1000000.0 ))
NFILES=$(find "$CORPUS" -type f | wc -l | tr -d ' ')
printf "  コーパス: %.1f MB / %s ファイル / %d cores (%s)\n\n" $INMB "$NFILES" $CORES "$CHIP"

# ditto: best-of-2 の壁時計（秒）を返す。
ditto_time() {
  local best=1e9 s d out="$WORK/ditto.zip"
  for _ in 1 2; do
    rm -f "$out"
    s=$EPOCHREALTIME
    ditto -c -k "$CORPUS" "$out" 2>/dev/null
    d=$(( EPOCHREALTIME - s ))
    (( d < best )) && best=$d
  done
  print -- $best
}

# CleanZip.make(): best-of-2 の TIME=（CleanZipBench が出力）を返す。引数は追加フラグ（--aes pw 等）。
neat_time() {
  local best=1e9 t line
  for _ in 1 2; do
    line=$("$BENCH" --make "$CORPUS" "$WORK/neat.zip" "$@")
    t=${${(M)${(z)line}:#TIME=*}#TIME=}
    (( t < best )) && best=$t
  done
  print -- $best
}

echo "── 計測 (end-to-end 壁時計, best-of-2) ──"
DITTO=$(ditto_time)
NEAT=$(neat_time)
NEAT_AES=$(neat_time --aes "$PW")

row() { printf "  %-26s %7.3f s   %8.1f MB/s   %5.1fx\n" "$1" "$2" $(( INMB / $2 )) $(( DITTO / $2 )); }
printf "  %-26s %7.3f s   %8.1f MB/s   %5s\n" "ditto -c -k (Finder相当)" $DITTO $(( INMB / DITTO )) "1.0x"
row "NeatZip 既定 (無AES)" $NEAT
row "NeatZip AES-256" $NEAT_AES
echo
echo "※ 倍率は同一機・同一コーパスでの end-to-end 壁時計比（ditto=1.0x 基準）。"
