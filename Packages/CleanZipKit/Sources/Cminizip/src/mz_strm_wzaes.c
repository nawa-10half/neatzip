/* mz_strm_wzaes.c -- Stream for WinZip AES encryption
   part of the minizip-ng project

   Copyright (C) Nathan Moinvaziri
      https://github.com/zlib-ng/minizip-ng
   Copyright (C) 1998-2010 Brian Gladman, Worcester, UK

   This program is distributed under the terms of the same license as zlib.
   See the accompanying LICENSE file for the full text of the license.
*/

#include "mz.h"
#include "mz_crypt.h"
#include "mz_strm.h"
#include "mz_strm_wzaes.h"

/***************************************************************************/

#define MZ_AES_KEY_LENGTH(STRENGTH)  (8 * (STRENGTH & 3) + 8)
#define MZ_AES_KEYING_ITERATIONS     (1000)
#define MZ_AES_SALT_LENGTH(STRENGTH) (4 * (STRENGTH & 3) + 4)
#define MZ_AES_SALT_LENGTH_MAX       (16)
#define MZ_AES_PW_LENGTH_MAX         (128)
#define MZ_AES_PW_VERIFY_SIZE        (2)
#define MZ_AES_AUTHCODE_SIZE         (10)

/***************************************************************************/

static mz_stream_vtbl mz_stream_wzaes_vtbl = {
    mz_stream_wzaes_open,   mz_stream_wzaes_is_open, mz_stream_wzaes_read,           mz_stream_wzaes_write,
    mz_stream_wzaes_tell,   mz_stream_wzaes_seek,    mz_stream_wzaes_close,          mz_stream_wzaes_error,
    mz_stream_wzaes_create, mz_stream_wzaes_delete,  mz_stream_wzaes_get_prop_int64, mz_stream_wzaes_set_prop_int64};

/***************************************************************************/

typedef struct mz_stream_wzaes_s {
    mz_stream stream;
    int32_t mode;
    int32_t error;
    int16_t initialized;
    uint8_t buffer[UINT16_MAX];
    int64_t total_in;
    int64_t max_total_in;
    int64_t total_out;
    uint8_t strength;
    const char *password;
    void *aes;
    uint32_t crypt_pos;
    uint8_t crypt_block[MZ_AES_BLOCK_SIZE];
    void *hmac;
    uint8_t nonce[MZ_AES_BLOCK_SIZE];
    uint8_t keystream[UINT16_MAX]; /* NeatZip PATCH: バルク CTR 用キーストリームバッファ */
    /* NeatZip PATCH: 並列phaseで導出済みの salt+鍵を注入し、write時の rand+PBKDF2 を回避する */
    uint8_t has_injected_key;
    uint16_t injected_salt_length;
    uint8_t injected_salt[MZ_AES_SALT_LENGTH_MAX];
    uint16_t injected_kbuf_length;
    uint8_t injected_kbuf[2 * MZ_AES_KEY_LENGTH_MAX + MZ_AES_PW_VERIFY_SIZE];
} mz_stream_wzaes;

/***************************************************************************/

