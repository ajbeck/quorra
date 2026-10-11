#include "CoreSupport.hpp"
#include <arpa/inet.h>

namespace quorra {
namespace {
NSString *mask(int prefix)
{
    if (prefix < 0 || prefix > 32)
        throw std::runtime_error("invalid prefix");
    in_addr address{htonl(prefix ? 0xffffffffU << (32 - prefix) : 0)};
    char buffer[INET_ADDRSTRLEN];
    if (!inet_ntop(AF_INET, &address, buffer, sizeof(buffer)))
        throw std::runtime_error("invalid mask");
    return [NSString stringWithUTF8String:buffer];
}

bool contains(NSString *network, int prefix, NSString *address, bool ipv6)
{
    unsigned char net[16]{}, host[16]{};
    int family = ipv6 ? AF_INET6 : AF_INET;
    if (inet_pton(family, network.UTF8String, net) != 1 || inet_pton(family, address.UTF8String, host) != 1)
        return false;
    for (int bit = 0; bit < prefix; ++bit)
        if ((net[bit / 8] ^ host[bit / 8]) & (0x80 >> (bit % 8))) return false;
    return true;
}

int prefix4(NSString *mask)
{
    in_addr parsed{};
    if (inet_pton(AF_INET, mask.UTF8String, &parsed) != 1) return -1;
    return __builtin_popcount(parsed.s_addr);
}

class Builder final : public openvpn::TunBuilderBase
{
public:
    NSMutableArray<NSString *> *v4 = [NSMutableArray array], *v4Masks = [NSMutableArray array], *v6 = [NSMutableArray array];
    NSMutableArray<NSNumber *> *v6Prefixes = [NSMutableArray array];
    NSMutableArray<NEIPv4Route *> *include4 = [NSMutableArray array], *exclude4 = [NSMutableArray array];
    NSMutableArray<NEIPv6Route *> *include6 = [NSMutableArray array], *exclude6 = [NSMutableArray array];
    NSMutableArray<NSString *> *dnsServers = [NSMutableArray array], *dnsDomains = [NSMutableArray array], *searchDomains = [NSMutableArray array];
    int mtu = 1500;
    bool rejectedRoute = false;

