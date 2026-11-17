import Foundation

/// Two running copies of HoldSpeak (say one from /Applications and one from the DMG)
/// would each install an event tap, and every dictation would be typed twice.
public enum SingleInstance {
    public struct Instance: Equatable {
        public let pid: Int32
        /// Nil for a process LaunchServices didn't start (Terminal, a debugger).
        public let launchDate: Date?
        public init(pid: Int32, launchDate: Date?) {
            self.pid = pid
            self.launchDate = launchDate
        }
    }

    /// The running copy this launch should give way to, or nil to keep running: the
    /// copy that started first wins. A copy with no launch date counts as started
    /// earliest (it was there already); a tie goes to the lower pid, so two copies
    /// started together never both quit.
    public static func instanceToYieldTo(me: Instance, others: [Instance]) -> Instance? {
        func key(_ i: Instance) -> (Date, Int32) { (i.launchDate ?? .distantPast, i.pid) }
        return others
            .filter { $0.pid != me.pid && key($0) < key(me) }
            .min { key($0) < key($1) }
    }
}
