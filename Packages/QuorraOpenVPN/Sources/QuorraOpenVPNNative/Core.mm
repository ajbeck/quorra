#include "CoreSupport.hpp"

@implementation QVPNChallenge
- (instancetype)initWithURL:(NSURL *)url cookie:(NSData *)cookie
{
    if ((self = [super init])) { _url = [url copy]; _cookie = [cookie copy]; }
    return self;
}
- (NSString *)description { return @"VPN authentication challenge (redacted)"; }
- (NSString *)debugDescription { return self.description; }
@end

@implementation QVPNCredentials {
    openvpn::ClientAPI::ProvideCreds _credentials;
}
- (instancetype)initPrivate { return [super init]; }
+ (instancetype)challenge:(NSData *)cookie response:(NSData *)response
{
    if (!cookie.length || !response.length || cookie.length > 8192
        || response.length > quorra::maximumCredential - cookie.length)
        return nil;
    if (![QVPNCore parseChallenge:cookie])
        return nil;
    QVPNCredentials *result = [[QVPNCredentials alloc] initPrivate];
    result->_credentials.dynamicChallengeCookie = quorra::bytes(cookie);
    result->_credentials.response = quorra::bytes(response);
    if (result->_credentials.response.find('\0') != std::string::npos)
        return nil;
    return result;
}
+ (instancetype)cachedUsername:(NSData *)username token:(NSData *)token
{
    if (!username.length || !token.length || username.length > 4096
        || token.length > quorra::maximumCredential - username.length)
        return nil;
    QVPNCredentials *result = [[QVPNCredentials alloc] initPrivate];
    result->_credentials.username = quorra::bytes(username);
    result->_credentials.password = quorra::bytes(token);
    if (result->_credentials.username.find('\0') != std::string::npos || result->_credentials.password.find('\0') != std::string::npos)
        return nil;
    return result;
}
- (openvpn::ClientAPI::ProvideCreds)coreCredentials { return _credentials; }
- (NSString *)description { return @"VPN credentials (redacted)"; }
- (NSString *)debugDescription { return self.description; }
@end

namespace quorra {
bool profileConfig(NSString *profile, openvpn::ClientAPI::Config &config)
{
    NSData *encoded = [profile dataUsingEncoding:NSUTF8StringEncoding];
    if (!encoded.length || encoded.length > 65536)
        return false;
    const auto text = bytes(encoded);
    if (text.find('\0') != std::string::npos)
        return false;
    openvpn::OptionList options;
    options.parse_from_config(text, nullptr);
    options.update_map();
    const std::set<std::string> allowed = {
        "client", "dev", "proto", "remote", "resolv-retry", "nobind", "remote-cert-tls",
        "cipher", "verb", "ca", "auth-user-pass", "auth-federate", "auth-retry",
        "auth-nocache", "reneg-sec", "verify-x509-name", "tls-version-min",
    };
    std::set<std::string> seen;
    for (const auto &option : options)
    {
        if (option.empty() || !allowed.count(option.ref(0)) || !seen.insert(option.ref(0)).second)
            return false;
        if (option.ref(0) != "ca" && option.render(0).size() > 1024)
            return false;
    }
    auto exact = [&](const char *name, const char *value) {
        const auto *option = options.get_ptr(name);
        return option && option->size() == 2 && option->ref(1) == value;
    };
    const auto *ca = options.get_ptr("ca");
    const auto *remote = options.get_ptr("remote");
    const auto *auth = options.get_ptr("auth-user-pass");
    if (!options.exists("client") || !exact("dev", "tun") || !exact("remote-cert-tls", "server")
        || !auth || auth->size() != 1 || !ca || ca->size() != 2
        || ca->ref(1).find("-----BEGIN CERTIFICATE-----") == std::string::npos
        || !remote || remote->size() != 3 || remote->ref(1).empty() || remote->ref(1).size() > 253)
        return false;
    for (unsigned char c : remote->ref(1))
        if (!(std::isalnum(c) || c == '.' || c == '-' || c == ':'))
            return false;
    if (!(exact("proto", "udp") || exact("proto", "udp4") || exact("proto", "udp6") || exact("proto", "tcp-client")))
        return false;
    if (options.exists("tls-version-min") && !(exact("tls-version-min", "1.2") || exact("tls-version-min", "1.3")))
        return false;
    config.content = text + "\nignore-unknown-option auth-federate\n";
    config.disableClientCert = true;
    config.tlsVersionMinOverride = exact("tls-version-min", "1.3") ? "tls_1_3" : "tls_1_2";
    config.tlsCertProfileOverride = "preferred";
    config.tlsCipherList = "ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256";
    config.tlsCiphersuitesList = "TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256";
    config.connTimeout = 60;
    config.retryOnAuthFailed = false;
    config.tunPersist = false;
    config.googleDnsFallback = false;
    config.dco = false;
    config.guiVersion = "Quorra";
    return true;
}
}

