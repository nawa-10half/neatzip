/* NeatZip: minizip-ng 4.2.1 の手書き設定ヘッダ（cmake 生成物の代替）。
   機能: ZLIB(deflate) + WinZip AES + PKCRYPT、暗号は Apple CommonCrypto(mz_crypt_apple.c)。
   BZIP2/LZMA/PPMD/ZSTD/LIBCOMP/COMPAT/ICONV/OpenSSL は無効（該当 .c を vendoring しない）。 */
#ifndef MZ_CONFIG_H
#define MZ_CONFIG_H

/* 圧縮・暗号バックエンド */
#define HAVE_ZLIB
#define HAVE_WZAES
#define HAVE_PKCRYPT

/* プラットフォーム（macOS / Apple Silicon・Intel） */
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_DIRENT_H 1
#define HAVE_SYS_DIRENT_H 1
#define HAVE_PDIR 1
#define HAVE_FSEEKO 1
#define HAVE_SYMLINK 1
#define HAVE_READLINK 1
#define HAVE_ARC4RANDOM_BUF 1

#endif /* MZ_CONFIG_H */
