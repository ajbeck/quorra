// The public module exposes Objective-C only; these C++ types stay private.
#pragma once
#import "include/QuorraOpenVPNNative.h"
#include <openvpn/io/io.hpp>
#include <client/ovpncli.hpp>
#define OPENVPN_LOG_CLASS openvpn::ClientAPI::LogReceiver
#define OPENVPN_LOG_INFO openvpn::ClientAPI::LogInfo
#include <openvpn/log/logthread.hpp>
#include <openvpn/tun/extern/config.hpp>
#include <openvpn/init/initprocess.hpp>
#include <openvpn/auth/cr.hpp>
#include <openvpn/openssl/pki/quorra_cert_policy.hpp>
#include <openssl/pem.h>
#include <mutex>
#include <atomic>
#include <thread>
#include <set>

@interface QVPNCredentials (Internal)
- (openvpn::ClientAPI::ProvideCreds)coreCredentials;
@end

namespace quorra {
inline constexpr size_t maximumCredential = 120 * 1024;
inline constexpr size_t maximumQueuedBytes = 1024 * 1024;
inline std::string bytes(NSData *data) { return std::string(static_cast<const char *>(data.bytes), data.length); }
inline NSData *data(const std::string &value) { return [NSData dataWithBytes:value.data() length:value.size()]; }
inline NSString *string(const std::string &value) { return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding]; }
inline void fail(NSError **error, QVPNFailure code)
{
    if (error)
        *error = [NSError errorWithDomain:@"dev.ajbeck.quorra.vpn.core" code:code userInfo:@{NSLocalizedDescriptionKey: @"The VPN core could not complete this operation."}];
}
bool profileConfig(NSString *profile, openvpn::ClientAPI::Config &config);
int packetFamily(NSData *packet, size_t mtu);
NEPacketTunnelNetworkSettings *settings(const openvpn::OptionList &options,
                                      const openvpn::TunProp::Config &config,
                                      const openvpn::IP::Addr &remote);
}