@implementation QVPNCore
+ (BOOL)selfTest { return BORINGSSL_self_test() == 1 && FIPS_mode() == 0; }
+ (NSInteger)packetProtocolFamily:(NSData *)packet maximumTransmissionUnit:(NSUInteger)mtu
{
    return quorra::packetFamily(packet, mtu);
}
+ (BOOL)evaluateProfile:(NSString *)profile error:(NSError **)error
{
    try {
        openvpn::ClientAPI::OpenVPNClientHelper helper;
        openvpn::ClientAPI::Config config;
        if (quorra::profileConfig(profile, config) && !helper.eval_config(config).error)
            return YES;
    } catch (...) {}
    quorra::fail(error, QVPNFailureInvalidProfile);
    return NO;
}
+ (QVPNChallenge *)parseChallenge:(NSData *)cookie
{
    if (!cookie.length || cookie.length > 8192)
        return nil;
    try {
        openvpn::ClientAPI::OpenVPNClientHelper helper;
        const auto text = quorra::bytes(cookie);
        if (text.find('\0') != std::string::npos)
            return nil;
        openvpn::ChallengeResponse challenge(text);
        if (!challenge.get_response_required() || challenge.get_state_id().empty() || challenge.get_username().empty())
            return nil;
        NSURLComponents *parts = [NSURLComponents componentsWithString:quorra::string(challenge.get_challenge_text())];
        if (![parts.scheme.lowercaseString isEqualToString:@"https"] || !parts.host.length || parts.user || parts.password || parts.fragment)
            return nil;
        return [[QVPNChallenge alloc] initWithURL:parts.URL cookie:cookie];
    } catch (...) { return nil; }
}
+ (BOOL)acceptsCertificateStrength:(NSData *)der
{
    if (!der.length || der.length > 65536) return NO;
    const unsigned char *cursor = static_cast<const unsigned char *>(der.bytes);
    bssl::UniquePtr<X509> certificate(d2i_X509(nullptr, &cursor, static_cast<long>(der.length)));
    return certificate && cursor == static_cast<const unsigned char *>(der.bytes) + der.length
           && openvpn::QuorraCertificatePolicy::accepts(certificate.get());
}
+ (NEPacketTunnelNetworkSettings *)networkSettingsForPushedOptions:(NSString *)options remoteAddress:(NSString *)address error:(NSError **)error
{
    try {
        if ([options lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 65536)
            throw std::runtime_error("bounded settings");
        openvpn::InitProcess::Init init;
        openvpn::OptionList parsed;
        parsed.parse_from_config(quorra::bytes([options dataUsingEncoding:NSUTF8StringEncoding]), nullptr);
        parsed.update_map();
        openvpn::TunProp::Config config;
        config.mtu = 1500;
        config.mtu_max = 1500;
        return quorra::settings(parsed, config, openvpn::IP::Addr([address UTF8String]));
    } catch (...) {
        quorra::fail(error, QVPNFailureNetworkSettings);
        return nil;
    }
}
@end
