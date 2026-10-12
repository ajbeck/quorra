#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// In-memory TLS handshake using the production client profile and verifier.
FOUNDATION_EXPORT BOOL QVPNTestTLSHandshake(NSString *profile, NSString *serverCertificate, NSString *serverKey);
/// Exercises the production external-tun factory with delayed system settings.
FOUNDATION_EXPORT BOOL QVPNTestTunnelStartupContract(NSInteger scenario);
NS_ASSUME_NONNULL_END
