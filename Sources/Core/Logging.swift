import Foundation

public func pttLog(_ msg: String) {
    NSLog("[PTT] \(msg)")
    let path = ("~/Library/Logs/PushToTalk.log" as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: path)
    let line = "\(Date()) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: path) {
        try? data.write(to: url)
        return
    }
    if let fh = try? FileHandle(forWritingTo: url) {
        try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
        try? fh.close()
    }
}
