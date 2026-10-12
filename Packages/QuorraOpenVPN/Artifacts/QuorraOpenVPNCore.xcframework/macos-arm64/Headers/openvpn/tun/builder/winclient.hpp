
// Windows-specific TunBuilder client implementation
// Implement https://github.com/OpenVPN/openvpn3/blob/master/openvpn/tun/builder/client.hpp, but for Windows.

#ifndef OPENVPN_TUN_BUILDER_WINCLIENT_H
#define OPENVPN_TUN_BUILDER_WINCLIENT_H

#ifdef _WIN32

#include <memory>
#include <sstream>

#include <openvpn/win/scoped_handle.hpp>
#include <openvpn/tun/win/client/clientconfig.hpp>
#include <openvpn/tun/win/client/tunsetup.hpp>
#include <openvpn/win/modname.hpp>
#include <openvpn/common/cleanup.hpp>
#include <openvpn/tun/persist/tunwrapasio.hpp>
#include <openvpn/tun/tunio.hpp>
#include <io.h>

namespace openvpn::TunBuilderClient {

struct PacketFrom
{
    typedef std::unique_ptr<PacketFrom> SPtr;
    BufferAllocated buf;
};

using TunPersist = TunWin::TunPersist;

typedef openvpn_io::windows::stream_handle TAPStream;

template <typename ReadHandler, typename TunPersist>
class Tun : public TunIO<ReadHandler, PacketFrom, TunWrapAsioStream<TunPersist>>
{
    typedef TunIO<ReadHandler, PacketFrom, TunWrapAsioStream<TunPersist>> Base;

  public:
    typedef RCPtr<Tun> Ptr;

    Tun(const typename TunPersist::Ptr &tun_persist,
        const std::string &name,
        const bool retain_stream,
        ReadHandler read_handler,
        const Frame::Ptr &frame,
        const SessionStats::Ptr &stats)
        : Base(read_handler, frame, stats, Frame::READ_TUN)
    {
        Base::name_ = name;
        Base::retain_stream = retain_stream;
        Base::stream = new TunWrapAsioStream<TunPersist>(tun_persist);
    }
};

class WindowsTunBuilderClient;

class ClientConfig : public TunClientFactory
{
  public:
    typedef RCPtr<ClientConfig> Ptr;

    TunProp::Config tun_prop;
    int n_parallel = 8;
    bool retain_sd = false;
    bool tun_prefix = false;
    Frame::Ptr frame;
    SessionStats::Ptr stats;
    EmulateExcludeRouteFactory::Ptr eer_factory;
    TunPersist::Ptr tun_persist;
    TunBuilderBase *builder = nullptr;

    static Ptr new_obj()
    {
        return new ClientConfig;
    }

    TunClient::Ptr new_tun_client_obj(openvpn_io::io_context &io_context,
                                      TunClientParent &parent,
                                      TransportClient *transcli) override;

    void finalize(const bool disconnected) override
    {
        if (disconnected)
            tun_persist.reset();
    }

    bool supports_epoch_data() override
    {
        return true;
    }

  private:
    ClientConfig() = default;
};

class WindowsTunBuilderClient : public TunClient
{
    friend class ClientConfig;                                                                // calls constructor
    friend class TunIO<WindowsTunBuilderClient *, PacketFrom, TunWrapAsioStream<TunPersist>>; // calls tun_read_handler

    typedef Tun<WindowsTunBuilderClient *, TunPersist> TunImpl;

  public:
    typedef RCPtr<WindowsTunBuilderClient> Ptr;
    WindowsTunBuilderClient(openvpn_io::io_context &io_context,
                            ClientConfig *config,
                            TunClientParent &parent)
        : io_context_(io_context), config_(config), parent_(parent)
    {
    }

