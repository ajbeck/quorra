import Darwin
import Dispatch
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

        let terminationSources = makeTerminationSources(service: service)
        withExtendedLifetime(terminationSources) {
            RunLoop.current.run()
        }
    }

    @MainActor
    private static func makeTerminationSources(
        service: IMDSHelperService
    ) -> [any DispatchSourceSignal] {
        [SIGTERM, SIGINT].map { signalNumber in
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler {
                Task { @MainActor [service] in
                    let exitCode: Int32
                    do {
                        try service.disable()
                        exitCode = EXIT_SUCCESS
                    } catch {
                        exitCode = EXIT_FAILURE
                    }
                    Darwin.exit(exitCode)
                }
            }
            source.activate()
            return source
        }
    }
}
