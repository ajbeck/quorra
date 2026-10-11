#pragma once
#include "CoreSupport.hpp"
#include <os/log.h>
#include <condition_variable>

namespace quorra {
namespace {
struct PacketGate;
class Client;

struct NetworkSettingsReply
{
    std::mutex mutex;
    std::condition_variable changed;
    bool completed = false;
    bool accepted = false;
    void complete(bool success)
    {
        std::lock_guard lock(mutex);
        if (completed) return;
        completed = true;
        accepted = success;
        changed.notify_all();
    }
    bool wait(std::chrono::milliseconds timeout)
    {
        std::unique_lock lock(mutex);
        if (!changed.wait_for(lock, timeout, [&] { return completed; })) {
            completed = true;
            accepted = false;
        }
        return accepted;
    }
};

struct Runtime : std::enable_shared_from_this<Runtime>
{
    std::mutex mutex;
    bool running = false;
    bool started = false;
    std::atomic<bool> active{false};
    std::atomic<bool> cancelled{false};
    std::atomic<size_t> queuedBytes{0};
    std::atomic<size_t> mtu{0};
    std::atomic<QVPNFailure> failure{QVPNFailureNone};
    __weak id<QVPNCoreDelegate> delegate;
    dispatch_queue_t queue;
    // Only post while holding mutex; the worker clears io before deleting Client.
    openvpn_io::io_context *io = nullptr;
    std::weak_ptr<PacketGate> packets;
    std::shared_ptr<NetworkSettingsReply> pendingSettings;
    std::chrono::milliseconds settingsTimeout{15000};
    std::unique_ptr<Client> client;
    QVPNChallenge *challenge = nil;

