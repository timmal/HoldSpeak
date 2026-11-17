import Foundation

/// Serialises all file writes. pttLog is called from the audio tap thread,
/// the main thread and background tasks, so the handle is only ever touched here.
private let logQueue = DispatchQueue(label: "com.timmal.holdspeak.log", qos: .utility)
private let logPath = ("~/Library/Logs/HoldSpeak.log" as NSString).expandingTildeInPath
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

/// Dictated text for log lines: quoted in Debug builds, only its length in Release
/// so the log file never holds what the user said.
public func logText(_ text: String) -> String {
    #if DEBUG
    return "\"\(text)\""
    #else
    return "<\(text.count) chars>"
    #endif
}
