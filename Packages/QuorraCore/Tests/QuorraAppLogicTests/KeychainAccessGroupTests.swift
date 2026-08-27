import Testing
@testable import QuorraAppLogic

struct KeychainAccessGroupTests {
    @Test func resolvesSharedGroupFromEntitlementsWhenInfoPlistPrefixIsMissing() {
        let resolved = KeychainAccessGroup.resolve(
            infoDictionary: [:],
            keychainAccessGroups: [
                "9GEBAJV9R4.dev.ajbeck.quorra.shared",
                "9GEBAJV9R4.dev.ajbeck.quorra"
            ]
        )

        #expect(resolved == "9GEBAJV9R4.dev.ajbeck.quorra.shared")
    }
}
