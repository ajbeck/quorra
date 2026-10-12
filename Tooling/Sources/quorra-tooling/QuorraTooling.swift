import ArgumentParser
import Foundation
import QuorraTooling

@main
struct QuorraToolingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quorra-tooling",
        abstract: "Build and check Quorra's bundled OpenVPN core.",
        subcommands: [Build.self, Check.self]
    )

    static func main() {
        // Keep this output in order with the output of child processes.
        setvbuf(stdout, nil, _IOLBF, 0)
        main(nil)
    }
}

struct RootOptions: ParsableArguments {
    @Option(help: "The repository root. The default is the nearest directory with quorra.xcodeproj.")
    var root: String?

    func url() throws -> URL {
        try root.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL } ?? Repository.root()
    }
}

/// Runs a command body that starts child processes.
/// A signal stops the current child, and the command exits with the shell-style status.
func guarded(_ body: () throws -> Void) throws {
    Signals.install()
    do {
        try body()
    } catch let interrupted as Interrupted {
        throw ExitCode(interrupted.status)
    } catch let failure as ToolingFailure {
        standardError(failure.description)
        throw ExitCode.failure
    }
}

struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build the VPN core or its SwiftPM package.", subcommands: [VPNCoreReview.self, VPNPackage.self])

    struct VPNCoreReview: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "vpn-core-review", abstract: "Build and check the pinned VPN core without installing or connecting.")
        @OptionGroup var options: RootOptions
        @Option(help: "The directory containing the checksum-pinned archives listed in sources.json.") var archives: String
        @Option(help: "A new directory for sources, build products and check evidence.") var output: String
        @Flag(help: "Download the checksum-pinned inputs into a new archives directory before the offline build.") var download = false

        func run() throws {
            try guarded {
                if download { try ClientVPNCoreReview.download(root: options.url(), archives: URL(fileURLWithPath: archives)) }
                print(try ClientVPNCoreReview.build(root: options.url(), archives: URL(fileURLWithPath: archives), output: URL(fileURLWithPath: output)))
            }
        }
    }

    struct VPNPackage: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "vpn-package", abstract: "Package the approved VPN core and its source/notices for SwiftPM.")
        @OptionGroup var options: RootOptions
        @Option(help: "The completed native core review directory.") var review: String
        @Option(help: "A new directory for the package artifacts.") var output: String

        func run() throws {
            try guarded {
                print(try ClientVPNCorePackage.build(root: options.url(), review: URL(fileURLWithPath: review), output: URL(fileURLWithPath: output)))
            }
        }
    }
}

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run offline checks.", subcommands: [VPNPackage.self])

    struct VPNPackage: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "vpn-package", abstract: "Check native VPN artifacts, notices and source against their manifest.")
        @OptionGroup var options: RootOptions
        @Option(help: "Also compare a freshly rebuilt native package.") var rebuilt: String?

        func run() throws {
            try guarded { print(try ClientVPNCorePackage.check(root: options.url(), rebuilt: rebuilt.map { URL(fileURLWithPath: $0) })) }
        }
    }
}
