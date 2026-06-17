import Foundation
import MultipeerConnectivity
import TavliEngine

/// The real-radio `SyncTransport`: a serverless MultipeerConnectivity mesh for
/// ≤3 iPads on the same WiFi. Every device both **advertises** the
/// `tavli-turnier` service and **browses** for it, so the mesh forms with no host
/// and no codes — open the app on each iPad and they find each other.
///
/// - **Handshake.** Browser finds a peer → (lower device id invites, to avoid a
///   double-invite) → the advertiser auto-accepts (trusted family event) → the
///   `MCSession` connects. The model then broadcasts current state on the
///   resulting peer-change, so a joiner is brought up to date.
/// - **Payload.** The whole `Tournament` is sent on every change (it's tiny — no
///   diffing) and merged on the far side via `Tournament.merged(with:)`.
/// - **Threading.** Delegate callbacks arrive on MultipeerConnectivity's queue;
///   this type just forwards them through `onReceive` / `onPeersChanged`. The
///   `TournamentModel` hops to the main actor before touching published state.
final class MultipeerTransport: NSObject, SyncTransport {
    var onReceive: ((Tournament) -> Void)?
    var onPeersChanged: (([String]) -> Void)?

    /// 1–15 chars, lowercase letters / numbers / hyphens — must match the
    /// `NSBonjourServices` entries in Info.plist (`_tavli-turnier._tcp`/`._udp`).
    static let serviceType = "tavli-turnier"

    /// Stable per-device id, advertised so peers can break the invite tie
    /// deterministically (the per-launch `MCPeerID.hash` can't).
    private let deviceID: UUID
    private let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(deviceName: String, deviceID: UUID) {
        self.deviceID = deviceID
        self.myPeerID = MCPeerID(displayName: deviceName)
        self.session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        self.advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                                    discoveryInfo: ["id": deviceID.uuidString],
                                                    serviceType: MultipeerTransport.serviceType)
        self.browser = MCNearbyServiceBrowser(peer: myPeerID,
                                              serviceType: MultipeerTransport.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    func broadcast(_ tournament: Tournament) {
        let peers = session.connectedPeers
        guard !peers.isEmpty, let data = try? encoder.encode(tournament) else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    private func publishPeers() {
        onPeersChanged?(session.connectedPeers.map(\.displayName))
    }
}

// ── Discovery ───────────────────────────────────────────────────────────────────

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser,
                 foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        // Both sides advertise *and* browse, so each would invite the other. Break
        // the tie on the stable device id: only the lower id sends the invitation.
        let theirID = info?["id"] ?? peerID.displayName
        guard deviceID.uuidString < theirID else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // Session state changes drive the peer list; nothing to do here.
    }
}

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Trusted local event → auto-accept.
        invitationHandler(true, session)
    }
}

// ── Session ─────────────────────────────────────────────────────────────────────

extension MultipeerTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        publishPeers()
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let tournament = try? decoder.decode(Tournament.self, from: data) else { return }
        onReceive?(tournament)
    }

    // Unused MultipeerConnectivity channels (required by the protocol).
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
