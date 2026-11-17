import AppKit

/// A CrossOver installation: the bundle the fixes are written into.
///
/// Stable builds ship one `bin/wineserver` and the unix side of Wine in `lib/wine/x86_64-unix`.
/// Preview builds with native arm64 support ship `bin/wineserver-x86` and `bin/wineserver-arm64`
/// instead, and a second `lib/wine/aarch64-unix`. `bin/wine` picks the server and the unix directory
/// per bottle, so the fixes go into every one of them.
public struct CrossOver: Equatable {
    public let bundle: URL

    public init(bundle: URL) { self.bundle = bundle.standardizedFileURL }
    public init(path: String) { self.init(bundle: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }

    public var support: URL { bundle.appendingPathComponent("Contents/SharedSupport/CrossOver") }
    public var bin: URL { support.appendingPathComponent("bin") }

    /// Names the Wine server goes by: stable builds use the first, preview builds the other two.
    public static let serverNames = ["wineserver", "wineserver-x86", "wineserver-arm64"]
    /// Unix-side library directories, one per host architecture.
    public static let unixDirNames = ["x86_64-unix", "aarch64-unix"]

    /// Every Wine server in the bundle, patched or not.
    public var wineservers: [URL] {
        Self.serverNames.map { bin.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every unix library directory that holds a CoreAudio driver.
    public var unixLibDirs: [URL] {
        Self.unixDirNames.map { support.appendingPathComponent("lib/wine").appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("winecoreaudio.so").path) }
    }

    /// The audio driver in each unix library directory.
    public var audioDrivers: [URL] { unixLibDirs.map { $0.appendingPathComponent("winecoreaudio.so") } }

    /// True when the bundle holds a Wine server, patched or not.
    public var isValid: Bool { !wineservers.isEmpty }

    /// Whether macOS lets this process change files in the bundle (App Management). Opens a Wine
    /// server for writing and closes it again: not a byte is written. nil when there is no server to try.
    public var isWritable: Bool? {
        guard let server = wineservers.first else { return nil }
        let fd = open(server.path, O_WRONLY)
        if fd >= 0 { close(fd); return true }
        return errno == ENOENT ? nil : false
    }

    public var version: String? {
        let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return plist?["CFBundleShortVersionString"] as? String
    }

    /// Every CrossOver found where it usually lives (stable first, then preview), then wherever Launch Services knows it.
    public static func detectAll() -> [CrossOver] {
        var candidates = ["~/Applications/CrossOver.app", "/Applications/CrossOver.app",
                          "~/Applications/CrossOver Preview.app", "/Applications/CrossOver Preview.app"].map(CrossOver.init(path:))
        if let known = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.codeweavers.CrossOver") {
            candidates.append(CrossOver(bundle: known))
        }
        var found: [CrossOver] = []
        for candidate in candidates where candidate.isValid && !found.contains(candidate) { found.append(candidate) }
        return found
    }

    /// The first CrossOver detectAll() finds.
    public static func detect() -> CrossOver? { detectAll().first }
}
