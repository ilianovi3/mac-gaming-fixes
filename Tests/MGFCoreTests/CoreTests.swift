import Foundation
import Testing
@testable import MGFCore

/// A throwaway CrossOver bundle: /usr/bin/true stands in for the Wine server, so the real
/// xattr and codesign steps run against a real signed Mach-O. `preview` lays it out like a
/// CrossOver Preview build: wineserver-x86 and wineserver-arm64, and an aarch64-unix next to x86_64-unix.
struct FakeCrossOver {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mgf-test-\(UUID().uuidString)")
    let crossover: CrossOver
    let fixes: Fixes
    let payload: URL
    let serverBytes: Data
    let driverBytes = Data("stock audio driver __wine_unix_call_funcs".utf8)

    init(preview: Bool = false, name: String = "CrossOver.app") throws {
        let fm = FileManager.default
        let crossover = CrossOver(bundle: root.appendingPathComponent(name)), payload = root.appendingPathComponent("payload")
        self.crossover = crossover
        self.payload = payload
        let servers = preview ? ["wineserver-x86", "wineserver-arm64"] : ["wineserver"]
        let unixDirs = (preview ? ["x86_64-unix", "aarch64-unix"] : ["x86_64-unix"])
            .map { crossover.support.appendingPathComponent("lib/wine").appendingPathComponent($0) }
        for dir in [crossover.bin, payload] + unixDirs { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        for server in servers { try fm.copyItem(atPath: "/usr/bin/true", toPath: crossover.bin.appendingPathComponent(server).path) }
        serverBytes = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        for dir in unixDirs { try driverBytes.write(to: dir.appendingPathComponent("winecoreaudio.so")) }
        try Data("fix dylib".utf8).write(to: payload.appendingPathComponent("wineserver_fix.dylib"))
        try Data("audio wrapper".utf8).write(to: payload.appendingPathComponent("winecoreaudio.so"))
        fixes = Fixes(crossover: crossover, payload: payload)
    }

    var server: URL { crossover.wineservers[0] }
    var unix: URL { crossover.unixLibDirs[0] }
    var driver: URL { crossover.audioDrivers[0] }

    func names(in dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Test func gridRowsAreFullForAnyMixOfFixesAndTools() {
    for fixes in 0...9 {
        for tools in 0...6 {
            let kinds = [Bool](repeating: true, count: fixes) + [Bool](repeating: false, count: tools)
            let spans = gridSpans(kinds)
            for row in gridRows(kinds) { #expect(spans[row].reduce(0, +) == 6, "\(fixes) fixes, \(tools) tools") }
            #expect(gridRows(kinds).map(\.count).reduce(0, +) == kinds.count, "\(fixes) fixes, \(tools) tools: a card fell out of the rows")
        }
    }
}

@Test func wrapperScriptReadsBackWhatWasWritten() {
    let quoted = WineserverConfig(busyCpu: 0.05, udpService: 3, log: "/tmp/it's a log/regsave.log")
    #expect(WineserverConfig(script: quoted.script) == quoted)
    let off = WineserverConfig(busyCpu: 0, udpService: 4, log: nil)
    #expect(WineserverConfig(script: off.script) == off)
    // the wrapper the first shell installer wrote
    let legacy = "#!/bin/sh\n# netjitterfix\nd=$(dirname \"$0\")\nREGSAVE_LOG=\"${REGSAVE_LOG:-/tmp/regsave_defer.log}\" DYLD_INSERT_LIBRARIES=\"$d/wineserver_fix.dylib\" exec \"$d/wineserver.real\" \"$@\"\n"
    #expect(WineserverConfig(script: legacy) == WineserverConfig(busyCpu: 0.05, udpService: 3, log: "/tmp/regsave_defer.log"))
    #expect(WineserverConfig(script: "not a wrapper") == nil)
}

@Test func wineserverFixInstallsAndRevertsToTheSameBytes() throws {
    let fake = try FakeCrossOver()
    defer { fake.cleanUp() }
    let bin = fake.crossover.bin
    #expect(fake.fixes.wineserverConfig() == nil)

    let config = WineserverConfig(busyCpu: 0.05, udpService: 3, log: fake.root.appendingPathComponent("logs/regsave.log").path)
    try fake.fixes.installWineserver(config)
    #expect(fake.fixes.wineserverConfig() == config)
    #expect(try Data(contentsOf: bin.appendingPathComponent("wineserver.orig")) == fake.serverBytes)
    #expect(FileManager.default.isExecutableFile(atPath: fake.server.path))
    #expect(signature(of: bin.appendingPathComponent("wineserver.real")) == .adHoc)  // runs on Apple silicon, takes DYLD_INSERT_LIBRARIES
    #expect(fake.names(in: bin) == ["wineserver", "wineserver.orig", "wineserver.real", "wineserver_fix.dylib"])

    // changing a knob rewrites the wrapper and leaves the original alone
    let voice = WineserverConfig(busyCpu: 0, udpService: 4, log: nil)
    try fake.fixes.installWineserver(voice)
    #expect(fake.fixes.wineserverConfig() == voice)
    #expect(try Data(contentsOf: bin.appendingPathComponent("wineserver.orig")) == fake.serverBytes)

    try fake.fixes.uninstallWineserver()
    #expect(try Data(contentsOf: fake.server) == fake.serverBytes)
    #expect(fake.names(in: bin) == ["wineserver"])
    #expect(fake.fixes.wineserverConfig() == nil)
}

@Test func wineserverFixRefusesAServerItDoesNotRecognise() throws {
    let fake = try FakeCrossOver()
    defer { fake.cleanUp() }
    try Data("#!/bin/sh\necho someone else's wrapper\n".utf8).write(to: fake.server)
    #expect(throws: FixError.unexpected(fake.server.path)) {
        try fake.fixes.installWineserver(WineserverConfig(busyCpu: 0.05, udpService: 3, log: nil))
    }
    #expect(fake.names(in: fake.crossover.bin) == ["wineserver"])
}

@Test func audioFixInstallsAndRevertsToTheSameBytes() throws {
    let fake = try FakeCrossOver()
    defer { fake.cleanUp() }
    let unix = fake.unix
    #expect(fake.fixes.audioIOms() == nil)

    try fake.fixes.installAudio(ioMs: 5.33)
    #expect(fake.fixes.audioIOms() == 5.33)
    #expect(try Data(contentsOf: fake.driver) == Data("audio wrapper".utf8))
    #expect(try Data(contentsOf: unix.appendingPathComponent("winecoreaudio.so.orig")) == fake.driverBytes)
    #expect(try Data(contentsOf: unix.appendingPathComponent("winecoreaudio_real.so")) == fake.driverBytes)

    try fake.fixes.installAudio(ioMs: 4)  // again, over our own wrapper: the original must survive
    #expect(fake.fixes.audioIOms() == 4)
    #expect(try Data(contentsOf: unix.appendingPathComponent("winecoreaudio.so.orig")) == fake.driverBytes)

    try fake.fixes.uninstallAudio()
    #expect(try Data(contentsOf: fake.driver) == fake.driverBytes)
    #expect(fake.names(in: unix) == ["winecoreaudio.so"])
}

/// A downloaded app is quarantined, and so is every file in it. A library copied into CrossOver with
/// that flag would make Gatekeeper stop Wine from loading it.
@Test func installedFilesDoNotCarryTheQuarantineFlag() throws {
    let fake = try FakeCrossOver()
    defer { fake.cleanUp() }
    let flag = "com.apple.quarantine", value = Array("0083;00000000;Safari;".utf8)
    func quarantined(_ url: URL) -> Bool { getxattr(url.path, flag, nil, 0, 0, 0) >= 0 }
    for name in ["wineserver_fix.dylib", "winecoreaudio.so"] {
        let file = fake.fixes.payload.appendingPathComponent(name)
        #expect(setxattr(file.path, flag, value, value.count, 0, 0) == 0)
        #expect(quarantined(file))
    }
    try fake.fixes.installWineserver(WineserverConfig(busyCpu: 0.05, udpService: 3, log: nil))
    try fake.fixes.installAudio(ioMs: 5.33)
    #expect(!quarantined(fake.crossover.bin.appendingPathComponent("wineserver_fix.dylib")))
    #expect(!quarantined(fake.driver))
}

@Test func writeProbeTellsAllowedFromRefusedWithoutWriting() throws {
    let fake = try FakeCrossOver()
    defer { fake.cleanUp() }
    let server = fake.server.path
    #expect(fake.crossover.isWritable == true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: server)   // refused, as macOS refuses an app without App Management
    #expect(fake.crossover.isWritable == false)
    #expect(try Data(contentsOf: fake.server) == fake.serverBytes)
    try FileManager.default.removeItem(atPath: server)
    #expect(fake.crossover.isWritable == nil)
}

@Test func autoSwitchOnlyTurnsOffWhatItTurnedOn() {
    var auto = AutoSwitch()
    #expect(auto.update(conditionActive: false, isOn: false) == nil)
    #expect(auto.update(conditionActive: true, isOn: false) == true)    // game starts
    #expect(auto.update(conditionActive: true, isOn: true) == nil)
    #expect(auto.update(conditionActive: false, isOn: true) == false)   // game quits

    #expect(auto.update(conditionActive: true, isOn: true) == nil)      // already on by hand: not ours
    #expect(auto.update(conditionActive: false, isOn: true) == nil)

    #expect(auto.update(conditionActive: true, isOn: false) == true)
    auto.manualChange()                                                 // the user took over mid-game
    #expect(auto.update(conditionActive: false, isOn: true) == nil)
}

@Test func processNamesComeFromWindowsAndUnixPaths() {
    #expect(processName(argv0: #"C:\Program Files (x86)\Steam\steamapps\common\Deadlock\game\bin\win64\deadlock.exe"#) == ("deadlock.exe", true))
    #expect(processName(argv0: "/Users/me/Library/Application Support/Steam/steamapps/common/dota 2 beta/game/bin/osx64/dota2") == ("dota2", false))
    #expect(processName(argv0: "explorer.exe") == ("explorer.exe", true))
    #expect(ProcessList().snapshot().contains { $0.pid == getpid() })
}

@Test func articleMarkdownBecomesBlocks() {
    let article = Article(markdown: """
    # registry save deferral

    wine freezes the bottle
    twice a minute.

    ## measurement

    a 64 hz echo, received with `recvfrom`.

    | receiver | max |
    |---|---|
    | native | 8 ms |
    | wine | 264 ms |

    ```bars
    longest stall | ms | 264 | 10
    ```

    ## the fix

    ```c wineserver_fix.c
    if (share > busy_cpu)
        return -1;
    ```

    - first
    - second

    ```sh
    tail -f /tmp/regsave_defer.log
    ```

    > [!WARNING]
    > wine games do not always
    > trigger game mode.
    """)
    #expect(article.title == "registry save deferral")
    #expect(article.lead == "wine freezes the bottle twice a minute.")
    #expect(article.sections.map(\.title) == ["measurement", "the fix"])
    #expect(article.sections[0].blocks == [
        .paragraph("a 64 hz echo, received with `recvfrom`."),
        .table(head: ["receiver", "max"], rows: [["native", "8 ms"], ["wine", "264 ms"]]),
        .bars(label: "longest stall", unit: "ms", before: 264, after: 10),
    ])
    #expect(article.sections[1].blocks == [
        .code(title: "wineserver_fix.c", text: "if (share > busy_cpu)\n    return -1;"),
        .list(["first", "second"]),
        .command("tail -f /tmp/regsave_defer.log"),
        .note(warning: true, text: "wine games do not always trigger game mode."),
    ])
}

