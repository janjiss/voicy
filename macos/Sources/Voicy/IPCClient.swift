import Foundation

// IPCClient spawns the Go backend helper and speaks the newline-delimited JSON
// protocol over its stdio: events are read from stdout, commands written to
// stdin.
final class IPCClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "com.voicy.ipc.write")

    private var buffer = Data()

    /// Called on the main queue for every decoded event.
    var onEvent: ((IncomingEvent) -> Void)?
    /// Called on the main queue if the backend exits.
    var onTerminate: (() -> Void)?

    func start() throws {
        process.executableURL = Self.backendURL()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Let backend logging flow to our stderr for debugging.
        process.standardError = FileHandle.standardError

        let handle = stdoutPipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] file in
            let data = file.availableData
            if data.isEmpty {
                file.readabilityHandler = nil
                return
            }
            self?.ingest(data)
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.onTerminate?() }
        }

        try process.run()
    }

    func stop() {
        send(.simple(CommandType.shutdown))
        // Give the backend a brief moment to exit cleanly before forcing it.
        writeQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if self.process.isRunning {
                self.process.terminate()
            }
        }
    }

    func send(_ command: Command) {
        guard let line = try? JSONEncoder().encode(command) else { return }
        var payload = line
        payload.append(0x0A) // newline
        writeQueue.async { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.stdinPipe.fileHandleForWriting.write(payload)
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            if let event = IncomingEvent.decode(lineData) {
                DispatchQueue.main.async { [weak self] in
                    self?.onEvent?(event)
                }
            }
        }
    }

    private static func backendURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["VOICY_BACKEND"] {
            return URL(fileURLWithPath: override)
        }
        // Bundled next to the app's main executable: Contents/MacOS/voicy-backend.
        let dir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        return dir.appendingPathComponent("voicy-backend")
    }
}
