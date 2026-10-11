import Foundation
@preconcurrency import NetworkExtension

/// Uses Apple's supported packet APIs; never obtains or manages a utun descriptor.
public final class VPNPacketTunnelIO: VPNPacketIO, @unchecked Sendable {
    private weak var provider: NEPacketTunnelProvider?

    public init(provider: NEPacketTunnelProvider) { self.provider = provider }

    public func apply(_ settings: NEPacketTunnelNetworkSettings?, completion: @escaping @Sendable (Bool) -> Void) {
        guard let provider else { completion(false); return }
        provider.setTunnelNetworkSettings(settings) { error in completion(error == nil) }
    }

    public func read(completion: @escaping @Sendable (Result<VPNPacketBatch, VPNFailure>) -> Void) {
        guard let provider else { completion(.failure(.transport)); return }
        provider.packetFlow.readPackets { packets, families in
            completion(.success(.init(packets: packets, families: families.map(\.int32Value))))
        }
    }

    public func write(_ packet: Data, family: Int32) -> Bool {
        provider?.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: family)]) == true
    }
}
