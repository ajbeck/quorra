import Foundation

@main
enum QuorraIMDSHelper {
    static func main() {
        // The launch daemon service loop is added with the authenticated XPC
        // control plane. Keeping this executable inert until then prevents a
        // partially configured helper from changing system state.
    }
}
