/* NeatZip 速度ベンチ: ディレクトリツリーを libdeflate 圧縮 → minizip raw write でzip化。
 * single / parallel（ファイル間並列）を切替、任意で WinZip AES-256。
 * 圧縮フェーズと書き込みフェーズの壁時計を分けて計測する（I/O 込み・実ゲイン確認）。
 *
 * usage: bench <dir> <out.zip> <single|parallel> [password|-] [level] [threads]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dirent.h>
#include <sys/stat.h>
#include <pthread.h>

#include <CommonCrypto/CommonKeyDerivation.h>

#include "mz.h"
#include "mz_strm.h"
#include "mz_strm_os.h"
#include "mz_zip.h"
#include "libdeflate.h"

#define AES_SALT_LEN 16          /* AES-256 */
#define AES_KBUF_LEN 66          /* [aes_key32 | hmac_key32 | verify2] */

typedef struct {
    char *abspath;
    char *relpath;
    int64_t usize;          /* uncompressed size */
    unsigned char *payload; /* deflate 出力 or（store時）生バイト */
    size_t psize;
    int method;             /* MZ_COMPRESS_METHOD_* */
    uint32_t crc;
    uint8_t salt[AES_SALT_LEN]; /* AES: 並列phaseで生成 */
    uint8_t kbuf[AES_KBUF_LEN]; /* AES: 並列phaseで PBKDF2 導出 */
} entry_t;

static const char *g_password = NULL; /* AES 有効時のパスワード */
static int g_inject = 1;              /* 1=並列導出鍵を minizip に注入(D案) / 0=minizip 内部 PBKDF2(逐次) */

static entry_t *g_entries = NULL;
static size_t g_count = 0, g_cap = 0;
static size_t g_rootlen = 0;
static int g_level = 6;

