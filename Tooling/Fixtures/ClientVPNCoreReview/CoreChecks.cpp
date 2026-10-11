// Synthetic checks for the proposed dependency; this executable never connects.
#include <client/ovpncli.hpp>
#include <openssl/crypto.h>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>

namespace {
void require(bool condition)
{
    if (!condition)
        throw std::runtime_error("core check failed");
}

class Client final : public openvpn::ClientAPI::OpenVPNClient
{
    bool pause_on_connection_timeout() override { return false; }
    void event(const openvpn::ClientAPI::Event &) override {}
    void acc_event(const openvpn::ClientAPI::AppCustomControlMessageEvent &) override {}
    void log(const openvpn::ClientAPI::LogInfo &) override {}
    void external_pki_cert_request(openvpn::ClientAPI::ExternalPKICertRequest &request) override { request.error = true; }
    void external_pki_sign_request(openvpn::ClientAPI::ExternalPKISignRequest &request) override { request.error = true; }
    openvpn::TunClientFactory *new_tun_factory(const openvpn::ExternalTun::Config &, const openvpn::OptionList &) override
    {
        throw std::runtime_error("networking is disabled in this check");
    }
};
}

int main(int argc, char **argv)
{
    try
    {
        require(argc == 2);
        openvpn::ClientAPI::OpenVPNClientHelper helper;
        Client client;
        for (const auto &username : {"dXNlcg==", "b'dXNlcg=='", "b\"dXNlcg==\""})
        {
            openvpn::ClientAPI::DynamicChallenge challenge;
            require(helper.parse_dynamic_challenge(std::string("CRV1:R:synthetic-state:") + username + ":https://signin.example.invalid/", challenge));
            require(challenge.stateID == "synthetic-state" && challenge.responseRequired);
        }
        for (const auto &username : {"b'dXNlcg==\"", "B'dXNlcg=='", "b'not base64!'", "b'dXNlcg==\\n'"})
        {
            openvpn::ClientAPI::DynamicChallenge challenge;
            require(!helper.parse_dynamic_challenge(std::string("CRV1:R:synthetic-state:") + username + ":https://signin.example.invalid/", challenge));
        }
        std::ifstream file(argv[1]);
        require(file.good());
        const std::string ca((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        openvpn::ClientAPI::Config config;
        config.content = "client\ndev tun\nproto udp\nremote vpn.example.invalid 443\nauth-user-pass\nremote-cert-tls server\ntls-version-min 1.2\n<ca>\n" + ca + "</ca>\n";
        const auto evaluated = client.eval_config(config);
        require(!evaluated.error && !evaluated.autologin && evaluated.remoteHost == "vpn.example.invalid");
        config.content = "client\ndev tun\n";
        require(client.eval_config(config).error);
        openvpn::ClientAPI::SessionToken token;
        require(!client.session_token(token));
        require(BORINGSSL_self_test() == 1);
        // A source build using AWS-LC is not a FIPS-validated product.
        require(FIPS_mode() == 0);
        std::cout << "PASS core API: CRV1 compatibility/rejection, profile evaluation, absent token, AWS-LC known-answer self-tests\n";
        return 0;
    }
    catch (...)
    {
        // Even synthetic checks use closed errors, never core descriptions.
        std::cerr << "FAIL core API checks\n";
        return 1;
    }
}
