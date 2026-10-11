#import "include/QuorraOpenVPNTestSupport.h"
#include "../../Sources/QuorraOpenVPNNative/CoreSupport.hpp"
#include <openvpn/frame/frame_init.hpp>

BOOL QVPNTestTLSHandshake(NSString *profile, NSString *serverCertificate, NSString *serverKey)
{
    using namespace openvpn;
    try {
        InitProcess::Init init;
        ClientAPI::Config input;
        if (!quorra::profileConfig(profile, input)) return NO;
        OptionList options;
        options.parse_from_config(input.content, nullptr);
        options.update_map();
        OpenSSLContext::Config::Ptr clientConfig = new OpenSSLContext::Config;
        clientConfig->set_local_cert_enabled(false);
        clientConfig->load(options, SSLConfigAPI::LF_PARSE_MODE);
        clientConfig->set_tls_version_min_override(input.tlsVersionMinOverride);
        clientConfig->set_tls_cert_profile_override(input.tlsCertProfileOverride);
        clientConfig->set_tls_cipher_list(input.tlsCipherList);
        clientConfig->set_tls_ciphersuite_list(input.tlsCiphersuitesList);
        clientConfig->set_frame(frame_init_simple(4096));

        OpenSSLContext::Config::Ptr serverConfig = new OpenSSLContext::Config;
        serverConfig->set_mode(Mode(Mode::SERVER));
        // This synthetic server accepts the certificate-less SAML client. The
        // client verifier remains the production verifier with no trust exception.
        serverConfig->set_flags(SSLConst::NO_VERIFY_PEER);
        serverConfig->load_cert([serverCertificate UTF8String]);
        serverConfig->load_private_key([serverKey UTF8String]);
        serverConfig->set_frame(frame_init_simple(4096));
        auto clientFactory = clientConfig->new_factory(), serverFactory = serverConfig->new_factory();
        auto client = clientFactory->ssl(), server = serverFactory->ssl();
        client->start_handshake(); server->start_handshake();
        bool sent = false;
        for (int i = 0; i < 100; ++i) {
            while (client->read_ciphertext_ready()) server->write_ciphertext(client->read_ciphertext());
            while (server->read_ciphertext_ready()) client->write_ciphertext(server->read_ciphertext());
            unsigned char byte = 0;
            client->read_cleartext(&byte, 1);
            if (!sent) sent = client->write_cleartext_unbuffered("X", 1) == 1;
            if (server->read_cleartext(&byte, 1) == 1) return sent && byte == 'X';
        }
    } catch (...) {}
    return NO;
}
