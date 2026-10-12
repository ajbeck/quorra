# Synthetic TLS fixtures

`tls-server.key` is a deliberately shared test key for the included certificate
`tls-server.pem`, whose identity is `vpn.example.invalid`. That certificate is
signed only by the included self-signed `Synthetic VPN Test Root`.

The key and certificate have matching public-key SHA-256:
`c2103501bc5cf3b3d1cf4624957873c431feecc72a00e8a1eb6527b4bbd9b134`.

`TLSHandshakeTests` passes these fixtures to `QVPNTestTLSHandshake`, which moves
TLS records between two in-memory sessions. It opens no listener or remote socket.
The fixtures are resources of the SwiftPM test target only; the app and provider
do not bundle them. They are not AWS credentials or a production signing identity.

The DER fixtures exercise certificate-strength rejection. All trust in these roots
is scoped to synthetic tests; no system Keychain trust is modified.
