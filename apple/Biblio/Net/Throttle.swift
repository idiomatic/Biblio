import Foundation

/// App-wide request pacing so the library sites are not hammered:
/// at most `maxConcurrent` requests in flight and a minimum gap between starts.
actor Throttle {
    static let shared = Throttle(maxConcurrent: 3, minimumGap: .milliseconds(250))

    private let maxConcurrent: Int
    private let minimumGap: Duration
    private var inFlight = 0
    private var lastStart = ContinuousClock.now - .seconds(10)
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int, minimumGap: Duration) {
        self.maxConcurrent = maxConcurrent
        self.minimumGap = minimumGap
    }

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        while inFlight >= maxConcurrent {
            await withCheckedContinuation { waiters.append($0) }
        }
        inFlight += 1
        let next = lastStart + minimumGap
        lastStart = max(ContinuousClock.now, next)
        if next > .now { try? await Task.sleep(until: next, clock: .continuous) }
    }

    private func release() {
        inFlight -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}
