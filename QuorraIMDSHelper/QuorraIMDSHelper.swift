import Foundation
import QuorraIMDSHelperCore
import QuorraIPC

@main
enum QuorraIMDSHelper {
    @MainActor
    static func main() {
        let service = IMDSHelperService()
        let delegate = IMDSHelperXPCListenerDelegate(service: service)
        let listener = NSXPCListener(
            machServiceName: QuorraIMDSHelperXPC.machServiceName
        )
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(
            QuorraIMDSHelperXPC.appCodeSigningRequirement
        )
        listener.activate()
        RunLoop.current.run()
    }
}