enum Signature { case none, adHoc, hardened, other }

/// What `codesign -d` says about a binary's signature.
func signature(of url: URL) -> Signature {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-d", "--verbose=2", url.path]
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return .other }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    if text.contains("not signed") { return .none }
    if text.contains("runtime") { return .hardened }
    return text.contains("Signature=adhoc") ? .adHoc : .other
}

@Test func previewLayoutIsRecognised() throws {
    let fake = try FakeCrossOver(preview: true, name: "CrossOver Preview.app")
    defer { fake.cleanUp() }
    #expect(fake.crossover.isValid)
    #expect(fake.crossover.wineservers.map(\.lastPathComponent) == ["wineserver-x86", "wineserver-arm64"])
    #expect(fake.crossover.unixLibDirs.map(\.lastPathComponent) == ["x86_64-unix", "aarch64-unix"])
    #expect(fake.crossover.isWritable == true)
}

@Test func previewWineserversAreAllWrappedAndRestored() throws {
    let fake = try FakeCrossOver(preview: true)
    defer { fake.cleanUp() }
    let bin = fake.crossover.bin
    let config = WineserverConfig(busyCpu: 0.05, udpService: 3, log: nil)
    try fake.fixes.installWineserver(config)
    #expect(fake.fixes.wineserverConfig() == config)
    #expect(fake.names(in: bin) == ["wineserver-arm64", "wineserver-arm64.orig", "wineserver-arm64.real",
                                    "wineserver-x86", "wineserver-x86.orig", "wineserver-x86.real", "wineserver_fix.dylib"])
    // never a plain bin/wineserver: bin/wine would pick it over both real servers
    #expect(!FileManager.default.fileExists(atPath: bin.appendingPathComponent("wineserver").path))
    for name in ["wineserver-x86", "wineserver-arm64"] {
        let wrapper = try String(contentsOf: bin.appendingPathComponent(name), encoding: .utf8)
        #expect(wrapper.contains("exec \"$d/\(name).real\""))
        #expect(signature(of: bin.appendingPathComponent(name + ".real")) == .adHoc)
    }

    // one server patched by hand back to stock: the bundle no longer counts as patched
    try FileManager.default.removeItem(at: bin.appendingPathComponent("wineserver-arm64"))
    try FileManager.default.moveItem(at: bin.appendingPathComponent("wineserver-arm64.orig"), to: bin.appendingPathComponent("wineserver-arm64"))
    #expect(fake.fixes.wineserverConfig() == nil)
    try fake.fixes.installWineserver(config)
    #expect(fake.fixes.wineserverConfig() == config)

    try fake.fixes.uninstallWineserver()
    #expect(fake.names(in: bin) == ["wineserver-arm64", "wineserver-x86"])
    for name in ["wineserver-x86", "wineserver-arm64"] {
        #expect(try Data(contentsOf: bin.appendingPathComponent(name)) == fake.serverBytes)
    }
}

