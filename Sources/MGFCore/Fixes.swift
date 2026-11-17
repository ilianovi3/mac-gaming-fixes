import Darwin
import Foundation

public enum FixError: LocalizedError, Equatable {
    case missing(String)            // a file the fix needs is not there
    case unexpected(String)         // a file is not what a stock CrossOver ships
    case tool(String, Int32, String)

    public var errorDescription: String? {
        switch self {
        case .missing(let path): return "missing: \(path)"
        case .unexpected(let path): return "unexpected file, not touching it: \(path)"
        case .tool(let name, let code, let output): return "\(name) exited \(code): \(output)"
        }
    }
}

/// Knobs of the wineserver wrapper. They travel as environment variables in the wrapper script,
/// so the script on disk is the single source of truth for what is applied.
public struct WineserverConfig: Equatable {
    /// Share of one core above which registry saves are deferred. 0 turns the deferral off.
    public var busyCpu: Double
    /// SO_NET_SERVICE_TYPE for UDP sockets: 3 interactive video, 4 voice, 0 leaves sockets alone.
    public var udpService: Int
    /// File that gets one line per registry decision, nil for no log.
    public var log: String?

    public init(busyCpu: Double, udpService: Int, log: String?) {
        self.busyCpu = busyCpu; self.udpService = udpService; self.log = log
    }
    public var isIdle: Bool { busyCpu <= 0 && udpService == 0 }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    var script: String { script(server: "wineserver") }

    /// The wrapper that stands in for `bin/<server>` and runs `bin/<server>.real`.
    func script(server: String) -> String {
        var env = "REGSAVE_BUSY_CPU=\(busyCpu) UDP_SERVICE_TYPE=\(udpService) "
        if let log, !log.isEmpty { env += "REGSAVE_LOG=\(Self.quote(log)) " }
        return """
        #!/bin/sh
        # mgf: injects wineserver_fix.dylib into the Wine server. The untouched original is \(server).orig.
        # https://github.com/been-earth/mac-gaming-fixes
        d=$(dirname "$0")
        \(env)DYLD_INSERT_LIBRARIES="$d/wineserver_fix.dylib" exec "$d/\(server).real" "$@"

        """
    }

