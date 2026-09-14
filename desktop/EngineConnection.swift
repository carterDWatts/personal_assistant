import Foundation

@MainActor
final class EngineConnection {
    var onEvent: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?
    private let settings: [String: Any]
    private var process: Process?
    private var input: FileHandle?
    private var outputTask: Task<Void, Never>?
    private var buffer = Data()
    private var generation = UUID()
    private var heartbeat: Task<Void, Never>?
    private var lastEvent = ContinuousClock.now
    private let heartbeatInterval: Duration
    private let heartbeatTimeout: Duration

    init(settings: [String: Any] = Bundle.main.infoDictionary ?? [:], heartbeatInterval: Duration = .seconds(10), heartbeatTimeout: Duration = .seconds(30)) {
        self.settings = settings
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatTimeout = heartbeatTimeout
    }

    func start(test: Bool) throws {
        close()
        guard let root = settings["AssistantRoot"] as? String,
              let python = settings["AssistantPython"] as? String else {
            throw CocoaError(.fileNoSuchFile)
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = ["-m", "engine.desktop"]
        child.currentDirectoryURL = URL(fileURLWithPath: root)
        var environment = ProcessInfo.processInfo.environment
        environment["ASSISTANT_ENV"] = test ? "test" : "prod"
        environment["PYTHONUNBUFFERED"] = "1"
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        let epoch = generation
        let output = outputStream(from: stdout.fileHandleForReading)
        outputTask = Task { @MainActor [weak self] in
            for await data in output {
                guard let self, self.generation == epoch else { return }
                self.buffer.append(data)
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer[..<end]
                    self.buffer.removeSubrange(...end)
                    if let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        self.lastEvent = .now
                        if event["type"] as? String == "ready", self.heartbeat == nil { self.watchHealth() }
                        self.onEvent?(event)
                    }
                    // A callback may reconnect while this chunk still has old events.
                    guard self.generation == epoch else { return }
                }
            }
            guard let self, self.generation == epoch else { return }
            // EOF follows the final buffered event; process termination can race it.
            self.close()
            self.onClose?()
        }
    }

    private func watchHealth() {
        heartbeat = Task { [weak self, heartbeatInterval, heartbeatTimeout] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: heartbeatInterval) } catch { return }
                guard let self else { return }
                do {
                    guard self.lastEvent.duration(to: .now) < heartbeatTimeout else { throw URLError(.timedOut) }
                    try self.send(["type": "ping"])
                } catch {
                    self.close()
                    self.onClose?()
                    return
                }
            }
        }
    }

    func send(_ value: [String: Any]) throws {
        guard let input else { throw CocoaError(.fileWriteUnknown) }
        let data = try JSONSerialization.data(withJSONObject: value)
        try input.write(contentsOf: data + Data([10]))
    }

    func close(immediately: Bool = false) {
        generation = UUID()
        heartbeat?.cancel(); heartbeat = nil
        outputTask?.cancel()
        outputTask = nil
        try? send(["type": "quit"])
        try? input?.close()
        if let child = process, child.isRunning {
            if immediately { child.terminate() }
            else { Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if child.isRunning { child.terminate() }
            } }
        }
        process = nil
        input = nil
        buffer = Data()
    }
}