    Runtime(id<QVPNCoreDelegate> delegate, dispatch_queue_t queue) : delegate(delegate), queue(queue) {}
    void cancel()
    {
        cancelled = true;
        std::shared_ptr<NetworkSettingsReply> reply;
        { std::lock_guard lock(mutex); reply = pendingSettings; }
        if (reply) reply->complete(false);
    }
    void emit(void (^body)(id<QVPNCoreDelegate>))
    {
        auto runtime = shared_from_this();
        dispatch_async(queue, ^{
            @autoreleasepool { body(runtime->delegate); }
        });
    }
    template <class F> bool post(F body)
    {
        std::lock_guard lock(mutex);
        if (!io || cancelled) return false;
        openvpn_io::post(*io, std::move(body));
        return true;
    }
};

struct PacketGate
{
    openvpn::TunClientParent *parent;
    bool alive = true;
    bool ready = false;
    openvpn::Frame::Ptr frame;
    openvpn::SessionStats::Ptr stats;
};

class PacketClient final : public openvpn::TunClient
{
    std::shared_ptr<Runtime> runtime;
    std::shared_ptr<PacketGate> gate;
    openvpn::ExternalTun::Config config;
    openvpn::TunProp::State state;
    openvpn_io::io_context &io;
public:
    PacketClient(std::shared_ptr<Runtime> runtime, const openvpn::ExternalTun::Config &config,
                 openvpn_io::io_context &io, openvpn::TunClientParent &parent)
        : runtime(std::move(runtime)), gate(std::make_shared<PacketGate>()), config(config), io(io)
    {
        gate->parent = &parent; gate->frame = config.frame; gate->stats = config.stats;
        std::lock_guard lock(this->runtime->mutex);
        this->runtime->io = &io;
        this->runtime->packets = gate;
    }
    ~PacketClient() override { stop(); }
    void tun_start(const openvpn::OptionList &options, openvpn::TransportClient &transport, openvpn::CryptoDCSettings &) override
    {
        try {
            auto network = settings(options, config.tun_prop, transport.server_endpoint_addr());
            if (network.IPv4Settings.addresses.count) state.vpn_ip4_addr = openvpn::IP::Addr([network.IPv4Settings.addresses[0] UTF8String]);
            if (network.IPv6Settings.addresses.count) state.vpn_ip6_addr = openvpn::IP::Addr([network.IPv6Settings.addresses[0] UTF8String]);
            state.mtu = network.MTU.intValue;
            runtime->mtu = state.mtu;
            gate->parent->tun_pre_tun_config();
            auto runtime = this->runtime;
            auto reply = std::make_shared<NetworkSettingsReply>();
            { std::lock_guard lock(runtime->mutex); runtime->pendingSettings = reply; }
            if (runtime->cancelled) reply->complete(false);
            runtime->emit(^(id<QVPNCoreDelegate> delegate) {
                if (!delegate || !runtime->active || runtime->cancelled) { reply->complete(false); return; }
                [delegate applyVPNSettings:network completion:^(BOOL success) {
                    reply->complete(success);
                }];
            });
            // OpenVPN checks connected_ immediately after tun_start returns. Wait
            // only on its worker; Apple's completion runs on the callback queue.
            const bool accepted = reply->wait(runtime->settingsTimeout);
            { std::lock_guard lock(runtime->mutex); runtime->pendingSettings.reset(); }
            if (accepted && !runtime->cancelled) {
                gate->ready = true;
                gate->parent->tun_connected();
            } else {
                runtime->failure = runtime->cancelled ? QVPNFailureCancelled : QVPNFailureNetworkSettings;
                gate->parent->tun_error(openvpn::Error::TUN_SETUP_FAILED, "network settings unavailable");
            }
        } catch (...) {
            runtime->failure = QVPNFailureNetworkSettings;
            gate->parent->tun_error(openvpn::Error::TUN_SETUP_FAILED, "unsupported network settings");
        }
    }
    bool tun_send(openvpn::BufferAllocated &buffer) override
    {
        if (!gate->alive || !gate->ready || runtime->cancelled) return false;
        NSData *packet = [NSData dataWithBytes:buffer.c_data() length:buffer.size()];
        int family = packetFamily(packet, runtime->mtu);
        if (!family) return false;
        auto runtime = this->runtime;
        const auto count = packet.length;
        if (runtime->queuedBytes.fetch_add(count) + count > maximumQueuedBytes) {
            runtime->queuedBytes.fetch_sub(count);
            runtime->failure = QVPNFailurePacketOverflow; runtime->cancel();
            return false;
        }
        runtime->emit(^(id<QVPNCoreDelegate> delegate) {
            if (runtime->active && !runtime->cancelled) [delegate writeVPNPacket:packet protocolFamily:family];
            runtime->queuedBytes.fetch_sub(count);
        });
        gate->stats->inc_stat(openvpn::SessionStats::TUN_BYTES_OUT, count);
        gate->stats->inc_stat(openvpn::SessionStats::TUN_PACKETS_OUT, 1);
        return true;
    }
    void stop() override
    {
        gate->alive = false; gate->ready = false;
        runtime->mtu = 0;
    }
    void set_disconnect() override { stop(); }
    std::string tun_name() const override { return "QuorraPacketFlow"; }
    std::string vpn_ip4() const override { return state.vpn_ip4_addr.defined() ? state.vpn_ip4_addr.to_string() : ""; }
    std::string vpn_ip6() const override { return state.vpn_ip6_addr.defined() ? state.vpn_ip6_addr.to_string() : ""; }
    int vpn_mtu() const override { return state.mtu; }
};

class Factory final : public openvpn::TunClientFactory
{
    std::shared_ptr<Runtime> runtime;
    openvpn::ExternalTun::Config config;
public:
    Factory(std::shared_ptr<Runtime> runtime, const openvpn::ExternalTun::Config &config) : runtime(std::move(runtime)), config(config) {}
    openvpn::TunClient::Ptr new_tun_client_obj(openvpn_io::io_context &io, openvpn::TunClientParent &parent, openvpn::TransportClient *) override
    { return new PacketClient(runtime, config, io, parent); }
    bool supports_epoch_data() override { return true; }
};

class Client final : public openvpn::ClientAPI::OpenVPNClient
{
    std::shared_ptr<Runtime> runtime;
    std::string lastToken;
    bool connected = false;
public:
    explicit Client(std::shared_ptr<Runtime> runtime) : runtime(std::move(runtime)) {}
    bool pause_on_connection_timeout() override { return false; }
    void log(const openvpn::ClientAPI::LogInfo &) override {} // Never forward raw core diagnostics.
    void acc_event(const openvpn::ClientAPI::AppCustomControlMessageEvent &) override {}
    void external_pki_cert_request(openvpn::ClientAPI::ExternalPKICertRequest &request) override { request.error = true; }
    void external_pki_sign_request(openvpn::ClientAPI::ExternalPKISignRequest &request) override { request.error = true; }
    openvpn::TunClientFactory *new_tun_factory(const openvpn::ExternalTun::Config &config, const openvpn::OptionList &) override
    { return new quorra::Factory(runtime, config); }
    void event(const openvpn::ClientAPI::Event &event) override
    {
        // Never forward event.info: it can contain SAML state, tokens or hostnames.
        const std::set<std::string> diagnosticEvents = {
            "RESOLVE", "WAIT", "CONNECTING", "GET_CONFIG", "CONNECTED", "DYNAMIC_CHALLENGE",
            "AUTH_FAILED", "SESSION_EXPIRED", "RECONNECTING", "DISCONNECTED", "CERT_VERIFY_FAIL",
            "TLS_VERSION_MIN", "TUN_SETUP_FAILED", "TRANSPORT_ERROR", "CONNECTION_TIMEOUT", "NEED_CREDS",
        };
        os_log(OS_LOG_DEFAULT, "Quorra VPN event=%{public}s error=%{public}d fatal=%{public}d",
               diagnosticEvents.count(event.name) ? event.name.c_str() : "OTHER", event.error, event.fatal);
        if (event.name == "DYNAMIC_CHALLENGE") {
            runtime->challenge = [QVPNCore parseChallenge:quorra::data(event.info)];
            if (!runtime->challenge) runtime->failure = QVPNFailureAuthentication;
        } else if (event.name == "CONNECTED") {
            connected = true;
            runtime->emit(^(id<QVPNCoreDelegate> delegate) { [delegate vpnDidConnect]; });
        } else if (event.name == "RECONNECTING" || event.name == "DISCONNECTED") {
            if (connected && event.name == "RECONNECTING") {
                // The provider must end the current path before a new attempt.
                runtime->failure = QVPNFailureTransport;
                runtime->cancel();
            }
            connected = false;
        } else if (event.error && runtime->failure == QVPNFailureNone) {
            runtime->failure = event.name == "AUTH_FAILED" ? QVPNFailureAuthentication : QVPNFailureTransport;
        }
    }
    void clock_tick() override
    {
        if (runtime->cancelled) { stop(); return; }
        openvpn::ClientAPI::SessionToken token;
        if (connected && session_token(token) && token.session_id != lastToken) {
            lastToken = token.session_id;
            NSData *value = quorra::data(token.session_id), *username = quorra::data(token.username);
            runtime->emit(^(id<QVPNCoreDelegate> delegate) { [delegate vpnReceivedToken:value username:username]; });
        }
    }
};
}
}
