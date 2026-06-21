# prototype — 速度差別化エンジンの検証環境

NeatZip の「zip 互換のまま圧縮速度で差別化」方針（DESIGN.md §5 #11）を実証するための捨て検証環境。
**本番統合前のスクラッチ**であり、vendored 上流ソース・ビルド成果物・計測データは git 管理外。
追跡するのは自作ハーネス（`*.c` / `*.py`）と minizip パッチ（`minizip-ng.patch`）のみ。

## 依存（vendoring・再取得用）
- libdeflate **1.25**（upstream commit `b122c8b`）— 無改変
- minizip-ng **4.2.1**（upstream commit `d69cb0a`）— `minizip-ng.patch` を適用

```sh
mkdir -p vendor && cd vendor
git clone --depth 1 https://github.com/ebiggers/libdeflate.git
git clone --depth 1 https://github.com/zlib-ng/minizip-ng.git
git -C minizip-ng apply ../../minizip-ng.patch     # NeatZip パッチ適用
# libdeflate: cmake -B build -DCMAKE_BUILD_TYPE=Release -DLIBDEFLATE_BUILD_SHARED_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF && cmake --build build -j
# minizip-ng: cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
#   -DMZ_OPENSSL=OFF -DMZ_WZAES=ON -DMZ_ZLIB=ON -DMZ_BZIP2=OFF -DMZ_LZMA=OFF \
#   -DMZ_PPMD=OFF -DMZ_ZSTD=OFF -DMZ_LIBCOMP=OFF -DMZ_ICONV=OFF -DMZ_COMPAT=OFF \
#   -DMZ_BUILD_TESTS=OFF && cmake --build build -j
```
ビルド: `clang -O2 bench.c -I vendor/minizip-ng -I vendor/minizip-ng/build -I vendor/libdeflate \`
`vendor/minizip-ng/build/libminizip-ng.a vendor/libdeflate/build/libdeflate.a -lz -framework CoreFoundation -framework Security -o bench`

## ハーネス
- `proto.c` — 単一ファイルを「libdeflate raw deflate → minizip raw entry + AES」で zip 化（最大リスク撃破用）
- `bench.c` — ディレクトリツリーを single/parallel・任意 AES で zip 化し、圧縮/書き込みフェーズを分けて計測。
  `NEATZIP_INJECT=1`(既定) で並列導出鍵を注入（D案）、`=0` で minizip 内部 PBKDF2（逐次）
- `gen_corpus.py` — 再現可能な圧縮可能コーパス生成（seed 42）
- `probe_crypto.c` / `probe_pbkdf2.c` / `probe_pbkdf2_par.c` — CommonCrypto 単体・PBKDF2 の切り分け計測

## minizip-ng パッチ（`minizip-ng.patch`）
1. **raw write + AES の両立** — `mz_zip_entry_open_int` の「raw は暗号化しない」一行ゲートを外す
2. **CTR バルク化** — `mz_stream_wzaes_ctr_encrypt` を 64KB 一括 ECB ＋ ワード XOR に（出力不変）
3. **並列導出鍵の注入** — `mz_stream_wzaes_set_key` / `mz_zip_set_aes_key` を追加し、write の PBKDF2 を回避

## 実証結果（対 ditto / Finder Compress, 433.7MB/2060ファイル, 10コア）
| 方式 | end-to-end | 対 Finder |
|---|---|---|
| ditto（Finder Compress） | ~35 MB/s | 1.0x |
| 無AES 並列 | 563 MB/s | 16x |
| AES-256 並列（D案・鍵注入） | 381 MB/s | 11x |

全出力は `7z` / `unzip` で正当性確認済み（AES は 7z で全ファイルバイト一致・誤パス拒否）。
