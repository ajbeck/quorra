// Quorra additions to OpenVPN. SPDX-License-Identifier: MPL-2.0
// AWS-LC does not enforce OpenSSL security levels. Apply a minimum policy
// to every certificate without overriding the TLS library's trust result.
#pragma once
#include <openssl/x509.h>
#include <openssl/evp.h>

namespace openvpn::QuorraCertificatePolicy {
inline bool accepts(X509 *certificate)
{
    if (!certificate)
        return false;
    EVP_PKEY *key = X509_get0_pubkey(certificate);
    if (!key)
        return false;
    const int kind = EVP_PKEY_id(key);
    const int bits = EVP_PKEY_bits(key);
    const bool strong_key = ((kind == EVP_PKEY_RSA || kind == EVP_PKEY_RSA_PSS) && bits >= 2048)
                            || (kind == EVP_PKEY_EC && bits >= 256)
                            || kind == EVP_PKEY_ED25519;
    int security_bits = 0;
    return strong_key
           && X509_get_signature_info(certificate, nullptr, nullptr, &security_bits, nullptr) == 1
           && security_bits >= 128;
}
}
