//    OpenVPN -- An application to securely tunnel IP networks
//               over a single port, with support for SSL/TLS-based
//               session authentication and key exchange,
//               packet encryption, packet authentication, and
//               packet compression.
//
//    Copyright (C) 2012- OpenVPN Inc.
//
//    SPDX-License-Identifier: MPL-2.0 OR AGPL-3.0-only WITH openvpn3-openssl-exception
//

// Wrap the OpenSSL GCM API.

#pragma once

#include <string>

#include <openssl/objects.h>
#include <openssl/evp.h>

#include <openvpn/common/size.hpp>
#include <openvpn/common/exception.hpp>
#include <openvpn/common/likely.hpp>
#include <openvpn/crypto/static_key.hpp>
#include <openvpn/crypto/cryptoalgs.hpp>
#include <openvpn/crypto/aead_usage_limit.hpp>
#include <openvpn/openssl/util/error.hpp>
#ifdef OPENSSL_IS_AWSLC
// AWS-LC AEAD cipher compatibility wrappers to handle stricter parameter validation
namespace {
    static inline int EVP_EncryptUpdate_compat(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
                                               const unsigned char *in, int inl) {
        if (inl == 0 && in == nullptr) {
            static unsigned char empty_buf[1] = {0};
            return EVP_EncryptUpdate(ctx, out, outl, empty_buf, 0);
        }
        return EVP_EncryptUpdate(ctx, out, outl, in, inl);
    }
    static inline int EVP_DecryptUpdate_compat(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
                                               const unsigned char *in, int inl) {
        if (inl == 0 && in == nullptr) {
            static unsigned char empty_buf[1] = {0};
            return EVP_DecryptUpdate(ctx, out, outl, empty_buf, 0);
        }
        return EVP_DecryptUpdate(ctx, out, outl, in, inl);
    }
}
#endif

namespace openvpn::OpenSSLCrypto {
class CipherContextAEAD
{
    /* In OpenSSL 3.0 the method that returns EVP_CIPHER, the cipher needs to be
     * freed afterwards, thus needing a non-const type. In contrast, OpenSSL 1.1.1
     * and lower returns a const type, needing a const type */
#if OPENSSL_VERSION_NUMBER < 0x30000000L
    using evp_cipher_type = const EVP_CIPHER;
#else
    using evp_cipher_type = EVP_CIPHER;
#endif
#ifdef OPENSSL_IS_AWSLC
    // AWS-LC: Direct cipher functions return static const pointers, no cleanup needed
    using cipher_ptr = const EVP_CIPHER*;
#else
    using CIPHER_unique_ptr = std::unique_ptr<evp_cipher_type, decltype(&::EVP_CIPHER_free)>;
#endif

  public:
    CipherContextAEAD(const CipherContextAEAD &) = delete;
    CipherContextAEAD &operator=(const CipherContextAEAD &) = delete;

    CipherContextAEAD(CipherContextAEAD &&other) noexcept
        : ctx(std::exchange(other.ctx, nullptr)), aead_usage_limit_(other.aead_usage_limit_)
    {
    }

    CipherContextAEAD &operator=(CipherContextAEAD &&other)
    {
        CipherContextAEAD temp(std::move(other));
        std::swap(ctx, temp.ctx);
        std::swap(aead_usage_limit_, other.aead_usage_limit_);
        return *this;
    }

    OPENVPN_EXCEPTION(openssl_gcm_error);

    // mode parameter for constructor
    enum
    {
        MODE_UNDEF = -1,
        ENCRYPT = 1,
        DECRYPT = 0
    };

    // OpenSSL cipher constants
    enum : size_t
    {
        IV_LEN = 12,
        AUTH_TAG_LEN = 16
    };

    bool constexpr requires_authtag_at_end()
    {
        return false;
    }

    CipherContextAEAD() = default;

    ~CipherContextAEAD()
    {
        free_cipher_context();
    }