int32_t mz_stream_wzaes_open(void *stream, const char *path, int32_t mode) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    uint16_t salt_length = 0;
    uint16_t password_length = 0;
    uint16_t key_length = 0;
    uint8_t kbuf[2 * MZ_AES_KEY_LENGTH_MAX + MZ_AES_PW_VERIFY_SIZE];
    uint8_t verify[MZ_AES_PW_VERIFY_SIZE];
    uint8_t verify_expected[MZ_AES_PW_VERIFY_SIZE];
    uint8_t salt_value[MZ_AES_SALT_LENGTH_MAX];
    const char *password = path;

    wzaes->total_in = 0;
    wzaes->total_out = 0;
    wzaes->initialized = 0;

    if (mz_stream_is_open(wzaes->stream.base) != MZ_OK)
        return MZ_OPEN_ERROR;

    if (!password)
        password = wzaes->password;
    if (!password)
        return MZ_PARAM_ERROR;
    password_length = (uint16_t)strlen(password);
    if (password_length > MZ_AES_PW_LENGTH_MAX)
        return MZ_PARAM_ERROR;

    if (wzaes->strength < 1 || wzaes->strength > 3)
        return MZ_PARAM_ERROR;

    key_length = MZ_AES_KEY_LENGTH(wzaes->strength);
    salt_length = MZ_AES_SALT_LENGTH(wzaes->strength);

    if (mode & MZ_OPEN_MODE_WRITE) {
        /* NeatZip PATCH: 注入鍵があれば salt も並列phaseで生成済みのものを使う */
        if (wzaes->has_injected_key) {
            salt_length = wzaes->injected_salt_length;
            memcpy(salt_value, wzaes->injected_salt, salt_length);
        } else {
            mz_crypt_rand(salt_value, salt_length);
        }
    } else if (mode & MZ_OPEN_MODE_READ) {
        if (mz_stream_read(wzaes->stream.base, salt_value, salt_length) != salt_length)
            return MZ_READ_ERROR;
    }

    /* Derive the encryption and authentication keys and the password verifier */
    if ((mode & MZ_OPEN_MODE_WRITE) && wzaes->has_injected_key) {
        /* NeatZip PATCH: 並列phaseで導出済みの鍵を流用し、逐次の高コストな PBKDF2(1000反復) を省く */
        memcpy(kbuf, wzaes->injected_kbuf, 2 * key_length + MZ_AES_PW_VERIFY_SIZE);
    } else {
        mz_crypt_pbkdf2((uint8_t *)password, password_length, salt_value, salt_length, MZ_AES_KEYING_ITERATIONS, kbuf,
                        2 * key_length + MZ_AES_PW_VERIFY_SIZE);
    }

    /* Initialize the buffer pos */
    wzaes->crypt_pos = MZ_AES_BLOCK_SIZE;

    /* Use fixed zeroed IV/nonce for CTR mode */
    memset(wzaes->nonce, 0, sizeof(wzaes->nonce));

    /* Initialize for encryption using key 1 */
    mz_crypt_aes_reset(wzaes->aes);
    mz_crypt_aes_set_encrypt_key(wzaes->aes, kbuf, key_length, NULL, 0);

    /* Initialize for authentication using key 2 */
    mz_crypt_hmac_reset(wzaes->hmac);
    mz_crypt_hmac_set_algorithm(wzaes->hmac, MZ_HASH_SHA1);
    mz_crypt_hmac_init(wzaes->hmac, kbuf + key_length, key_length);

    memcpy(verify, kbuf + (2 * key_length), MZ_AES_PW_VERIFY_SIZE);

    if (mode & MZ_OPEN_MODE_WRITE) {
        if (mz_stream_write(wzaes->stream.base, salt_value, salt_length) != salt_length)
            return MZ_WRITE_ERROR;

        wzaes->total_out += salt_length;

        if (mz_stream_write(wzaes->stream.base, verify, MZ_AES_PW_VERIFY_SIZE) != MZ_AES_PW_VERIFY_SIZE)
            return MZ_WRITE_ERROR;

        wzaes->total_out += MZ_AES_PW_VERIFY_SIZE;
    } else if (mode & MZ_OPEN_MODE_READ) {
        wzaes->total_in += salt_length;

        if (mz_stream_read(wzaes->stream.base, verify_expected, MZ_AES_PW_VERIFY_SIZE) != MZ_AES_PW_VERIFY_SIZE)
            return MZ_READ_ERROR;

        wzaes->total_in += MZ_AES_PW_VERIFY_SIZE;

        if (memcmp(verify_expected, verify, MZ_AES_PW_VERIFY_SIZE) != 0)
            return MZ_PASSWORD_ERROR;
    }

    wzaes->mode = mode;
    wzaes->initialized = 1;

    return MZ_OK;
}

int32_t mz_stream_wzaes_is_open(void *stream) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    if (!wzaes->initialized)
        return MZ_OPEN_ERROR;
    return MZ_OK;
}

/* NeatZip PATCH: CTR キーストリーム生成を 16 バイト毎の ECB 呼び出しから
   「チャンク分を 1 回の ECB でバルク生成 → 8 バイト単位 XOR」へ置換。
   カウンタ列・各カウンタの ECB 結果・XOR は従来と完全に同一なので、
   出力バイト列は stock 実装とビット単位で一致する（7z 互換を担保）。
   元実装は 207MB で約1300万回の CCCryptorUpdate を呼び ~100MB/s に律速していた。 */
