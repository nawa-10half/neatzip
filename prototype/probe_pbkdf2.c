/* PBKDF2 ボトルネック検証: CommonCrypto native CCKeyDerivationPBKDF の速度を測る。
 * minizip 手書き PBKDF2 は小2000ファイルで ~0.89ms/file だった。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <CommonCrypto/CommonKeyDerivation.h>

static double now_s(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec+ts.tv_nsec/1e9; }

int main(int argc, char **argv){
    int files = (argc>1)? atoi(argv[1]) : 2000;
    const char *pw = "hunter2";
    uint8_t salt[16] = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16};
    uint8_t key[66];
    double t = now_s();
    for (int i = 0; i < files; i++) {
        salt[0] = (uint8_t)i;            /* ファイルごとに salt が変わる想定 */
        CCKeyDerivationPBKDF(kCCPBKDF2, pw, strlen(pw), salt, sizeof(salt),
                             kCCPRFHmacAlgSHA1, 1000, key, sizeof(key));
    }
    double dt = now_s() - t;
    printf("CCKeyDerivationPBKDF native: %d files  %.3fs  (%.3f ms/file)\n",
           files, dt, dt*1000.0/files);
    printf("  vs minizip 手書き ~0.89 ms/file\n");
    return 0;
}
