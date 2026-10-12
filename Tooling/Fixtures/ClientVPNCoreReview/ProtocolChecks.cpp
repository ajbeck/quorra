// Compile separately from the client API, without UNIT_TEST: Amazon's patch
// changes the receive protocol under that define, hiding wire incompatibility.
#define OPENVPN_LOG(args) do {} while (false)
#define OPENVPN_LOG_NTNL(args) do {} while (false)
#include <openvpn/io/io.hpp>
#include <openvpn/init/initprocess.hpp>
#include <openvpn/ssl/proto.hpp>
#include <openvpn/auth/cr.hpp>
#include <iostream>
#include <stdexcept>

namespace {
struct ProtocolAccess : openvpn::ProtoContext
{
    using ProtoContext::write_auth_string;
    using ProtoContext::read_auth_string;
    using ProtoContext::write_uint32_length;
    using ProtoContext::APP_MSG_MAX;
};

void require(bool condition)
{
    if (!condition)
        throw std::runtime_error("protocol check failed");
}
}

int main()
{
    try
    {
        openvpn::InitProcess::Init initialization;
        openvpn::BufferAllocated buffer(80000, openvpn::BufAllocFlags::GROW);
        ProtocolAccess::write_auth_string(std::string(70000, 'x'), buffer);
        require(buffer.size() == 70005);
        require(buffer[0] == 0 && buffer[1] == 1 && buffer[2] == 0x11 && buffer[3] == 0x71);
        require(buffer[70004] == 0);
        require(ProtocolAccess::APP_MSG_MAX == 131072);

        // Server-to-client auth strings still use the stock 16-bit prefix.
        openvpn::BufferAllocated incoming(16, openvpn::BufAllocFlags::GROW);
        const unsigned char encoded[] = {0, 3, 'o', 'k', 0};
        incoming.write(encoded, sizeof(encoded));
        require(ProtocolAccess::read_auth_string<std::string>(incoming) == "ok");
        require(incoming.empty());

        openvpn::BufferAllocated overflow(8, 0);
        bool rejected = false;
        try { ProtocolAccess::write_uint32_length(0x100000000ULL, overflow); }
        catch (const std::exception &) { rejected = true; }
        require(rejected && overflow.empty());

        openvpn::BufferAllocated truncated(4, 0);
        const unsigned char invalid[] = {0, 5, 'x'};
        truncated.write(invalid, sizeof(invalid));
        rejected = false;
        try { ProtocolAccess::read_auth_string<std::string>(truncated); }
        catch (const std::exception &) { rejected = true; }
        require(rejected);

        for (const auto &username : {"dXNlcg==", "b'dXNlcg=='", "b\"dXNlcg==\""})
        {
            openvpn::ChallengeResponse challenge(std::string("CRV1:R:synthetic-state:") + username + ":https://signin.example.invalid/");
            require(challenge.get_username() == "user");
            require(challenge.construct_dynamic_password("synthetic-response") == "CRV1::synthetic-state::synthetic-response");
        }

        std::cout << "PASS production AWS framing: 32-bit outbound, 16-bit inbound, 70 KB credential, length overflow/truncation\n";
        return 0;
    }
    catch (...)
    {
        std::cerr << "FAIL protocol checks\n";
        return 1;
    }
}
