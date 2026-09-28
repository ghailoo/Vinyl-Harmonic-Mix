import Foundation

// Shared runner for the Essentia analysis and cue-detection Python scripts.
//
// Both pipes are drained concurrently via FileHandle.bytes, so no mutable buffer is ever
// shared between threads (the old readabilityHandler version appended to captured vars
// from GCD threads and could race with the final read). Draining while the process runs
// also keeps a chatty stderr from filling the kernel pipe buffer and hanging Python.
nonisolated enum Subprocess {
    struct Output: Sendable {
        let stdout: Data
        let stderr: Data
        let status: Int32
    }

    /// Runs `executable`, returning once it has exited and both pipes hit EOF. After
    /// `timeout` the process is terminated, then SIGKILLed one second later if still alive.
    /// Throws only if the process can't be launched.
    static func run(_ executable: String, arguments: [String], timeout: Duration) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe
        try process.run()

        // Unstructured on purpose: cancelling it once output is complete skips the kill.
        // isRunning guards match the old loop and avoid signalling a recycled pid.
        let watchdog = Task.detached {
            try await Task.sleep(for: timeout)
            guard process.isRunning else { return }
            process.terminate()
            try await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        async let out = drain(stdoutPipe.fileHandleForReading)
        async let err = drain(stderrPipe.fileHandleForReading)
        let (stdout, stderr) = await (out, err)
        watchdog.cancel()
        process.waitUntilExit()
        return Output(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }

    private static func drain(_ handle: FileHandle) async -> Data {
        var data = Data()
        do {
            for try await byte in handle.bytes { data.append(byte) }
        } catch {}   // read error: keep what arrived, same as the old best-effort drain
        return data
    }
}
