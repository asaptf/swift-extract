import Foundation

/// Runs ingest work off Swift's cooperative thread pool.
///
/// PDFKit rasterisation and `VNImageRequestHandler.perform` are synchronous, so calling
/// them from `async` code parks a cooperative-pool thread for the whole operation. The
/// pool holds roughly one thread per core, so enough concurrent extractions park every
/// thread and the process stops making progress — nothing is left to run the work that
/// would release them. Measured on a 15-core machine: 8 concurrent OCR extractions finish
/// in 1.3s, 16 never finish.
///
/// Moving the blocking section to a dedicated queue keeps the cooperative pool free, but
/// unbounded concurrency then deadlocks Vision instead: it dispatches synchronously onto
/// its own capacity-limited queue (`VNControlledCapacityTasksQueue`) and oversubscribing
/// that wedges just as hard — measured at 64 concurrent extractions. So the queue is
/// bounded to the core count. That is not a tuning constant picked by feel: OCR is
/// CPU-bound, so more in-flight requests than cores buys no throughput and only starves
/// Vision. Verified: 64 and 256 concurrent extractions both finish.
enum IngestExecutor {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.swift-extract.ingest"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return queue
    }()

    /// Awaits `body` on the ingest queue.
    ///
    /// `body` and its result are moved across threads without a `Sendable` requirement:
    /// ingest deals in `CGImage` / `PDFPage`, which are not `Sendable`. That is sound here
    /// because ownership *transfers* — the calling task suspends until `body` returns, so
    /// exactly one thread touches those values at any moment.
    static func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        let work = UnsafeTransfer(value: body)
        let outcome: UnsafeTransfer<Result<T, Error>> = await withCheckedContinuation { continuation in
            queue.addOperation {
                continuation.resume(returning: UnsafeTransfer(value: Result { try work.value() }))
            }
        }
        return try outcome.value.get()
    }
}

/// Carries a non-`Sendable` value across a thread hop where ownership transfers.
private struct UnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
}