    void init(SSLLib::Ctx libctx,
              const CryptoAlgs::Type alg,
              const unsigned char *key,
              const unsigned int keysize,
              const int mode)
    {
        free_cipher_context();
        unsigned int ckeysz = 0;

#ifdef OPENSSL_IS_AWSLC
        const EVP_CIPHER *ciph = cipher_type(alg, ckeysz);
#else
        CIPHER_unique_ptr ciph(cipher_type(libctx, alg, ckeysz), EVP_CIPHER_free);
#endif
        if (!ciph)
            OPENVPN_THROW(openssl_gcm_error, CryptoAlgs::name(alg) << ": not usable");

        if (ckeysz > keysize)
            throw openssl_gcm_error("insufficient key material");
        ctx = EVP_CIPHER_CTX_new();
        EVP_CIPHER_CTX_reset(ctx);
        switch (mode)
        {
        case ENCRYPT:
#ifdef OPENSSL_IS_AWSLC
            if (!EVP_EncryptInit_ex(ctx, ciph, nullptr, key, nullptr))
#else
            if (!EVP_EncryptInit_ex(ctx, ciph.get(), nullptr, key, nullptr))
#endif
            {
                openssl_clear_error_stack();
                free_cipher_context();
                throw openssl_gcm_error("EVP_EncryptInit_ex (init)");
            }
            break;
        case DECRYPT:
#ifdef OPENSSL_IS_AWSLC
            if (!EVP_DecryptInit_ex(ctx, ciph, nullptr, key, nullptr))
#else
            if (!EVP_DecryptInit_ex(ctx, ciph.get(), nullptr, key, nullptr))
#endif
            {
                openssl_clear_error_stack();
                free_cipher_context();
                throw openssl_gcm_error("EVP_DecryptInit_ex (init)");
            }
            break;
        default:
            throw openssl_gcm_error("bad mode");
        }
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, IV_LEN, nullptr) != 1)
        {
            openssl_clear_error_stack();
            free_cipher_context();
            throw openssl_gcm_error("EVP_CIPHER_CTX_ctrl set IV len");
        }
        aead_usage_limit_ = {alg};
    }

    void encrypt(const unsigned char *input,
                 unsigned char *output,
                 size_t length,
                 const unsigned char *iv,
                 unsigned char *tag,
                 const unsigned char *ad,
                 size_t ad_len)
    {
        int len;
        int ciphertext_len;

        check_initialized();
        if (!EVP_EncryptInit_ex(ctx, nullptr, nullptr, nullptr, iv))
        {
            openssl_clear_error_stack();
            throw openssl_gcm_error("EVP_EncryptInit_ex (reset)");
        }
#ifdef OPENSSL_IS_AWSLC
        if (!EVP_EncryptUpdate_compat(ctx, nullptr, &len, ad, int(ad_len)))
#else
        if (!EVP_EncryptUpdate(ctx, nullptr, &len, ad, int(ad_len)))
#endif
        {
            openssl_clear_error_stack();
            throw openssl_gcm_error("EVP_EncryptUpdate AD");
        }
#ifdef OPENSSL_IS_AWSLC
        if (!EVP_EncryptUpdate_compat(ctx, output, &len, input, int(length)))
#else
        if (!EVP_EncryptUpdate(ctx, output, &len, input, int(length)))
#endif
        {
            openssl_clear_error_stack();
            throw openssl_gcm_error("EVP_EncryptUpdate data");
        }
        ciphertext_len = len;
        if (!EVP_EncryptFinal_ex(ctx, output + len, &len))
        {
            openssl_clear_error_stack();
            throw openssl_gcm_error("EVP_EncryptFinal_ex");
        }
        ciphertext_len += len;
        if ((size_t)ciphertext_len != length)
        {
            throw openssl_gcm_error("encrypt size inconsistency");
        }
        if (!EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, AUTH_TAG_LEN, tag))
        {
            openssl_clear_error_stack();
            throw openssl_gcm_error("EVP_CIPHER_CTX_ctrl get tag");
        }
        aead_usage_limit_.update(length + ad_len);
    }


    /** Returns the AEAD usage limit associated with this AEAD cipher instance to check the limits */
    [[nodiscard]] const Crypto::AEADUsageLimit &get_usage_limit()
    {
        return aead_usage_limit_;
    }


    /**
     * Decrypts AEAD encrypted data. Note that if tag is the nullptr the tag is assumed to be
     * part of input and at the end of the input. The length parameter of input includes the tag in
     * this case
     *
     * @param input     Input data to decrypt
     * @param output    Where decrypted data will be written to
     * @param iv        IV of the encrypted data.
     * @param length    length the of the data, this includes the tag at the end if tag is not a nullptr.
     * @param ad        start of the additional data
     * @param ad_len    length of the additional data
     * @param tag       location of the tag to use or nullptr if at the end of the input
     */
    bool decrypt(const unsigned char *input,
                 unsigned char *output,
                 size_t length,
                 const unsigned char *iv,
                 const unsigned char *tag,
                 const unsigned char *ad,
                 size_t ad_len)
    {
        if (!tag)
        {
            /* Tag is at the end of input, check that input is large enough to hold the tag */
            if (length < AUTH_TAG_LEN)
            {
                throw openssl_gcm_error("decrypt input length too short");
            }

            length = length - AUTH_TAG_LEN;
            tag = input + length;
        }

        check_initialized();
        if (!EVP_DecryptInit_ex(ctx, nullptr, nullptr, nullptr, iv))
        {
            openssl_clear_error_stack();
            throw openssl_gcm_error("EVP_DecryptInit_ex (reset)");
        }

        int len;
#ifdef OPENSSL_IS_AWSLC
        if (!EVP_DecryptUpdate_compat(ctx, nullptr, &len, ad, int(ad_len)))
#else
        if (!EVP_DecryptUpdate(ctx, nullptr, &len, ad, int(ad_len)))
#endif
        {
            openssl_clear_error_stack();
            throw openssl_gcm_error("EVP_DecryptUpdate AD");
        }
#ifdef OPENSSL_IS_AWSLC
        if (!EVP_DecryptUpdate_compat(ctx, output, &len, input, int(length)))
#else
        if (!EVP_DecryptUpdate(ctx, output, &len, input, int(length)))
#endif
        {
            openssl_clear_error_stack();
            throw openssl_gcm_error("EVP_DecryptUpdate data");
        }

        int plaintext_len = len;
        /** This API of OpenSSL does not modify the tag it is given but the function signature always expects
         * a modifiable tag, so we have to const cast it to get around this restriction */
        if (!EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, AUTH_TAG_LEN, const_cast<unsigned char *>(tag)))
        {
            openssl_clear_error_stack();
            throw openssl_gcm_error("EVP_CIPHER_CTX_ctrl set tag");
        }
        if (!EVP_DecryptFinal_ex(ctx, output + len, &len))
        {
            openssl_clear_error_stack();
            return false;
        }
        plaintext_len += len;
        if (static_cast<size_t>(plaintext_len) != length)
        {
            throw openssl_gcm_error("decrypt size inconsistency");
        }
        return true;
    }

    bool is_initialized() const
    {
        return ctx != nullptr;
    }

    static bool is_supported(SSLLib::Ctx libctx, const CryptoAlgs::Type alg)
    {
#ifdef OPENSSL_IS_AWSLC
        unsigned int keysize = 0;
        return cipher_type(alg, keysize) != nullptr;
#else
        unsigned int keysize = 0;
        CIPHER_unique_ptr cipher(cipher_type(libctx, alg, keysize), EVP_CIPHER_free);
        return (bool)cipher;
#endif
    }


  private:
