Public synthetic certificates for offline SecTrust tests; no private keys are saved.
server.der has the DNS SAN db.example.test and is signed by root.der.
expired.der has the same hostname and issuer but expired in 2025.
other-root.der is an unrelated CA.
Tests evaluate these fixtures at a fixed September 2026 date.
