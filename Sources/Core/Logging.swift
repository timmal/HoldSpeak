import Foundation

/// Serialises all file writes. pttLog is called from the audio tap thread,
/// the main thread and background tasks, so the handle is only ever touched here.
private let logQueue = DispatchQueue(label: "com.timmal.holdspeak.log", qos: .utility)

/// XCTest is loaded into the test runner, never into the app; checked without importing it.
private let runningUnderXCTest = NSClassFromString("XCTestCase") != nil
    || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

/// ~/Library/Logs/HoldSpeak.log; a file in the temp directory under the unit tests,
/// which would otherwise write their lines into the user's log.
let logPath: String = runningUnderXCTest
    ? (NSTemporaryDirectory() as NSString).appendingPathComponent("HoldSpeak-tests.log")
    : ("~/Library/Logs/HoldSpeak.log" as NSString).expandingTildeInPath
private let logMaxBytes: UInt64 = 2 * 1024 * 1024
/// Opened lazily on logQueue; nil until the first write (or after a failed open).
private var logHandle: FileHandle?

public func pttLog(_ msg: String) {
    NSLog("%@", "[PTT] \(msg)")
    let line = "\(Date()) \(msg)\n"
    logQueue.async {
        guard let data = line.data(using: .utf8), let fh = openLogHandle() else { return }
        try? fh.write(contentsOf: data)
        if let size = try? fh.offset(), size > logMaxBytes {
            rotateLog()
        }
    }
}

/// Must be called on logQueue.
private func openLogHandle() -> FileHandle? {
    if let fh = logHandle { return fh }
    let fm = FileManager.default
    if !fm.fileExists(atPath: logPath) {
        fm.createFile(atPath: logPath, contents: nil)
    }
    guard let fh = FileHandle(forWritingAtPath: logPath) else { return nil }
    _ = try? fh.seekToEnd()
    logHandle = fh
    return fh
}

/// Moves the current log to HoldSpeak.log.1 (replacing any previous one);
/// the next write starts a fresh file. Must be called on logQueue.
private func rotateLog() {
    try? logHandle?.close()
    logHandle = nil
    let fm = FileManager.default
    let rotated = logPath + ".1"
    try? fm.removeItem(atPath: rotated)
    try? fm.moveItem(atPath: logPath, toPath: rotated)
}

/// Deletes the log from before the rename, `PushToTalk.log` and its rotated `.1`, in
/// `directory` (~/Library/Logs). Old builds wrote transcripts into it in clear text,
/// and nothing else ever removes it. Returns the names removed.
@discardableResult
public func removeLegacyLogs(in directory: URL) -> [String] {
    let fm = FileManager.default
    return ["PushToTalk.log", "PushToTalk.log.1"].filter { name in
        let url = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return false }
        do {
            try fm.removeItem(at: url)
            return true
        } catch {
            pttLog("Couldn't remove the old log \(name): \(error)")
            return false
        }
    }
}

/// Whether log lines may quote dictated text. Off in every build, Debug included
/// (scripts/rebuild.sh installs a Debug build as the everyday app). To debug text
/// handling, turn it on and relaunch:
///     defaults write com.timmal.push-to-talk debugLogTranscripts -bool YES
/// and off again with `defaults delete com.timmal.push-to-talk debugLogTranscripts`.
/// Read once per run, on the first line that logs text.
private let logTranscripts = UserDefaults.standard.bool(forKey: "debugLogTranscripts")

/// Dictated text for log lines: only its length, so the log file never holds what
/// the user said, unless `debugLogTranscripts` is set.
public func logText(_ text: String) -> String {
    logText(text, verbatim: logTranscripts)
}

func logText(_ text: String, verbatim: Bool) -> String {
    verbatim ? "\"\(text)\"" : "<\(text.count) chars>"
}
