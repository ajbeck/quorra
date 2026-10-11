#include "SessionRuntime.hpp"

namespace quorra {
int packetFamily(NSData *packet, size_t mtu)
{
    if (mtu < 1280 || mtu > 1500 || packet.length < 20 || packet.length > mtu) return 0;
    const auto *p = static_cast<const unsigned char *>(packet.bytes);
    if ((p[0] >> 4) == 4 && (p[0] & 15) >= 5 && (p[0] & 15) * 4 <= packet.length
        && (size_t(p[2]) * 256 + p[3]) == packet.length) return AF_INET;
    if ((p[0] >> 4) == 6 && packet.length >= 40 && (size_t(p[4]) * 256 + p[5] + 40) == packet.length) return AF_INET6;
    return 0;
}
}

@implementation QVPNCoreSession {
    std::shared_ptr<quorra::Runtime> _runtime;
}
- (instancetype)initWithDelegate:(id<QVPNCoreDelegate>)delegate callbackQueue:(dispatch_queue_t)queue
{
    if ((self = [super init])) _runtime = std::make_shared<quorra::Runtime>(delegate, queue);
    return self;
}
- (BOOL)startProfile:(NSString *)profile credentials:(QVPNCredentials *)credentials error:(NSError **)error
{
    using namespace quorra;
    openvpn::ClientAPI::Config config;
    openvpn::ClientAPI::ProvideCreds creds;
    try {
        if (!profileConfig(profile, config) || ![QVPNCore evaluateProfile:profile error:nil]) {
            fail(error, QVPNFailureInvalidProfile); return NO;
        }
        if (credentials) creds = [credentials coreCredentials];
        else { creds.username = "N/A"; creds.password = "ACS::35001"; }
        config.clockTickMS = 250;
    } catch (...) { fail(error, QVPNFailureInvalidProfile); return NO; }
    auto runtime = _runtime;
    {
        std::lock_guard lock(runtime->mutex);
        if (runtime->started) { fail(error, QVPNFailureBusy); return NO; }
        runtime->started = true;
        runtime->running = true;
        runtime->active = true;
        runtime->cancelled = false;
        runtime->failure = QVPNFailureNone;
        runtime->challenge = nil;
    }
    try {
      std::thread([runtime, config = std::move(config), creds = std::move(creds)] {
        @autoreleasepool {
            try {
                auto client = std::make_unique<Client>(runtime);
                if (client->eval_config(config).error || client->provide_creds(creds).error)
                    runtime->failure = QVPNFailureInvalidCredentials;
                else if (!runtime->cancelled) {
                    { std::lock_guard lock(runtime->mutex); runtime->client = std::move(client); }
                    const auto status = runtime->client->connect();
                    if (status.error && !runtime->challenge && runtime->failure == QVPNFailureNone)
                        runtime->failure = QVPNFailureTransport;
                }
            } catch (...) { runtime->failure = QVPNFailureTransport; }
            QVPNChallenge *challenge = runtime->challenge;
            runtime->active = false;
            QVPNFailure failure = runtime->failure;
            if (runtime->cancelled && failure == QVPNFailureNone) failure = QVPNFailureCancelled;
            {
                std::lock_guard lock(runtime->mutex);
                runtime->io = nullptr; runtime->packets.reset(); runtime->client.reset(); runtime->running = false;
            }
            runtime->emit(^(id<QVPNCoreDelegate> delegate) {
                if (challenge && failure == QVPNFailureNone) [delegate vpnRequiresAuthentication:challenge];
                else [delegate vpnDidStop:failure];
            });
        }
      }).detach();
    } catch (...) {
        std::lock_guard lock(runtime->mutex);
        runtime->running = false;
        runtime->active = false;
        fail(error, QVPNFailureTransport);
        return NO;
    }
    return YES;
}
- (void)stop { _runtime->cancel(); }
- (void)dealloc { _runtime->cancel(); }
- (BOOL)sendPackets:(NSArray<NSData *> *)packets
{
    using namespace quorra;
    if (!packets.count || packets.count > 64) return NO;
    auto runtime = _runtime;
    const auto mtu = runtime->mtu.load();
    size_t count = 0;
    NSMutableArray<NSData *> *snapshot = [NSMutableArray arrayWithCapacity:packets.count];
    for (NSData *input in packets) {
        NSData *packet = [input copy];
        if (!packetFamily(packet, mtu)) return NO;
        count += packet.length;
        if (count > maximumQueuedBytes) return NO;
        [snapshot addObject:packet];
    }
    if (runtime->queuedBytes.fetch_add(count) + count > maximumQueuedBytes) {
        runtime->queuedBytes.fetch_sub(count); return NO;
    }
    std::weak_ptr<PacketGate> weak;
    { std::lock_guard lock(runtime->mutex); weak = runtime->packets; }
    bool posted = runtime->post([runtime, weak, snapshot, count] {
        @autoreleasepool {
            runtime->queuedBytes.fetch_sub(count);
            auto gate = weak.lock();
            if (!gate || !gate->alive || !gate->ready || runtime->cancelled) return;
            for (NSData *packet in snapshot) {
                if (!packetFamily(packet, runtime->mtu)) continue;
                openvpn::BufferAllocated buffer;
                gate->frame->prepare(openvpn::Frame::READ_TUN, buffer);
                buffer.write(packet.bytes, packet.length);
                gate->stats->inc_stat(openvpn::SessionStats::TUN_BYTES_IN, packet.length);
                gate->stats->inc_stat(openvpn::SessionStats::TUN_PACKETS_IN, 1);
                gate->parent->tun_recv(buffer);
            }
        }
    });
    if (!posted) runtime->queuedBytes.fetch_sub(count);
    return posted;
}
@end
