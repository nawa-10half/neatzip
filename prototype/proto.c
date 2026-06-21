/* NeatZip 速度プロト: 最大リスク（minizip raw write + AES の両立）を実証する。
 *
 *   入力ファイル -> libdeflate で raw deflate 圧縮 -> minizip の raw entry に書き込み
 *   -> パスワード指定時は WinZip AES-256 で暗号化（パッチ済み minizip）。
 *
 * 使い方: proto <input> <output.zip> [password] [level] [entryname]
 *   password 省略時は無暗号（raw write 単体の健全性確認）。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "mz.h"
#include "mz_strm.h"
#include "mz_strm_os.h"
#include "mz_zip.h"
#include "libdeflate.h"

static unsigned char *read_file(const char *path, size_t *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror("fopen input"); return NULL; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(sz > 0 ? (size_t)sz : 1);
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) { perror("fread"); fclose(f); free(buf); return NULL; }
    fclose(f);
    *out_size = (size_t)sz;
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <input> <output.zip> [password] [level] [entryname]\n", argv[0]);
        return 2;
    }
    const char *in_path   = argv[1];
    const char *zip_path  = argv[2];
    const char *password  = (argc > 3 && argv[3][0]) ? argv[3] : NULL;
    int level             = (argc > 4) ? atoi(argv[4]) : 6;
    const char *entryname = (argc > 5) ? argv[5] : "payload.bin";

    size_t in_size = 0;
    unsigned char *in = read_file(in_path, &in_size);
    if (!in) return 1;

    /* --- libdeflate で raw deflate 圧縮 --- */
    struct libdeflate_compressor *c = libdeflate_alloc_compressor(level);
    if (!c) { fprintf(stderr, "alloc_compressor failed\n"); return 1; }
    size_t bound = libdeflate_deflate_compress_bound(c, in_size);
    unsigned char *out = malloc(bound ? bound : 1);
    size_t comp_size = libdeflate_deflate_compress(c, in, in_size, out, bound);
    uint32_t crc = libdeflate_crc32(0, in, in_size);
    libdeflate_free_compressor(c);

    int method;                 /* MZ_COMPRESS_METHOD_* */
    const unsigned char *payload;
    size_t payload_size;
    if (comp_size > 0 && comp_size < in_size) {
        method = MZ_COMPRESS_METHOD_DEFLATE;
        payload = out; payload_size = comp_size;
    } else {
        /* 非圧縮 or 膨張: store にフォールバック（raw で生データを書く） */
        method = MZ_COMPRESS_METHOD_STORE;
        payload = in; payload_size = in_size;
    }

    printf("[in] %s  %zu bytes\n", in_path, in_size);
    printf("[deflate] method=%s payload=%zu bytes (ratio %.1f%%) crc=0x%08x\n",
           method == MZ_COMPRESS_METHOD_DEFLATE ? "DEFLATE" : "STORE",
           payload_size, in_size ? 100.0 * payload_size / in_size : 0.0, crc);
    printf("[aes] %s\n", password ? "AES-256 (WinZip)" : "none");

    /* --- minizip: raw entry として書き込み --- */
    void *file_stream = mz_stream_os_create();
    int32_t err = mz_stream_os_open(file_stream, zip_path, MZ_OPEN_MODE_WRITE | MZ_OPEN_MODE_CREATE);
    if (err != MZ_OK) { fprintf(stderr, "stream open err=%d\n", err); return 1; }

    void *zip = mz_zip_create();
    err = mz_zip_open(zip, file_stream, MZ_OPEN_MODE_WRITE);
    if (err != MZ_OK) { fprintf(stderr, "zip open err=%d\n", err); return 1; }

    mz_zip_file fi;
    memset(&fi, 0, sizeof(fi));
    fi.version_madeby       = MZ_HOST_SYSTEM_UNIX << 8;
    fi.compression_method   = method;
    fi.modified_date        = time(NULL);
    fi.filename             = entryname;
    fi.uncompressed_size    = (int64_t)in_size;
    fi.compressed_size      = (int64_t)payload_size; /* AES 時は close で crypt total_out に上書きされる */
    fi.crc                  = crc;
    fi.flag                 = MZ_ZIP_FLAG_UTF8;
    fi.external_fa          = (uint32_t)0100644 << 16; /* regular file rw-r--r-- */
    if (password) {
        fi.flag        |= MZ_ZIP_FLAG_ENCRYPTED;
        fi.aes_version  = MZ_AES_VERSION;
        fi.aes_strength = MZ_AES_STRENGTH_256;
    }

    err = mz_zip_entry_write_open(zip, &fi, (int16_t)level, /*raw=*/1, password);
    if (err != MZ_OK) { fprintf(stderr, "entry_write_open err=%d\n", err); return 1; }

    int32_t written = mz_zip_entry_write(zip, payload, (int32_t)payload_size);
    if (written < 0) { fprintf(stderr, "entry_write err=%d\n", written); return 1; }

    err = mz_zip_entry_close_raw(zip, (int64_t)in_size, crc);
    if (err != MZ_OK) { fprintf(stderr, "entry_close_raw err=%d\n", err); return 1; }

    err = mz_zip_close(zip);
    if (err != MZ_OK) { fprintf(stderr, "zip_close err=%d\n", err); return 1; }
    mz_zip_delete(&zip);
    mz_stream_os_close(file_stream);
    mz_stream_os_delete(&file_stream);

    printf("[ok] wrote %s (entry compressed-on-disk size set by minizip)\n", zip_path);
    free(in); free(out);
    return 0;
}
