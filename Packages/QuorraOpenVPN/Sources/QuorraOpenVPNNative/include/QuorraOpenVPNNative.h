#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, QVPNFailure) {
    QVPNFailureNone = 0,
    QVPNFailureInvalidProfile,
    QVPNFailureInvalidCredentials,
    QVPNFailureBusy,
    QVPNFailureAuthentication,
    QVPNFailureTransport,
    QVPNFailureNetworkSettings,
    QVPNFailureCancelled,
    QVPNFailurePacketOverflow,
};

/// Challenge material stays in memory and has a redacted description.
NS_SWIFT_SENDABLE
@interface QVPNChallenge : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@property(nonatomic, readonly, copy) NSURL *url;
@property(nonatomic, readonly, copy) NSData *cookie;
@end

NS_SWIFT_SENDABLE
@interface QVPNCredentials : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
+ (nullable instancetype)challenge:(NSData *)cookie response:(NSData *)response;
+ (nullable instancetype)cachedUsername:(NSData *)username token:(NSData *)token;
@end

/// Functions that do not open sockets or change system settings.
@interface QVPNCore : NSObject
+ (BOOL)evaluateProfile:(NSString *)profile error:(NSError **)error;
+ (nullable QVPNChallenge *)parseChallenge:(NSData *)cookie;
+ (BOOL)acceptsCertificateStrength:(NSData *)der;
+ (BOOL)selfTest;
+ (NSInteger)packetProtocolFamily:(NSData *)packet maximumTransmissionUnit:(NSUInteger)mtu;
+ (nullable NEPacketTunnelNetworkSettings *)networkSettingsForPushedOptions:(NSString *)options
                                                            remoteAddress:(NSString *)address
                                                                    error:(NSError **)error;
@end

@protocol QVPNCoreDelegate <NSObject>
/// Called on the supplied serial callback queue. Complete exactly once.
- (void)applyVPNSettings:(NEPacketTunnelNetworkSettings *)settings completion:(void (^)(BOOL))completion;
- (void)writeVPNPacket:(NSData *)packet protocolFamily:(NSInteger)family;
- (void)vpnRequiresAuthentication:(QVPNChallenge *)challenge;
- (void)vpnDidConnect;
- (void)vpnDidStop:(QVPNFailure)failure;
/// The token is optional and has no documented expiry; never log or persist here.
- (void)vpnReceivedToken:(NSData *)token username:(NSData *)username;
@end

/// One connection attempt per instance. Methods are synchronized; protocol state
/// belongs to one worker. Create a fresh instance to answer a SAML challenge.
NS_SWIFT_SENDABLE
@interface QVPNCoreSession : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithDelegate:(id<QVPNCoreDelegate>)delegate callbackQueue:(dispatch_queue_t)queue;
- (BOOL)startProfile:(NSString *)profile credentials:(nullable QVPNCredentials *)credentials error:(NSError **)error;
- (void)stop;
/// Raw IPv4/IPv6 packets, without an Apple utun family prefix. Bounded to 1 MiB.
- (BOOL)sendPackets:(NSArray<NSData *> *)packets;
@end

NS_ASSUME_NONNULL_END
