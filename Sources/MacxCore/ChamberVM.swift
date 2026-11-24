import Darwin
import Foundation
import Virtualization

/// What the agent printed on the chamber's console, split at its markers.
public struct ChamberConsole: Sendable, Equatable {
    public var ready: Bool
    public var trace: String
    public var output: String
    /// The agent got to the end (the trace wasn't cut off by the time limit).
    public var complete: Bool

    public static func parse(_ text: String) -> ChamberConsole {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        func section(_ start: String, _ end: String) -> (String, Bool) {
            guard let s = lines.firstIndex(of: start) else { return ("", false) }
            let rest = lines[(s + 1)...]
            let e = rest.firstIndex(of: end)
            let body = rest[..<(e ?? rest.endIndex)].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return (body, e != nil)
        }
        let (trace, traceDone) = section("==MACX-TRACE==", "==MACX-END==")
        let (output, _) = section("==MACX-OUTPUT==", "==MACX-OUTPUT-END==")
        return ChamberConsole(ready: lines.contains("==MACX-READY=="), trace: trace, output: output, complete: traceDone)
    }
}

/// Boots the light chamber: Apple's Virtualization framework, the raw kernel and a per-run initramfs, one CPU,
/// 768 MB, one console port and an entropy device. No disk, no network device, no shared folder. The VM is
/// thrown away when the agent powers off or the time limit passes.
public enum ChamberVM {
    public enum Problem: Error, CustomStringConvertible {
        case needsEntitlement
        case configuration(String)
        case startFailed(String)

        public var description: String {
            switch self {
            case .needsEntitlement:
                "This macx can't start virtual machines: it needs the Virtualization entitlement. Use the installed macx (scripts/install.sh signs it with the entitlement)."
            case .configuration(let why): "The chamber's VM setup was refused: \(why)"
            case .startFailed(let why): "The chamber didn't start: \(why)"
            }
        }
    }

    public struct Run: Sendable {
        public var console: ChamberConsole
        public var seconds: Double
        public var stoppedByTimeLimit: Bool
    }

    public static func run(kernel: URL, initramfs: Data, timeLimit: TimeInterval) throws -> Run {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("macx-chamber-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: tmp) }
        let initrd = tmp.appendingPathComponent("initramfs.cpio")
        try initramfs.write(to: initrd)

        let boot = VZLinuxBootLoader(kernelURL: kernel)
        boot.initialRamdiskURL = initrd
        boot.commandLine = "console=hvc0 quiet loglevel=0 rdinit=/init"
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = boot
        config.platform = VZGenericPlatformConfiguration()
        config.cpuCount = 1
        config.memorySize = 768 * 1024 * 1024
        let pipe = Pipe()
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: pipe.fileHandleForWriting)
        config.serialPorts = [port]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        do {
            try config.validate()
        } catch {
            if error.localizedDescription.contains("com.apple.security.virtualization") { throw Problem.needsEntitlement }
            throw Problem.configuration(error.localizedDescription)
        }

        let collected = Collector()
        pipe.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        let queue = DispatchQueue(label: "macx.chamber.vm")
        let state = RunState()
        let started = Date()
        let vm = queue.sync { VZVirtualMachine(configuration: config, queue: queue) }
        let delegate = Delegate(state: state)
        queue.sync {
            vm.delegate = delegate
            vm.start { result in
                if case .failure(let e) = result { state.finish(error: e.localizedDescription) }
            }
        }
        if !state.wait(timeout: timeLimit) {
            state.timedOut = true
            queue.sync { if vm.canStop { vm.stop { _ in state.finish(error: nil) } } else { state.finish(error: nil) } }
            _ = state.wait(timeout: 10)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        Thread.sleep(forTimeInterval: 0.2)
        collected.append(pipe.fileHandleForReading.availableDataIfAny())
        if let e = state.error, !state.timedOut, collected.text.isEmpty { throw Problem.startFailed(e) }
        _ = delegate
        return Run(
            console: ChamberConsole.parse(collected.text), seconds: Date().timeIntervalSince(started), stoppedByTimeLimit: state.timedOut)
    }

    final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        func append(_ d: Data) { lock.withLock { data.append(d.prefix(max(0, 30_000_000 - data.count))) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    final class RunState: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var finished = false
        var error: String?
        var timedOut = false
        func finish(error: String?) {
            lock.withLock {
                guard !finished else { return }
                finished = true
                self.error = error
                done.signal()
            }
        }
        func wait(timeout: TimeInterval) -> Bool { done.wait(timeout: .now() + timeout) == .success }
    }

    final class Delegate: NSObject, VZVirtualMachineDelegate {
        let state: RunState
        init(state: RunState) { self.state = state }
        func guestDidStop(_ virtualMachine: VZVirtualMachine) { state.finish(error: nil) }
        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
            state.finish(error: error.localizedDescription)
        }
    }
}

extension FileHandle {
    /// Whatever is waiting, without blocking when nothing is.
    func availableDataIfAny() -> Data {
        var out = Data()
        let fd = fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        _ = fcntl(fd, F_SETFL, flags)
        return out
    }
}
