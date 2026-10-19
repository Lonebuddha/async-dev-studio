import Combine
import Darwin
import Foundation
import PTYSupport

public enum TerminalState: Equatable {
    case stopped, running, exited(Int32), failed(String)
}

/// One PTY and shell per instance; view selection never creates another shell.
@MainActor
public final class TerminalSession: ObservableObject {
    @Published public private(set) var state: TerminalState = .stopped
    @Published public private(set) var processID: pid_t?
    public var onOutput: ((Data) -> Void)?
    public private(set) var configuration: TerminalConfiguration
    private var nextConfiguration: TerminalConfiguration?
    private let inheritedEnvironment: [String: String]
    private var master: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var monitor: DispatchSourceProcess?
    private var pendingInput = Data()
    private var stopping = false
    private var columns = 80
    private var rows = 24

    public init(configuration: TerminalConfiguration, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.configuration = configuration
        inheritedEnvironment = environment
    }

    public func start() throws {
        guard processID == nil else { return }
        do {
            let configuration = nextConfiguration ?? self.configuration
            try configuration.validate()
            let arguments = [configuration.shell] + configuration.arguments
            var environment = TerminalEnvironment.utf8(inheritedEnvironment)
            environment["TERM"] = "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            environment["SHELL"] = configuration.shell
            environment["PWD"] = configuration.workingDirectory
            // GUI launches often have a small PATH. Preserve it and include standard tool locations.
            let paths = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
            environment["PATH"] = (paths + ["/opt/homebrew/bin", "/usr/local/bin"].filter { !paths.contains($0) }).joined(separator: ":")
            let argv = arguments.map { strdup($0) } + [nil]
            let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var fd: Int32 = -1
            var execError: Int32 = 0
            let pid = argv.withUnsafeBufferPointer { argvPointer in
                envp.withUnsafeBufferPointer { envPointer in
                    studio_pty_spawn(configuration.shell, argvPointer.baseAddress, envPointer.baseAddress,
                                     configuration.workingDirectory, UInt16(columns), UInt16(rows), &fd, &execError)
                }
            }
            guard pid > 0 else { throw TerminalError.system("Couldn’t start shell", execError == 0 ? errno : execError) }
            self.configuration = configuration
            nextConfiguration = nil
            master = fd
            processID = pid
            stopping = false
            pendingInput.removeAll()
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

            let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            readSource.setEventHandler { [weak self] in self?.readAvailableOutput() }
            readSource.setCancelHandler { close(fd) }
            reader = readSource
            readSource.activate()

            let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            // Keep the session alive until the child has been reaped, even if its tab closes.
            exitSource.setEventHandler { [self] in finishProcess(pid) }
            monitor = exitSource
            state = .running
            exitSource.activate()
            send(configuration.startupInput)
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func configureForNextStart(_ configuration: TerminalConfiguration) throws {
        try configuration.validate()
        nextConfiguration = configuration
    }

    public func send(_ data: Data) {
        guard master >= 0, processID != nil, !stopping else { return }
        pendingInput.append(data)
        flushInput()
    }

    public func resize(columns: Int, rows: Int) throws {
        self.columns = min(max(columns, 1), Int(UInt16.max))
        self.rows = min(max(rows, 1), Int(UInt16.max))
        guard master >= 0 else { return }
        guard studio_pty_resize(master, UInt16(self.columns), UInt16(self.rows)) == 0 else {
            throw TerminalError.system("Couldn’t resize terminal", errno)
        }
    }

    public func stop() {
        guard let pid = processID, !stopping else { return }
        stopping = true
        state = .stopped
        let foreground = master >= 0 ? tcgetpgrp(master) : -1
        if foreground > 0 && foreground != pid { kill(-foreground, SIGHUP); kill(-foreground, SIGTERM) }
        kill(-pid, SIGHUP)
        kill(-pid, SIGTERM)
        // Bounded shutdown for shells which ignore termination signals.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.processID == pid else { return }
            if foreground > 0 && foreground != pid { kill(-foreground, SIGKILL) }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    private func readAvailableOutput() {
        guard master >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        // Bound each turn so a noisy process cannot monopolize the UI thread.
        for _ in 0..<16 {
            let count = read(master, &bytes, bytes.count)
            if count > 0 { onOutput?(Data(bytes.prefix(count))) }
            else if count < 0 && errno == EINTR { continue }
            else { break }
        }
    }

    private func flushInput() {
        guard master >= 0 else { return }
        while !pendingInput.isEmpty {
            let written = pendingInput.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            if written > 0 { pendingInput.removeFirst(written) }
            else if written < 0 && errno == EINTR { continue }
            else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: .main)
                    source.setEventHandler { [weak self] in self?.flushInput() }
                    writer = source
                    source.activate()
                }
                return
            } else {
                pendingInput.removeAll()
                break
            }
        }
        writer?.cancel()
        writer = nil
    }

    private func finishProcess(_ pid: pid_t) {
        guard processID == pid else { return }
        readAvailableOutput()
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
        let code = result == pid ? Int32(studio_process_exit_code(status)) : -1
        processID = nil
        writer?.cancel(); writer = nil
        reader?.cancel(); reader = nil
        monitor?.cancel(); monitor = nil
        master = -1
        pendingInput.removeAll()
        if !stopping { state = .exited(code) }
    }
}