@Test func previewAudioDriversAreAllWrappedAndRestored() throws {
    let fake = try FakeCrossOver(preview: true)
    defer { fake.cleanUp() }
    try fake.fixes.installAudio(ioMs: 5.33)
    #expect(fake.fixes.audioIOms() == 5.33)
    for unix in fake.crossover.unixLibDirs {
        #expect(try Data(contentsOf: unix.appendingPathComponent("winecoreaudio.so")) == Data("audio wrapper".utf8))
        #expect(try Data(contentsOf: unix.appendingPathComponent("winecoreaudio_real.so")) == fake.driverBytes)
    }
    try fake.fixes.uninstallAudio()
    for unix in fake.crossover.unixLibDirs {
        #expect(try Data(contentsOf: unix.appendingPathComponent("winecoreaudio.so")) == fake.driverBytes)
        #expect(fake.names(in: unix) == ["winecoreaudio.so"])
    }
}

@Test func fixSetPatchesEveryBundleAndAgreesOnlyWhenTheyMatch() throws {
    let stable = try FakeCrossOver(), preview = try FakeCrossOver(preview: true)
    defer { stable.cleanUp(); preview.cleanUp() }
    let set = FixSet(crossovers: [stable.crossover, preview.crossover], payload: stable.payload)
    let config = WineserverConfig(busyCpu: 0.05, udpService: 4, log: nil)
    try set.installWineserver(config)
    try set.installAudio(ioMs: 4)
    #expect(set.wineserverConfig() == config)
    #expect(set.audioIOms() == 4)
    #expect(stable.fixes.wineserverConfig() == config && preview.fixes.wineserverConfig() == config)

    try preview.fixes.uninstallAudio()  // e.g. a preview update wiped it
    #expect(set.audioIOms() == nil)
    try set.uninstallWineserver()
    try set.uninstallAudio()
    #expect(stable.fixes.wineserverConfig() == nil && preview.fixes.wineserverConfig() == nil)
    #expect(stable.fixes.audioIOms() == nil)
}