    void tun_start(const OptionList &opt, TransportClient &transcli, CryptoDCSettings &) override
    {
        if (!impl)
        {
            halt = false;

            if (config_->tun_persist)
                tun_persist = config_->tun_persist;
            else
                tun_persist.reset(new TunPersist(false, TunWrapObjRetain::NO_RETAIN, config_->builder));

            try
            {
                const IP::Addr server_addr = transcli.server_endpoint_addr();

                if (tun_persist->use_persisted_tun(server_addr, config_->tun_prop, opt))
                {
                    state = tun_persist->state().state;
                    OPENVPN_LOG("TunPersist: reused tun context");
                }
                else
                {
                    if (!config_->builder->tun_builder_new())
                    {
                        parent_.tun_error(Error::TUN_SETUP_FAILED, "tun_builder_new failed");
                        return;
                    }

                    state.reset(new TunProp::State());

                    TunProp::configure_builder(config_->builder,
                                               state.get(),
                                               config_->stats.get(),
                                               server_addr,
                                               config_->tun_prop,
                                               opt,
                                               config_->eer_factory.get(),
                                               false);


                    int fd = config_->builder->tun_builder_establish();

                    if (fd < 0)
                    {
                        parent_.tun_error(Error::TUN_SETUP_FAILED, "TunBuilder establish failed");
                        return;
                    }

                    HANDLE th = config_->builder->get_tun_handle();

                    TAPStream *ts = new TAPStream(io_context_, th);


                    if (tun_persist->persist_tun_state(ts, {state, nullptr}))
                        OPENVPN_LOG("TunPersist: saving tun context:" << std::endl
                                                                      << tun_persist->options());
                }

                impl.reset(new TunImpl(tun_persist, "TUN_WIN_BUILDER", true, this, config_->frame, config_->stats));
                impl->start(config_->n_parallel);

                parent_.tun_connected();
            }
            catch (const std::exception &e)
            {
                OPENVPN_LOG("Exception: " << e.what());

                if (tun_persist)
                    tun_persist->close();
                parent_.tun_error(Error::TUN_SETUP_FAILED, e.what());
            }
        }
    }

    void tun_read_handler(PacketFrom::SPtr &pfp)
    {
        parent_.tun_recv(pfp->buf);
    }

    void tun_error_handler(const Error::Type errtype, const openvpn_io::error_code *error)
    {
        if (!halt)
            parent_.tun_error(errtype, "TUN I/O error");
    }

    bool tun_send(BufferAllocated &buf) override
    {
        if (impl)
            return impl->write(buf);
        return false;
    }
    void stop() override
    {
        halt = true;
        if (impl)
            impl->stop();
        tun_persist.reset();
    }
    void set_disconnect() override
    {
        if (tun_persist)
            tun_persist->set_disconnect();
    }

    std::string tun_name() const override
    {
        if (impl)
            return impl->name();
        else
            return "UNDEF_TUN";
    }

    std::string vpn_ip4() const override
    {
        if (state->vpn_ip4_addr.specified())
            return state->vpn_ip4_addr.to_string();
        else
            return "";
    }

    std::string vpn_ip6() const override
    {
        if (state->vpn_ip6_addr.specified())
            return state->vpn_ip6_addr.to_string();
        else
            return "";
    }

    std::string vpn_gw4() const override
    {
        if (state->vpn_ip4_gw.specified())
            return state->vpn_ip4_gw.to_string();
        else
            return "";
    }

    std::string vpn_gw6() const override
    {
        if (state->vpn_ip6_gw.specified())
            return state->vpn_ip6_gw.to_string();
        else
            return "";
    }

    int vpn_mtu() const override
    {
        return state->mtu;
    }

  private:
    openvpn_io::io_context &io_context_;
    ClientConfig *config_;
    TunClientParent &parent_;

    TunPersist::Ptr tun_persist;
    TunImpl::Ptr impl;
    TunProp::State::Ptr state;
    TunWin::SetupBase::Ptr tun_setup;
    bool halt = false;
};

inline TunClient::Ptr ClientConfig::new_tun_client_obj(openvpn_io::io_context &io_context,
                                                       TunClientParent &parent,
                                                       TransportClient *transcli)
{
    return TunClient::Ptr(new WindowsTunBuilderClient(io_context, this, parent));
}

} 

#endif // _WIN32

#endif // OPENVPN_TUN_BUILDER_WINCLIENT_H