#ifdef OPENSSL_IS_AWSLC
    // AWS-LC: Simplified cipher_type function returning static pointers
    static const EVP_CIPHER *cipher_type(const CryptoAlgs::Type alg, unsigned int &keysize)
    {
        switch (alg)
        {
        case CryptoAlgs::AES_128_GCM:
            keysize = 16;
            return EVP_aes_128_gcm();
        case CryptoAlgs::AES_192_GCM:
            keysize = 24;
            return EVP_aes_192_gcm();
        case CryptoAlgs::AES_256_GCM:
            keysize = 32;
            return EVP_aes_256_gcm();
        case CryptoAlgs::CHACHA20_POLY1305:
            keysize = 32;
            return EVP_chacha20_poly1305();
        default:
            keysize = 0;
            return nullptr;
        }
    }
#else
    static evp_cipher_type *cipher_type(SSLLib::Ctx libctx,
                                        const CryptoAlgs::Type alg,
                                        unsigned int &keysize)
    {
        switch (alg)
        {
        case CryptoAlgs::AES_128_GCM:
            keysize = 16;
            return EVP_CIPHER_fetch(libctx, "AES-128-GCM", nullptr);
        case CryptoAlgs::AES_192_GCM:
            keysize = 24;
            return EVP_CIPHER_fetch(libctx, "AES-192-GCM", nullptr);
        case CryptoAlgs::AES_256_GCM:
            keysize = 32;
            return EVP_CIPHER_fetch(libctx, "AES-256-GCM", nullptr);
        case CryptoAlgs::CHACHA20_POLY1305:
            keysize = 32;
            return EVP_CIPHER_fetch(libctx, "CHACHA20-POLY1305", nullptr);
        default:
            keysize = 0;
            return nullptr;
        }
    }
#endif

    void free_cipher_context()
    {
        EVP_CIPHER_CTX_free(ctx);
        ctx = nullptr;
    }

    void check_initialized() const
    {
#ifdef OPENVPN_ENABLE_ASSERT
        if (!ctx)
            throw openssl_gcm_error("uninitialized");
#endif
    }

    EVP_CIPHER_CTX *ctx = nullptr;
    Crypto::AEADUsageLimit aead_usage_limit_ = {};
};
} // namespace openvpn::OpenSSLCrypto
