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

// Verify a PKCS7 signature

#ifndef OPENVPN_OPENSSL_SIGN_PKCS7VERIFY_H
#define OPENVPN_OPENSSL_SIGN_PKCS7VERIFY_H

#include <string>

#include <openssl/ssl.h>
#include <openssl/bio.h>
#ifdef OPENSSL_IS_AWSLC
#include <openssl/evp.h>
#include <openssl/x509.h>
#else
#include <openssl/pkcs7.h>
#endif

#include <openvpn/common/cleanup.hpp>
#include <openvpn/common/numeric_cast.hpp>
#include <openvpn/openssl/pki/x509.hpp>
#include <openvpn/openssl/util/error.hpp>
#ifdef OPENSSL_IS_AWSLC
// AWS-LC PKCS7_verify compatibility wrapper
namespace {
    static inline int PKCS7_verify_compat(PKCS7 *p7, STACK_OF(X509) *certs, X509_STORE *store,
                                          BIO *indata, BIO *out, int flags) {
        // AWS-LC requires non-null X509_STORE for PKCS7_verify, create empty one if needed
        X509_STORE *local_store = store;
        int need_free = 0;
        
        if (!local_store) {
            local_store = X509_STORE_new();
            need_free = 1;
        }
        
        int result = PKCS7_verify(p7, certs, local_store, indata, out, flags);
        
        if (need_free) {
            X509_STORE_free(local_store);
        }
        
        return result;
    }
}
#endif

namespace openvpn::OpenSSLSign {
/*
 * Verify PKCS7 signature.
 * On success, return.
 * On fail, throw exception.
 */
inline void verify_pkcs7(const std::list<OpenSSLPKI::X509> &certs,
                         const std::string &sig,
                         const std::string &data)
{
    STACK_OF(X509) *x509_stack = nullptr;
    BIO *in = nullptr;
    PKCS7 *p7 = nullptr;

    auto clean = Cleanup([&]()
                         {
	  if (x509_stack)
	    sk_X509_free(x509_stack);
	  if (in)
	    BIO_free(in);
	  if (p7)
	    PKCS7_free(p7); });

    /* create x509_stack from cert */
    x509_stack = sk_X509_new_null();
    for (const auto &cert : certs)
        sk_X509_push(x509_stack, cert.obj());

    /* get signature */
    in = BIO_new_mem_buf(sig.c_str(), numeric_cast<int>(sig.length()));
    p7 = PEM_read_bio_PKCS7(in, NULL, NULL, NULL);
    if (!p7)
        throw OpenSSLException("OpenSSLSign::verify_pkcs7: failed to parse pkcs7 signature");
    BIO_free(in);
    in = nullptr;

    /* get data */
    in = BIO_new_mem_buf(data.c_str(), numeric_cast<int>(data.length()));

    /* OpenSSL 1.0.2e and higher no longer allows calling PKCS7_verify
       with both data and content.  Empty out the content if present.
       Just calling PKCS7_set_detached call lead to a null pointer access */
    if (!PKCS7_is_detached(p7))
        PKCS7_set_detached(p7, 1);

    /* do the verify */
#ifdef OPENSSL_IS_AWSLC
    if (PKCS7_verify_compat(p7, x509_stack, nullptr, in, nullptr, PKCS7_NOVERIFY) != 1)
#else
    if (PKCS7_verify(p7, x509_stack, nullptr, in, nullptr, PKCS7_NOVERIFY) != 1)
#endif
        throw OpenSSLException("OpenSSLSign::verify_pkcs7: verification failed");
}
} // namespace openvpn::OpenSSLSign

#endif
