#import "include/QuorraOpenVPNTestSupport.h"
#include "../../Sources/QuorraOpenVPNNative/SessionRuntime.hpp"

namespace {
struct SettingsState {
    std::mutex mutex;
    std::condition_variable changed;
    void (^reply)(BOOL) = nil;
};
struct Parent final : openvpn::TunClientParent {
    bool connected = false;
    int errors = 0;
    void tun_recv(openvpn::BufferAllocated &) override {}
    void tun_error(openvpn::Error::Type, const std::string &) override { ++errors; }
    void tun_pre_tun_config() override {}
    void tun_pre_route_config() override {}
    void tun_connected() override { connected = true; }
};
struct Transport final : openvpn::TransportClient {
    void transport_start() override {}
    void stop() override {}
    bool transport_send_const(const openvpn::Buffer &) override { return false; }
    bool transport_send(openvpn::BufferAllocated &) override { return false; }
    bool transport_send_queue_empty() override { return true; }
    bool transport_has_send_queue() override { return false; }
    void transport_stop_requeueing() override {}
    size_t transport_send_queue_size() override { return 0; }
    void reset_align_adjust(size_t) override {}
    openvpn::IP::Addr server_endpoint_addr() const override { return openvpn::IP::Addr("192.0.2.8"); }
    void server_endpoint_info(std::string &, std::string &, std::string &, std::string &) const override {}
    openvpn::Protocol transport_protocol() const override { return openvpn::Protocol(openvpn::Protocol::UDPv4); }
    void transport_reparent(openvpn::TransportClientParent *) override {}
};
}

@interface SettingsReceiver : NSObject <QVPNCoreDelegate>
- (instancetype)initWithState:(std::shared_ptr<SettingsState>)state;
@end
@implementation SettingsReceiver {
    std::shared_ptr<SettingsState> _state;
}
- (instancetype)initWithState:(std::shared_ptr<SettingsState>)state { if ((self = [super init])) _state = state; return self; }
- (void)applyVPNSettings:(NEPacketTunnelNetworkSettings *)settings completion:(void (^)(BOOL))completion {
    std::lock_guard lock(_state->mutex);
    _state->reply = [completion copy];
    _state->changed.notify_all();
}
- (void)writeVPNPacket:(NSData *)packet protocolFamily:(NSInteger)family {}
- (void)vpnRequiresAuthentication:(QVPNChallenge *)challenge {}
- (void)vpnDidConnect {}
- (void)vpnDidStop:(QVPNFailure)failure {}
- (void)vpnReceivedToken:(NSData *)token username:(NSData *)username {}
@end

BOOL QVPNTestTunnelStartupContract(NSInteger scenario) {
    using namespace openvpn;
    InitProcess::Init init;
    auto state = std::make_shared<SettingsState>();
    SettingsReceiver *receiver = [[SettingsReceiver alloc] initWithState:state];
    auto runtime = std::make_shared<quorra::Runtime>(receiver, dispatch_queue_create("vpn-startup-test", DISPATCH_QUEUE_SERIAL));
    runtime->active = true;
    runtime->settingsTimeout = std::chrono::milliseconds(scenario == 3 ? 100 : 2000);
    openvpn_io::io_context io;
    ExternalTun::Config config;
    Parent parent;
    Transport transport;
    CryptoDCSettings crypto;
    OptionList options;
    options.parse_from_config("topology subnet\nifconfig 10.8.0.2 255.255.255.0\nroute 10.8.0.0 255.255.255.0\n", nullptr);
    options.update_map();
    quorra::PacketClient tunnel(runtime, config, io, parent);
    std::atomic<bool> returned{false};
    std::thread worker([&] { @autoreleasepool { tunnel.tun_start(options, transport, crypto); returned = true; } });
    void (^reply)(BOOL);
    {
        std::unique_lock lock(state->mutex);
        if (!state->changed.wait_for(lock, std::chrono::seconds(2), [&] { return state->reply != nil; })) {
            runtime->cancel(); worker.join(); return NO;
        }
        reply = state->reply;
    }
    // Withholding Apple's completion must keep OpenVPN's synchronous call pending.
    bool held = !returned.load();
    if (scenario == 0) reply(YES);
    else if (scenario == 1) reply(NO);
    else if (scenario == 2) runtime->cancel();
    worker.join();
    // Late or duplicate callbacks cannot change the outcome after return.
    reply(YES);
    const bool success = scenario == 0;
    return held && parent.connected == success && parent.errors == (success ? 0 : 1)
        && runtime->pendingSettings == nullptr
        && runtime->failure == (success ? QVPNFailureNone : scenario == 2 ? QVPNFailureCancelled : QVPNFailureNetworkSettings);
}
