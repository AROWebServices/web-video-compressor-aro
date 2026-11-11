import Foundation

public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

/// Runs a subprocess off the calling thread. Cancelling the surrounding task
/// terminates the process.
public enum ProcessRunner {
    public static func run(
        _ executable: URL, _ arguments: [String],
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessOutput {
        let job = Job(executable: executable, arguments: arguments, onLine: onStdoutLine)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.start(continuation)
            }
        } onCancel: {
            job.cancel()
        }
    }
}

/// All mutable state is guarded by `lock`; Process and Pipe are only touched
/// from `start`, `cancel` (under the lock) and the process's own callbacks.
private final class Job: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let onLine: (@Sendable (String) -> Void)?

    private var out = Data()
    private var err = Data()
    private var pendingLine = Data()
    private var started = false
    private var cancelled = false

    init(executable: URL, arguments: [String], onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe
    }

    func start(_ continuation: CheckedContinuation<ProcessOutput, Error>) {
        outPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { consumeStdout(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { lock.withLock { err.append(data) } }
        }
        process.terminationHandler = { [self] finished in
            stopReading()
            if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                consumeStdout(rest)
            }
            if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                lock.withLock { err.append(rest) }
            }
            let (lastLine, result) = lock.withLock {
                (String(data: pendingLine, encoding: .utf8),
                 ProcessOutput(status: finished.terminationStatus, stdout: out, stderr: err))
            }
            if let lastLine, !lastLine.isEmpty { onLine?(lastLine) }
            continuation.resume(returning: result)
        }

        lock.lock()
        if cancelled {
            lock.unlock()
            stopReading()
            continuation.resume(throwing: CancellationError())
            return
        }
        do {
            try process.run()
            started = true
            lock.unlock()
        } catch {
            lock.unlock()
            stopReading()
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if started && process.isRunning { process.terminate() }
        }
    }

    private func stopReading() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func consumeStdout(_ data: Data) {
        let lines: [String] = lock.withLock {
            out.append(data)
            pendingLine.append(data)
            var found: [String] = []
            while let newline = pendingLine.firstIndex(of: 0x0A) {
                let lineData = pendingLine[pendingLine.startIndex..<newline]
                if let line = String(data: lineData, encoding: .utf8) { found.append(line) }
                pendingLine = Data(pendingLine[pendingLine.index(after: newline)...])
            }
            return found
        }
        guard let onLine else { return }
        for line in lines { onLine(line) }
    }
}
