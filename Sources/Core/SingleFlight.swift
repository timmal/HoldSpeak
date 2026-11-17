import Foundation

/// Runs at most one operation per key at a time. A request for a key that is already
/// running joins it: same result or error, and its progress callback gets the running
/// operation's progress. Once an operation ends, successfully or not, the key is free
/// and the next request starts a fresh one.
///
/// Model downloads go through this, so two downloads of one model never write the same
/// files at once.
@MainActor
public final class SingleFlight<Key: Hashable, Value> {
    public typealias Progress = (Double) -> Void

    private final class Flight {
        let id: Int
        var task: Task<Value, Error>?
        var listeners: [Progress] = []
        var fraction: Double = 0
        init(id: Int) { self.id = id }
    }

    private var flights: [Key: Flight] = [:]
    private var nextID = 0
    /// Keys in flight, oldest first.
    public private(set) var running: [Key] = []
    /// Called on main when a key starts, reports progress, or ends.
    public var onChange: (() -> Void)?

    public nonisolated init() {}

    public func isRunning(_ key: Key) -> Bool { flights[key] != nil }

    /// Latest progress (0…1) of `key`'s running operation; nil when it isn't running.
    public func progress(of key: Key) -> Double? { flights[key]?.fraction }

    /// Runs `operation` for `key`, or joins the one already running. `operation` gets a
    /// progress reporter that may be called from any thread.
    public func run(_ key: Key,
                    progress: Progress? = nil,
                    operation: @escaping (_ report: @escaping @Sendable (Double) -> Void) async throws -> Value)
        async throws -> Value
    {
        if let flight = flights[key], let task = flight.task {
            if let progress {
                flight.listeners.append(progress)
                progress(flight.fraction)
            }
            return try await task.value
        }

        nextID += 1
        let flight = Flight(id: nextID)
        if let progress { flight.listeners.append(progress) }
        flights[key] = flight
        running.append(key)

        let id = flight.id
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progressed(key, id: id, fraction: fraction) }
        }
        let task = Task { @MainActor [weak self] () throws -> Value in
            // Freed before any caller resumes, so a retry after a failure starts afresh.
            defer { self?.finished(key, id: id) }
            return try await operation(report)
        }
        flight.task = task
        onChange?()
        return try await task.value
    }

    private func progressed(_ key: Key, id: Int, fraction: Double) {
        guard let flight = flights[key], flight.id == id else { return }
        flight.fraction = fraction
        for listener in flight.listeners { listener(fraction) }
        onChange?()
    }

    private func finished(_ key: Key, id: Int) {
        guard flights[key]?.id == id else { return }
        flights[key] = nil
        running.removeAll { $0 == key }
        onChange?()
    }
}
