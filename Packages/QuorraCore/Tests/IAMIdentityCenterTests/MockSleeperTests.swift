import Testing

extension IAMIdentityCenterTestSuite {
@Suite("MockSleeper", .serialized, .timeLimit(.minutes(1)))
struct MockSleeperTests {
    @Test("sleep-count waiter observes already-completed sleep")
    func waitForSleepCountHandlesLateWaiter() async throws {
        let sleeper = MockSleeper()

        try await sleeper.sleep(for: 1)
        await sleeper.waitForSleepCount(atLeast: 1)

        #expect(await sleeper.recordedSleeps == [1])
    }
}
}
