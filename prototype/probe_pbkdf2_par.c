/* PBKDF2 を並列化したときのスループットを測る（ファイル単位で独立なので並列可能）。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <CommonCrypto/CommonKeyDerivation.h>

static double now_s(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec+ts.tv_nsec/1e9; }

static int g_files; static volatile int g_next;
static void *worker(void *a){
    (void)a; const char *pw="hunter2"; uint8_t salt[16]={0}, key[66];
    for(;;){ int i=__atomic_fetch_add(&g_next,1,__ATOMIC_RELAXED); if(i>=g_files) break;
        salt[0]=(uint8_t)i; salt[1]=(uint8_t)(i>>8);
        CCKeyDerivationPBKDF(kCCPBKDF2, pw, strlen(pw), salt, sizeof(salt), kCCPRFHmacAlgSHA1, 1000, key, sizeof(key));
    }
    return NULL;
}
int main(int argc,char**argv){
    g_files=(argc>1)?atoi(argv[1]):2000;
    int T=(argc>2)?atoi(argv[2]):10;
    g_next=0;
    pthread_t th[64]; if(T>64)T=64;
    double t=now_s();
    for(int i=0;i<T;i++) pthread_create(&th[i],NULL,worker,NULL);
    for(int i=0;i<T;i++) pthread_join(th[i],NULL);
    double dt=now_s()-t;
    printf("PBKDF2 parallel x%d: %d files  %.3fs  (%.3f ms/file effective)\n", T, g_files, dt, dt*1000.0/g_files);
    return 0;
}