static int32_t mz_stream_wzaes_ctr_encrypt(void *stream, uint8_t *buf, int32_t size) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    uint32_t pos = wzaes->crypt_pos;
    int32_t i = 0;

    if (size < 0)
        return MZ_PARAM_ERROR;

    /* 1. 直前ブロックの残りキーストリームを消費 */
    while (i < size && pos < MZ_AES_BLOCK_SIZE)
        buf[i++] ^= wzaes->crypt_block[pos++];

    /* 2. フルブロックをバルク処理 */
    while (size - i >= MZ_AES_BLOCK_SIZE) {
        int32_t remain_blocks = (size - i) / MZ_AES_BLOCK_SIZE;
        int32_t batch_blocks = (int32_t)(sizeof(wzaes->keystream) / MZ_AES_BLOCK_SIZE);
        int32_t ks_len, k, b;
        uint8_t *ks = wzaes->keystream;

        if (batch_blocks > remain_blocks)
            batch_blocks = remain_blocks;
        ks_len = batch_blocks * MZ_AES_BLOCK_SIZE;

        /* カウンタを進めつつ nonce をキーストリーム入力に並べる（挙動は従来と同一） */
        for (b = 0; b < batch_blocks; b++) {
            uint32_t j = 0;
            while (j < 8 && !++wzaes->nonce[j])
                j += 1;
            memcpy(ks + b * MZ_AES_BLOCK_SIZE, wzaes->nonce, MZ_AES_BLOCK_SIZE);
        }

        /* ks をまとめて 1 回で ECB 暗号化 */
        if (mz_crypt_aes_encrypt(wzaes->aes, NULL, 0, ks, ks_len) != ks_len)
            return MZ_CRYPT_ERROR;

        /* buf ^= ks（8 バイト単位、端数はバイト単位） */
        for (k = 0; k + 8 <= ks_len; k += 8) {
            uint64_t a, c;
            memcpy(&a, buf + i + k, 8);
            memcpy(&c, ks + k, 8);
            a ^= c;
            memcpy(buf + i + k, &a, 8);
        }
        for (; k < ks_len; k++)
            buf[i + k] ^= ks[k];

        i += ks_len;
        pos = MZ_AES_BLOCK_SIZE; /* バルク末尾はブロック境界 */
    }

    /* 3. 末尾の半端ブロック */
    if (i < size) {
        uint32_t j = 0;
        while (j < 8 && !++wzaes->nonce[j])
            j += 1;
        memcpy(wzaes->crypt_block, wzaes->nonce, MZ_AES_BLOCK_SIZE);
        if (mz_crypt_aes_encrypt(wzaes->aes, NULL, 0, wzaes->crypt_block, MZ_AES_BLOCK_SIZE) != MZ_AES_BLOCK_SIZE)
            return MZ_CRYPT_ERROR;
        pos = 0;
        while (i < size)
            buf[i++] ^= wzaes->crypt_block[pos++];
    }

    wzaes->crypt_pos = pos;
    return MZ_OK;
}

int32_t mz_stream_wzaes_read(void *stream, void *buf, int32_t size) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    int64_t max_total_in = 0;
    int32_t bytes_to_read = size;
    int32_t read = 0;

    max_total_in = wzaes->max_total_in - MZ_AES_FOOTER_SIZE;
    if ((int64_t)bytes_to_read > (max_total_in - wzaes->total_in))
        bytes_to_read = (int32_t)(max_total_in - wzaes->total_in);

    read = mz_stream_read(wzaes->stream.base, buf, bytes_to_read);

    if (read > 0) {
        mz_crypt_hmac_update(wzaes->hmac, (uint8_t *)buf, read);
        mz_stream_wzaes_ctr_encrypt(stream, (uint8_t *)buf, read);

        wzaes->total_in += read;
    }

    return read;
}

int32_t mz_stream_wzaes_write(void *stream, const void *buf, int32_t size) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    const uint8_t *buf_ptr = (const uint8_t *)buf;
    int32_t bytes_to_write = sizeof(wzaes->buffer);
    int32_t total_written = 0;
    int32_t written = 0;

    if (size < 0)
        return MZ_PARAM_ERROR;

    do {
        if (bytes_to_write > (size - total_written))
            bytes_to_write = (size - total_written);

        memcpy(wzaes->buffer, buf_ptr, bytes_to_write);
        buf_ptr += bytes_to_write;

        mz_stream_wzaes_ctr_encrypt(stream, (uint8_t *)wzaes->buffer, bytes_to_write);
        mz_crypt_hmac_update(wzaes->hmac, wzaes->buffer, bytes_to_write);

        written = mz_stream_write(wzaes->stream.base, wzaes->buffer, bytes_to_write);
        if (written < 0)
            return written;

        total_written += written;
    } while (total_written < size && written > 0);

    wzaes->total_out += total_written;
    return total_written;
}

int64_t mz_stream_wzaes_tell(void *stream) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    return mz_stream_tell(wzaes->stream.base);
}

int32_t mz_stream_wzaes_seek(void *stream, int64_t offset, int32_t origin) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    return mz_stream_seek(wzaes->stream.base, offset, origin);
}