    bool tun_builder_set_layer(int layer) override { return layer == 3; }
    bool tun_builder_set_remote_address(const std::string &, bool) override { return true; }
    bool tun_builder_set_session_name(const std::string &) override { return true; }
    bool tun_builder_set_route_metric_default(int) override { return true; }
    bool tun_builder_reroute_gw(bool ipv4, bool ipv6, unsigned int) override { return !ipv4 && !ipv6; }
    bool tun_builder_set_allow_family(int, bool) override { return true; }
    bool tun_builder_set_allow_local_dns(bool) override { return true; }
    bool tun_builder_set_mtu(int value) override { mtu = value; return value >= 1280 && value <= 1500; }
    bool tun_builder_add_address(const std::string &address, int prefix, const std::string &, bool ipv6, bool) override
    {
        if (v4.count + v6.count >= 8 || prefix < 0 || prefix > (ipv6 ? 128 : 32))
            return false;
        if (ipv6) { [v6 addObject:string(address)]; [v6Prefixes addObject:@(prefix)]; }
        else { [v4 addObject:string(address)]; [v4Masks addObject:mask(prefix)]; }
        return true;
    }
    bool route(const std::string &address, int prefix, bool ipv6, bool excluded)
    {
        if (prefix <= 0 || prefix > (ipv6 ? 128 : 32) || include4.count + include6.count + exclude4.count + exclude6.count >= 256) {
            rejectedRoute = true;
            return false;
        }
        if (ipv6)
            [(excluded ? exclude6 : include6) addObject:[[NEIPv6Route alloc] initWithDestinationAddress:string(address) networkPrefixLength:@(prefix)]];
        else
            [(excluded ? exclude4 : include4) addObject:[[NEIPv4Route alloc] initWithDestinationAddress:string(address) subnetMask:mask(prefix)]];
        return true;
    }
    bool tun_builder_add_route(const std::string &address, int prefix, int, bool ipv6) override { return route(address, prefix, ipv6, false); }
    bool tun_builder_exclude_route(const std::string &address, int prefix, int, bool ipv6) override { return route(address, prefix, ipv6, true); }
    bool tun_builder_set_dns_options(const openvpn::DnsOptions &dns) override
    {
        [dnsServers removeAllObjects]; [dnsDomains removeAllObjects]; [searchDomains removeAllObjects];
        // NEDNSSettings has one resolver group; do not flatten distinct policies.
        if (dns.servers.size() > 1) return false;
        for (const auto &[priority, server] : dns.servers)
        {
            if ((server.transport != openvpn::DnsServer::Transport::Unset && server.transport != openvpn::DnsServer::Transport::Plain)
                || server.dnssec == openvpn::DnsServer::Security::Yes || !server.sni.empty())
                return false;
            for (const auto &address : server.addresses)
            {
                if (address.port != 0 && address.port != 53) return false;
                [dnsServers addObject:string(address.address)];
            }
            for (const auto &domain : server.domains) [dnsDomains addObject:string(domain.domain)];
        }
        for (const auto &domain : dns.search_domains) [searchDomains addObject:string(domain.domain)];
        return dnsServers.count <= 8 && dnsDomains.count + searchDomains.count <= 64;
    }
    bool dnsIsRouted(NSString *address)
    {
        int included = -1, excluded = -1;
        if (v4.count) {
            for (NEIPv4Route *route in include4) {
                int prefix = prefix4(route.destinationSubnetMask);
                if (contains(route.destinationAddress, prefix, address, false)) included = std::max(included, prefix);
            }
            for (NEIPv4Route *route in exclude4) {
                int prefix = prefix4(route.destinationSubnetMask);
                if (contains(route.destinationAddress, prefix, address, false)) excluded = std::max(excluded, prefix);
            }
        }
        if (v6.count) {
            for (NEIPv6Route *route in include6) {
                int prefix = route.destinationNetworkPrefixLength.intValue;
                if (contains(route.destinationAddress, prefix, address, true)) included = std::max(included, prefix);
            }
            for (NEIPv6Route *route in exclude6) {
                int prefix = route.destinationNetworkPrefixLength.intValue;
                if (contains(route.destinationAddress, prefix, address, true)) excluded = std::max(excluded, prefix);
            }
        }
        return included >= 0 && included > excluded;
    }
};
}

NEPacketTunnelNetworkSettings *settings(const openvpn::OptionList &options, const openvpn::TunProp::Config &config, const openvpn::IP::Addr &remote)
{
    Builder builder;
    openvpn::TunProp::State state;
    // The core intentionally ignores some invalid routes and clamps MTUs. Validate
    // the input first so partial settings cannot masquerade as a complete tunnel.
    for (const auto &option : options) {
        if (option.empty()) continue;
        const auto &name = option.ref(0);
        if (name == "route" || name == "route-ipv6") {
            bool ipv6 = name == "route-ipv6";
            const auto pair = ipv6
                ? openvpn::IP::AddrMaskPair::from_string(option.get(1, 256), "route-ipv6")
                : openvpn::IP::AddrMaskPair::from_string(option.get(1, 256), option.get_optional(2, 256), "route");
            size_t gateway = ipv6 ? 2 : 3;
            if (option.size() > gateway && option.ref(gateway) != "vpn_gateway" && option.ref(gateway) != "net_gateway")
                throw std::runtime_error("unsupported route gateway");
            option.get_num<int>(gateway + 1, -1, 0, 65535);
            if (!pair.is_canonical() || pair.netmask.prefix_len() <= 0 || pair.version() != (ipv6 ? openvpn::IP::Addr::V6 : openvpn::IP::Addr::V4)
                || !options.exists(ipv6 ? "ifconfig-ipv6" : "ifconfig"))
                throw std::runtime_error("unsupported split route");
        } else if (name == "tun-mtu") {
            int mtu = option.get_num<int>(1);
            if (mtu < 1280 || mtu > 1500) throw std::runtime_error("unsupported MTU");
        }
    }
    openvpn::TunProp::configure_builder(&builder, &state, nullptr, remote, config, options, nullptr, true);
    if (builder.rejectedRoute) throw std::runtime_error("unsupported route count");
    // TunProp also treats DNS parse failures as warnings. Require full success.
    openvpn::DnsOptionsParser dns(options, true);
    if (!builder.tun_builder_set_dns_options(dns)) throw std::runtime_error("unsupported DNS policy");
    if (!builder.v4.count && !builder.v6.count)
        throw std::runtime_error("missing tunnel address");
    if (!builder.include4.count && !builder.include6.count)
        throw std::runtime_error("missing split routes");
    // An exact exception keeps the encrypted transport outside the included routes.
    if (!builder.route(remote.to_string(), remote.is_ipv6() ? 128 : 32, remote.is_ipv6(), true))
        throw std::runtime_error("missing transport exception");
    if ((!builder.v4.count && builder.include4.count) || (!builder.v6.count && builder.include6.count))
        throw std::runtime_error("route without address family");
    for (NSString *server in builder.dnsServers)
        if (!builder.dnsIsRouted(server)) throw std::runtime_error("DNS outside included routes");
    NEPacketTunnelNetworkSettings *result = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:string(remote.to_string())];
    if (builder.v4.count) {
        NEIPv4Settings *ip = [[NEIPv4Settings alloc] initWithAddresses:builder.v4 subnetMasks:builder.v4Masks];
        ip.includedRoutes = builder.include4; ip.excludedRoutes = builder.exclude4; result.IPv4Settings = ip;
    }
    if (builder.v6.count) {
        NEIPv6Settings *ip = [[NEIPv6Settings alloc] initWithAddresses:builder.v6 networkPrefixLengths:builder.v6Prefixes];
        ip.includedRoutes = builder.include6; ip.excludedRoutes = builder.exclude6; result.IPv6Settings = ip;
    }
    if (builder.dnsServers.count) {
        NEDNSSettings *dns = [[NEDNSSettings alloc] initWithServers:builder.dnsServers];
        dns.matchDomains = builder.dnsDomains.count ? builder.dnsDomains : @[@""];
        dns.searchDomains = builder.searchDomains;
        dns.matchDomainsNoSearch = YES;
        result.DNSSettings = dns;
    }
    result.MTU = @(builder.mtu);
    return result;
}
}
