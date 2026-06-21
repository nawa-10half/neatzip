/* AES ボトルネックの切り分け: CommonCrypto 単体の AES-256-CTR / HMAC-SHA1 スループットを測る。
 * minizip の wzaes 書き込みが ~100MB/s だったのが「CommonCrypto の素の上限」か
 * 「minizip ストリームのオーバーヘッド」かを判定する。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <CommonCrypto/CommonCrypto.h>

static double now_s(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec+ts.tv_nsec/1e9; }

int main(int argc, char **argv){
    size_t MB = (argc>1)? (size_t)atoi(argv[1]) : 200;
    size_t n = MB*1024*1024;
    unsigned char *in = malloc(n), *out = malloc(n);
    memset(in, 0xA5, n);
    unsigned char key[32]={0}, iv[16]={0}, mac[CC_SHA1_DIGEST_LENGTH];
    double mbf = n/1024.0/1024.0;

    /* AES-256-CTR のみ */
    {
        CCCryptorRef cr;
        CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding,
                                iv, key, 32, NULL, 0, 0, kCCModeOptionCTR_BE, &cr);
        size_t moved=0;
        double t=now_s();
        CCCryptorUpdate(cr, in, n, out, n, &moved);
        double dt=now_s()-t;
        CCCryptorRelease(cr);
        printf("AES-256-CTR        : %.0f MB/s  (%.3fs)\n", mbf/dt, dt);
    }
    /* HMAC-SHA1 のみ（WinZip AES は SHA1 を 80bit に切詰めて使用）*/
    {
        double t=now_s();
        CCHmac(kCCHmacAlgSHA1, key, sizeof(key), out, n, mac);
        double dt=now_s()-t;
        printf("HMAC-SHA1          : %.0f MB/s  (%.3fs)\n", mbf/dt, dt);
    }
    /* AES-CTR + HMAC-SHA1（WinZip AES の暗号化実体に相当・逐次）*/
    {
        CCCryptorRef cr;
        CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding,
                                iv, key, 32, NULL, 0, 0, kCCModeOptionCTR_BE, &cr);
        size_t moved=0;
        double t=now_s();
        CCCryptorUpdate(cr, in, n, out, n, &moved);
        CCHmac(kCCHmacAlgSHA1, key, sizeof(key), out, n, mac);
        double dt=now_s()-t;
        CCCryptorRelease(cr);
        printf("AES-CTR + HMAC-SHA1: %.0f MB/s  (%.3fs)  <- WinZip AES 1スレッド理論上限\n", mbf/dt, dt);
    }
    free(in); free(out);
    return 0;
}