int32_t mz_stream_wzaes_close(void *stream) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    uint8_t expected_hash[MZ_AES_AUTHCODE_SIZE];
    uint8_t computed_hash[MZ_HASH_SHA1_SIZE];

    mz_crypt_hmac_end(wzaes->hmac, computed_hash, sizeof(computed_hash));

    if (wzaes->mode & MZ_OPEN_MODE_WRITE) {
        if (mz_stream_write(wzaes->stream.base, computed_hash, MZ_AES_AUTHCODE_SIZE) != MZ_AES_AUTHCODE_SIZE)
            return MZ_WRITE_ERROR;

        wzaes->total_out += MZ_AES_AUTHCODE_SIZE;
    } else if (wzaes->mode & MZ_OPEN_MODE_READ) {
        if (mz_stream_read(wzaes->stream.base, expected_hash, MZ_AES_AUTHCODE_SIZE) != MZ_AES_AUTHCODE_SIZE)
            return MZ_READ_ERROR;

        wzaes->total_in += MZ_AES_AUTHCODE_SIZE;

        /* If entire entry was not read this will fail */
        if (memcmp(computed_hash, expected_hash, MZ_AES_AUTHCODE_SIZE) != 0)
            return MZ_CRC_ERROR;
    }

    wzaes->initialized = 0;
    return MZ_OK;
}

int32_t mz_stream_wzaes_error(void *stream) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    return wzaes->error;
}

void mz_stream_wzaes_set_password(void *stream, const char *password) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    wzaes->password = password;
}

void mz_stream_wzaes_set_strength(void *stream, uint8_t strength) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    wzaes->strength = strength;
}

/* NeatZip PATCH: 並列phaseで導出済みの salt と鍵素材(kbuf=[aes_key|hmac_key|verify]) を注入する。
   注入があると open(write) は rand+PBKDF2 をスキップして逐次コストを排する。 */
int32_t mz_stream_wzaes_set_key(void *stream, const uint8_t *salt, uint16_t salt_length, const uint8_t *kbuf,
                                uint16_t kbuf_length) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    if (!wzaes || !salt || !kbuf)
        return MZ_PARAM_ERROR;
    if (salt_length > sizeof(wzaes->injected_salt) || kbuf_length > sizeof(wzaes->injected_kbuf))
        return MZ_PARAM_ERROR;
    memcpy(wzaes->injected_salt, salt, salt_length);
    wzaes->injected_salt_length = salt_length;
    memcpy(wzaes->injected_kbuf, kbuf, kbuf_length);
    wzaes->injected_kbuf_length = kbuf_length;
    wzaes->has_injected_key = 1;
    return MZ_OK;
}

int32_t mz_stream_wzaes_get_prop_int64(void *stream, int32_t prop, int64_t *value) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    switch (prop) {
    case MZ_STREAM_PROP_TOTAL_IN:
        *value = wzaes->total_in;
        break;
    case MZ_STREAM_PROP_TOTAL_OUT:
        *value = wzaes->total_out;
        break;
    case MZ_STREAM_PROP_TOTAL_IN_MAX:
        *value = wzaes->max_total_in;
        break;
    case MZ_STREAM_PROP_HEADER_SIZE:
        *value = MZ_AES_SALT_LENGTH((int64_t)wzaes->strength) + MZ_AES_PW_VERIFY_SIZE;
        break;
    case MZ_STREAM_PROP_FOOTER_SIZE:
        *value = MZ_AES_AUTHCODE_SIZE;
        break;
    default:
        return MZ_EXIST_ERROR;
    }
    return MZ_OK;
}

int32_t mz_stream_wzaes_set_prop_int64(void *stream, int32_t prop, int64_t value) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    switch (prop) {
    case MZ_STREAM_PROP_TOTAL_IN_MAX:
        wzaes->max_total_in = value;
        break;
    default:
        return MZ_EXIST_ERROR;
    }
    return MZ_OK;
}

void *mz_stream_wzaes_create(void) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)calloc(1, sizeof(mz_stream_wzaes));
    if (wzaes) {
        wzaes->stream.vtbl = &mz_stream_wzaes_vtbl;
        wzaes->strength = MZ_AES_STRENGTH_256;

        wzaes->hmac = mz_crypt_hmac_create();
        if (!wzaes->hmac) {
            free(wzaes);
            return NULL;
        }
        wzaes->aes = mz_crypt_aes_create();
        if (!wzaes->aes) {
            mz_crypt_hmac_delete(&wzaes->hmac);
            free(wzaes);
            return NULL;
        }
    }
    return wzaes;
}

void mz_stream_wzaes_delete(void **stream) {
    mz_stream_wzaes *wzaes = NULL;
    if (!stream)
        return;
    wzaes = (mz_stream_wzaes *)*stream;
    if (wzaes) {
        mz_crypt_aes_delete(&wzaes->aes);
        mz_crypt_hmac_delete(&wzaes->hmac);
        free(wzaes);
    }
    *stream = NULL;
}

void *mz_stream_wzaes_get_interface(void) {
    return (void *)&mz_stream_wzaes_vtbl;
}