    /// Reads a wrapper back, including the one the original shell installer wrote. nil = not a wrapper.
    init?(script: String) {
        guard script.hasPrefix("#!"), script.contains("wineserver_fix.dylib") else { return nil }
        func capture(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
                  let r = Range(m.range(at: 1), in: script) else { return nil }
            return String(script[r])
        }
        busyCpu = capture(#"REGSAVE_BUSY_CPU=([0-9.]+)"#).flatMap(Double.init) ?? 0.05
        udpService = capture(#"UDP_SERVICE_TYPE=([0-9]+)"#).flatMap(Int.init) ?? 3
        log = capture(#"REGSAVE_LOG='((?:[^']|'\\'')*)'"#)?.replacingOccurrences(of: "'\\''", with: "'")
            ?? capture(#"REGSAVE_LOG="\$\{REGSAVE_LOG:-([^}]*)\}""#)
    }
}

/// Installs and removes the two patches inside a CrossOver bundle. Every original file is kept
/// next to its replacement, and new files are renamed into place so running games keep the old ones.
/// A bundle with several Wine servers or unix library directories (CrossOver Preview) gets each one patched.
public struct Fixes: @unchecked Sendable {
    public let crossover: CrossOver
    /// Directory holding wineserver_fix.dylib and the winecoreaudio.so wrapper.
    public let payload: URL
    private let fm = FileManager.default

    public init(crossover: CrossOver, payload: URL) { self.crossover = crossover; self.payload = payload }

    private var bin: URL { crossover.bin }
    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    private func sibling(_ url: URL, _ suffix: String) -> URL { url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix) }

    // MARK: wineserver (registry save deferral + UDP tagging)

    /// nil when a stock server is in place, or the servers do not all carry the same wrapper.
    public func wineserverConfig() -> WineserverConfig? {
        Self.agreed(crossover.wineservers.map(wineserverConfig(of:)))
    }

    private func wineserverConfig(of server: URL) -> WineserverConfig? {
        guard exists(sibling(server, ".orig")),
              let handle = try? FileHandle(forReadingFrom: server),
              let head = try? handle.read(upToCount: 4096), let script = String(data: head, encoding: .utf8) else { return nil }
        return WineserverConfig(script: script)
    }

    public func installWineserver(_ config: WineserverConfig) throws {
        let servers = crossover.wineservers
        guard !servers.isEmpty else { throw FixError.missing(bin.appendingPathComponent("wineserver").path) }
        // Check every server before touching any, so a bundle is never left half patched by a stranger's file.
        for server in servers where !exists(sibling(server, ".orig")) {
            guard Self.isMachO(server) else { throw FixError.unexpected(server.path) }
        }
        try place(payload.appendingPathComponent("wineserver_fix.dylib"), at: bin.appendingPathComponent("wineserver_fix.dylib"))
        if let log = config.log, !log.isEmpty {
            try? fm.createDirectory(at: URL(fileURLWithPath: log).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        for server in servers { try installWineserver(config, at: server) }
        try? fm.removeItem(at: bin.appendingPathComponent("regsave_defer.dylib")) // name used by the first shell installer
    }

    private func installWineserver(_ config: WineserverConfig, at server: URL) throws {
        let orig = sibling(server, ".orig")
        let original = exists(orig) ? orig : server
        // The signed server has the hardened runtime, which ignores DYLD_INSERT_LIBRARIES: run a copy
        // signed ad hoc, which has none. Apple silicon refuses to run arm64 code with no signature at all.
        try place(original, at: sibling(server, ".real")) { copy in
            try Self.run("/usr/bin/xattr", ["-c", copy.path])
            try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", copy.path])
        }
        if original == server { try place(server, at: orig) }
        // The server itself is replaced last, so a failure on the way leaves CrossOver working.
        try write(Data(config.script(server: server.lastPathComponent).utf8), to: server, mode: 0o755)
    }

    public func uninstallWineserver() throws {
        var restored = false
        for server in crossover.wineservers {
            let orig = sibling(server, ".orig")
            guard exists(orig) else { continue }
            try rename(orig, to: server)
            try? fm.removeItem(at: sibling(server, ".real"))
            restored = true
        }
        guard restored else { return }
        for name in ["wineserver_fix.dylib", "regsave_defer.dylib"] {
            try? fm.removeItem(at: bin.appendingPathComponent(name))
        }
    }

    // MARK: audio driver wrapper (IO buffer length)

    /// IO buffer length the installed wrappers use, nil when a stock driver is in place or they disagree.
    public func audioIOms() -> Double? {
        Self.agreed(crossover.unixLibDirs.map(audioIOms(in:)))
    }

    private func audioIOms(in unix: URL) -> Double? {
        guard exists(unix.appendingPathComponent("winecoreaudio.so.orig")), exists(unix.appendingPathComponent("winecoreaudio_real.so")) else { return nil }
        let text = (try? String(contentsOf: unix.appendingPathComponent("mgf_audio_io_ms"), encoding: .utf8)) ?? ""
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 512 * 1000.0 / 96000
    }

    public func installAudio(ioMs: Double) throws {
        let dirs = crossover.unixLibDirs
        guard !dirs.isEmpty else { throw FixError.missing(crossover.support.appendingPathComponent("lib/wine/x86_64-unix/winecoreaudio.so").path) }
        // Check every driver before touching any.
        for unix in dirs where !exists(unix.appendingPathComponent("winecoreaudio.so.orig")) {
            let driver = unix.appendingPathComponent("winecoreaudio.so")
            // the real driver exports the unixlib call table; our wrapper only re-exports it
            guard let data = try? Data(contentsOf: driver), data.range(of: Data("__wine_unix_call_funcs".utf8)) != nil else {
                throw FixError.unexpected(driver.path)
            }
        }
        for unix in dirs {
            let driver = unix.appendingPathComponent("winecoreaudio.so")
            let orig = unix.appendingPathComponent("winecoreaudio.so.orig")
            if !exists(orig) { try fm.copyItem(at: driver, to: orig) }
            try place(orig, at: unix.appendingPathComponent("winecoreaudio_real.so"))
            try write(Data("\(ioMs)\n".utf8), to: unix.appendingPathComponent("mgf_audio_io_ms"), mode: 0o644)
            try place(payload.appendingPathComponent("winecoreaudio.so"), at: driver)
        }
    }

    public func uninstallAudio() throws {
        for unix in crossover.unixLibDirs {
            let orig = unix.appendingPathComponent("winecoreaudio.so.orig")
            guard exists(orig) else { continue }
            try rename(orig, to: unix.appendingPathComponent("winecoreaudio.so"))
            try? fm.removeItem(at: unix.appendingPathComponent("winecoreaudio_real.so"))
            try? fm.removeItem(at: unix.appendingPathComponent("mgf_audio_io_ms"))
        }
    }

    /// The value every item agrees on; nil when one has none or two disagree.
    static func agreed<T: Equatable>(_ values: [T?]) -> T? {
        guard let first = values.first ?? nil, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    // MARK: file plumbing

    /// Copies `source` next to `destination`, lets `prepare` adjust the copy, then renames it into place.
    private func place(_ source: URL, at destination: URL, prepare: (URL) throws -> Void = { _ in }) throws {
        guard exists(source) else { throw FixError.missing(source.path) }
        let staged = destination.appendingPathExtension("new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        // A downloaded app is quarantined, and a copy takes the flag along: Gatekeeper would then stop Wine from loading the library.
        removexattr(staged.path, "com.apple.quarantine", 0)
        do { try prepare(staged) } catch { try? fm.removeItem(at: staged); throw error }
        try rename(staged, to: destination)
    }

    private func write(_ data: Data, to destination: URL, mode: Int) throws {
        let staged = destination.appendingPathExtension("new")
        try data.write(to: staged)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path)
        try rename(staged, to: destination)
    }

    /// rename(2): replaces the destination in one step.
    private func rename(_ from: URL, to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: to.path])
        }
    }

    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [0xfeed_facf, 0xcffa_edfe, 0xcafe_babe, 0xbeba_feca].contains(magic)
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixError.tool((tool as NSString).lastPathComponent, process.terminationStatus,
                                String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// The same fixes kept in several CrossOver bundles side by side (say, a stable and a preview build):
/// every change goes into each of them, and a fix counts as applied only when all of them carry it alike.
public struct FixSet: @unchecked Sendable {
    public let members: [Fixes]

    public init(crossovers: [CrossOver], payload: URL) {
        members = crossovers.map { Fixes(crossover: $0, payload: payload) }
    }

    public func wineserverConfig() -> WineserverConfig? { Fixes.agreed(members.map { $0.wineserverConfig() }) }
    public func audioIOms() -> Double? { Fixes.agreed(members.map { $0.audioIOms() }) }

    public func installWineserver(_ config: WineserverConfig) throws { for fixes in members { try fixes.installWineserver(config) } }
    public func uninstallWineserver() throws { for fixes in members { try fixes.uninstallWineserver() } }
    public func installAudio(ioMs: Double) throws { for fixes in members { try fixes.installAudio(ioMs: ioMs) } }
    public func uninstallAudio() throws { for fixes in members { try fixes.uninstallAudio() } }
}
