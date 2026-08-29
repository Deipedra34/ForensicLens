import Foundation

/// Runs `BatchFileAnalyzer` across a list of files concurrently, bounded to
/// at most `maxConcurrency` analyses in flight at a time.
///
/// Concurrency is capped with a manual "keep N tasks in flight" loop over
/// `TaskGroup`, rather than firing off one child task per file. Batches can
/// be hundreds of images deep and each analysis is CPU-heavy, so starting
/// them all at once would oversubscribe the machine instead of speeding
/// anything up -- `--max-concurrency` (default: the core count) is what
/// keeps that bounded.
enum BatchRunner {
    /// - Parameters:
    ///   - onFileComplete: Invoked once per file, right after that file's
    ///     result has been collected, with the result and a running
    ///     `(completed, total)` count. Called serially, from this
    ///     function's own task, one file at a time -- never concurrently --
    ///     so it's safe to write straight to `stderr` from it without any
    ///     extra synchronization.
    static func run(
        files: [String],
        analyzer: BatchFileAnalyzer,
        maxConcurrency: Int,
        onFileComplete: (@Sendable (BatchAnalysisResult, _ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> [BatchAnalysisResult] {
        guard !files.isEmpty else { return [] }

        let limit = max(1, maxConcurrency)
        let total = files.count

        return await withTaskGroup(of: BatchAnalysisResult.self) { group -> [BatchAnalysisResult] in
            var results: [BatchAnalysisResult] = []
            results.reserveCapacity(total)
            var remaining = files[...]

            func scheduleNext() {
                guard let path = remaining.first else { return }
                remaining = remaining.dropFirst()
                group.addTask { analyzer.analyze(filePath: path) }
            }

            for _ in 0..<min(limit, total) {
                scheduleNext()
            }

            while let result = await group.next() {
                results.append(result)
                onFileComplete?(result, results.count, total)
                scheduleNext()
            }

            return results
        }
    }
}
