import Foundation

/// Transport abstraction for multi-iPad tournament sync. The model owns one of
/// these, broadcasts the whole `Tournament` after every change, and merges
/// whatever arrives via `onReceive`. Keeping this a protocol lets the app run the
/// real radio (`MultipeerTransport`, in the app target) while `swift test` — and a
/// single-process two-window dev mode — run the in-memory `LoopbackTransport`.
///
/// Callbacks may fire on any thread; the model hops to the main actor before
/// touching published state.
public protocol SyncTransport: AnyObject {
    /// A peer sent its full tournament state. Merge it.
    var onReceive: ((Tournament) -> Void)? { get set }
    /// The set of connected peer display names changed (for the "Geräte" indicator).
    var onPeersChanged: (([String]) -> Void)? { get set }

    /// Begin advertising + discovering peers.
    func start()
    /// Stop and disconnect.
    func stop()
    /// Send the whole tournament to every connected peer (it's tiny — no diffing).
    func broadcast(_ tournament: Tournament)
}

// ── In-process loopback (tests + single-process dev sync) ───────────────────────

/// A process-global rendezvous that wires `LoopbackTransport` instances together:
/// a broadcast from one is delivered to all the others, and membership changes
/// refresh every member's peer list. Used by the engine's convergence tests, and
/// it can back a two-window dev build on one iPad (both scenes share the process).
public final class LoopbackHub: @unchecked Sendable {
    public static let shared = LoopbackHub()

    private let lock = NSLock()
    private var members: [ObjectIdentifier: LoopbackTransport] = [:]

    public init() {}

    func register(_ t: LoopbackTransport) {
        lock.lock(); members[ObjectIdentifier(t)] = t; let snapshot = Array(members.values); lock.unlock()
        notifyPeers(snapshot)
    }

    func unregister(_ t: LoopbackTransport) {
        lock.lock(); members[ObjectIdentifier(t)] = nil; let snapshot = Array(members.values); lock.unlock()
        notifyPeers(snapshot)
        // The leaver now sees no peers.
        t.deliverPeers([])
    }

    func broadcast(from sender: LoopbackTransport, _ tournament: Tournament) {
        lock.lock(); let others = members.values.filter { $0 !== sender }; lock.unlock()
        for m in others { m.deliver(tournament) }
    }

    /// Give every member the names of the *other* members.
    private func notifyPeers(_ all: [LoopbackTransport]) {
        for m in all {
            m.deliverPeers(all.filter { $0 !== m }.map(\.name))
        }
    }
}

/// In-memory `SyncTransport`. Delivery is synchronous, so in a test a single
/// `broadcast` fully propagates (and settles, since the merge is idempotent)
/// before returning.
public final class LoopbackTransport: SyncTransport {
    public var onReceive: ((Tournament) -> Void)?
    public var onPeersChanged: (([String]) -> Void)?

    public let name: String
    private let hub: LoopbackHub
    private var started = false

    public init(name: String, hub: LoopbackHub = .shared) {
        self.name = name
        self.hub = hub
    }

    public func start() {
        guard !started else { return }
        started = true
        hub.register(self)
    }

    public func stop() {
        guard started else { return }
        started = false
        hub.unregister(self)
    }

    public func broadcast(_ tournament: Tournament) {
        guard started else { return }
        hub.broadcast(from: self, tournament)
    }

    // Hub → this transport.
    func deliver(_ tournament: Tournament) { onReceive?(tournament) }
    func deliverPeers(_ names: [String]) { onPeersChanged?(names) }
}
