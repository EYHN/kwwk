import Foundation
import Testing
@testable import KWCoding

@Suite("File mutation queue")
struct FileMutationQueueTests {
    @Test("serializes writes against the same path")
    func serializesSamePath() async throws {
        let queue = FileMutationQueue()
        let recorder = ConcurrencyRecorder()

        async let a: Void = {
            try? await queue.run("/tmp/same.txt") {
                await recorder.tag("a-start")
                try? await Task.sleep(nanoseconds: 10_000_000)
                await recorder.tag("a-end")
            }
        }()
        async let b: Void = {
            try? await queue.run("/tmp/same.txt") {
                await recorder.tag("b-start")
                try? await Task.sleep(nanoseconds: 10_000_000)
                await recorder.tag("b-end")
            }
        }()
        _ = await (a, b)

        let events = await recorder.all
        // a-start / a-end must precede b-start / b-end (or vice versa) — never interleave.
        let aEnd = events.firstIndex(of: "a-end") ?? -1
        let bStart = events.firstIndex(of: "b-start") ?? -1
        let bEnd = events.firstIndex(of: "b-end") ?? -1
        let aStart = events.firstIndex(of: "a-start") ?? -1
        let firstEndsBeforeSecondStarts = (aEnd < bStart) || (bEnd < aStart)
        #expect(firstEndsBeforeSecondStarts)
    }

    @Test("runs unrelated paths in parallel")
    func parallelDifferentPaths() async throws {
        let queue = FileMutationQueue()
        let recorder = ConcurrencyRecorder()

        async let a: Void = {
            try? await queue.run("/tmp/a.txt") {
                await recorder.tag("a-start")
                try? await Task.sleep(nanoseconds: 20_000_000)
                await recorder.tag("a-end")
            }
        }()
        async let b: Void = {
            try? await queue.run("/tmp/b.txt") {
                await recorder.tag("b-start")
                try? await Task.sleep(nanoseconds: 20_000_000)
                await recorder.tag("b-end")
            }
        }()
        _ = await (a, b)

        let events = await recorder.all
        // The starts must interleave before either end: b-start before a-end and vice versa.
        guard let aStart = events.firstIndex(of: "a-start"),
              let bStart = events.firstIndex(of: "b-start"),
              let aEnd = events.firstIndex(of: "a-end"),
              let bEnd = events.firstIndex(of: "b-end") else {
            Issue.record("expected all 4 tags")
            return
        }
        #expect(bStart < aEnd || aStart < bEnd)
    }

    @Test("propagates thrown errors")
    func propagatesErrors() async {
        struct Boom: Error {}
        let queue = FileMutationQueue()
        await #expect(throws: Boom.self) {
            _ = try await queue.run("/tmp/err.txt") {
                throw Boom()
            }
        }
    }
}

actor ConcurrencyRecorder {
    var events: [String] = []
    func tag(_ s: String) { events.append(s) }
    var all: [String] { events }
}