static double now_s(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int is_junk(const char *name) {
    return strcmp(name, ".DS_Store") == 0 ||
           strcmp(name, "__MACOSX") == 0 ||
           (name[0] == '.' && name[1] == '_');
}

static void add_entry(const char *abspath, int64_t size) {
    if (g_count == g_cap) {
        g_cap = g_cap ? g_cap * 2 : 1024;
        g_entries = realloc(g_entries, g_cap * sizeof(entry_t));
    }
    entry_t *e = &g_entries[g_count++];
    memset(e, 0, sizeof(*e));
    e->abspath = strdup(abspath);
    e->relpath = strdup(abspath + g_rootlen); /* ルート直下からの相対 */
    e->usize = size;
}

static void walk(const char *dir) {
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *de;
    char path[4096];
    while ((de = readdir(d))) {
        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
        if (is_junk(de->d_name)) continue;
        snprintf(path, sizeof(path), "%s/%s", dir, de->d_name);
        struct stat st;
        if (lstat(path, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) walk(path);
        else if (S_ISREG(st.st_mode)) add_entry(path, st.st_size);
    }
    closedir(d);
}

/* 1ファイルを読んで圧縮（スレッドごとに自前 compressor を渡す） */
static void compress_one(entry_t *e, struct libdeflate_compressor *c) {
    FILE *f = fopen(e->abspath, "rb");
    if (!f) { e->method = MZ_COMPRESS_METHOD_STORE; e->payload = calloc(1,1); e->psize = 0; return; }
    unsigned char *in = malloc(e->usize ? (size_t)e->usize : 1);
    size_t rd = fread(in, 1, (size_t)e->usize, f);
    fclose(f);
    e->usize = (int64_t)rd;
    e->crc = libdeflate_crc32(0, in, rd);
    size_t bound = libdeflate_deflate_compress_bound(c, rd);
    unsigned char *out = malloc(bound ? bound : 1);
    size_t clen = libdeflate_deflate_compress(c, in, rd, out, bound);
    if (clen > 0 && clen < rd) {
        e->method = MZ_COMPRESS_METHOD_DEFLATE; e->payload = out; e->psize = clen; free(in);
    } else {
        e->method = MZ_COMPRESS_METHOD_STORE; e->payload = in; e->psize = rd; free(out);
    }

    /* AES(D案): 並列phaseで salt 生成 + PBKDF2 鍵導出（逐次の write からこの高コストを追い出す） */
    if (g_password && g_inject) {
        arc4random_buf(e->salt, AES_SALT_LEN);
        CCKeyDerivationPBKDF(kCCPBKDF2, g_password, strlen(g_password),
                             e->salt, AES_SALT_LEN, kCCPRFHmacAlgSHA1,
                             1000, e->kbuf, AES_KBUF_LEN);
    }
}

/* --- parallel: スレッドプール + アトミック索引 --- */
static volatile size_t g_next = 0;
static void *worker(void *arg) {
    (void)arg;
    struct libdeflate_compressor *c = libdeflate_alloc_compressor(g_level);
    for (;;) {
        size_t i = __atomic_fetch_add(&g_next, 1, __ATOMIC_RELAXED);
        if (i >= g_count) break;
        compress_one(&g_entries[i], c);
    }
    libdeflate_free_compressor(c);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <dir> <out.zip> <single|parallel> [password|-] [level] [threads]\n", argv[0]);
        return 2;
    }
    const char *dir = argv[1];
    const char *zip_path = argv[2];
    int parallel = strcmp(argv[3], "parallel") == 0;
    const char *password = (argc > 4 && strcmp(argv[4], "-") != 0 && argv[4][0]) ? argv[4] : NULL;
    g_level = (argc > 5) ? atoi(argv[5]) : 6;
    int threads = (argc > 6) ? atoi(argv[6]) : 10;
    g_password = password;
    { const char *e = getenv("NEATZIP_INJECT"); if (e) g_inject = atoi(e); } /* 既定 1=注入 */

    g_rootlen = strlen(dir) + 1; /* "dir/" を剥がす */

    double t0 = now_s();
    walk(dir);
    double t_walk = now_s() - t0;

    int64_t total_in = 0;
    for (size_t i = 0; i < g_count; i++) total_in += g_entries[i].usize;

    /* --- 圧縮フェーズ --- */
    double t1 = now_s();
    if (parallel) {
        g_next = 0;
        pthread_t th[64];
        if (threads > 64) threads = 64;
        for (int i = 0; i < threads; i++) pthread_create(&th[i], NULL, worker, NULL);
        for (int i = 0; i < threads; i++) pthread_join(th[i], NULL);
    } else {
        struct libdeflate_compressor *c = libdeflate_alloc_compressor(g_level);
        for (size_t i = 0; i < g_count; i++) compress_one(&g_entries[i], c);
        libdeflate_free_compressor(c);
    }
    double t_comp = now_s() - t1;

    /* --- 書き込みフェーズ（順次 raw write）--- */
    double t2 = now_s();
    void *fs = mz_stream_os_create();
    if (mz_stream_os_open(fs, zip_path, MZ_OPEN_MODE_WRITE | MZ_OPEN_MODE_CREATE) != MZ_OK) {
        fprintf(stderr, "stream open failed\n"); return 1;
    }
    void *zip = mz_zip_create();
    mz_zip_open(zip, fs, MZ_OPEN_MODE_WRITE);
    time_t mtime = time(NULL);
    for (size_t i = 0; i < g_count; i++) {
        entry_t *e = &g_entries[i];
        mz_zip_file fi; memset(&fi, 0, sizeof(fi));
        fi.version_madeby = MZ_HOST_SYSTEM_UNIX << 8;
        fi.compression_method = e->method;
        fi.modified_date = mtime;
        fi.filename = e->relpath;
        fi.uncompressed_size = e->usize;
        fi.compressed_size = (int64_t)e->psize;
        fi.crc = e->crc;
        fi.flag = MZ_ZIP_FLAG_UTF8;
        fi.external_fa = (uint32_t)0100644 << 16;
        if (password) { fi.flag |= MZ_ZIP_FLAG_ENCRYPTED; fi.aes_version = MZ_AES_VERSION; fi.aes_strength = MZ_AES_STRENGTH_256; }
        /* AES(D案): 並列導出済みの鍵を注入 → このエントリの PBKDF2 を minizip がスキップ */
        if (password && g_inject)
            mz_zip_set_aes_key(zip, e->salt, AES_SALT_LEN, e->kbuf, AES_KBUF_LEN);
        if (mz_zip_entry_write_open(zip, &fi, (int16_t)g_level, 1, password) != MZ_OK) {
            fprintf(stderr, "write_open failed at %s\n", e->relpath); return 1;
        }
        if (e->psize > 0) mz_zip_entry_write(zip, e->payload, (int32_t)e->psize);
        mz_zip_entry_close_raw(zip, e->usize, e->crc);
    }
    mz_zip_close(zip);
    mz_zip_delete(&zip);
    mz_stream_os_close(fs);
    mz_stream_os_delete(&fs);
    double t_write = now_s() - t2;
    double t_total = now_s() - t0;

    struct stat zst; stat(zip_path, &zst);
    double in_mb = total_in / 1024.0 / 1024.0;

    printf("mode=%-8s threads=%-2d aes=%-3s level=%d\n",
           parallel ? "parallel" : "single", parallel ? threads : 1,
           password ? "yes" : "no", g_level);
    printf("  files=%zu  in=%.1f MB  zip=%.1f MB  ratio=%.1f%%\n",
           g_count, in_mb, zst.st_size / 1024.0 / 1024.0,
           total_in ? 100.0 * zst.st_size / total_in : 0.0);
    printf("  walk=%.3fs  compress=%.3fs  write=%.3fs  TOTAL=%.3fs\n",
           t_walk, t_comp, t_write, t_total);
    printf("  >> compress-phase = %.0f MB/s   |   end-to-end = %.0f MB/s\n",
           in_mb / t_comp, in_mb / t_total);
    return 0;
}
