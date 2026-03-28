//
//  PatchbayManager.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  v4 — Pure event-driven architecture:
//  - Listens to Jack callbacks (port registration, connect/disconnect)
//  - Debounces callback bursts
//  - No polling, no timers
//  - Bridge connected only when the Patchbay view is active
//

import SwiftUI
import Combine

// MARK: - Connect All — types

enum ConnectAllMode: String, Identifiable, CaseIterable {
    case minAbandon = "minAbandon"
    case wrap       = "wrap"
    case fanOut     = "fanOut"
    var id: String { rawValue }
    /// SF Symbol name for this mode. `fanOut` uses a custom Canvas instead.
    var systemImage: String {
        switch self {
        case .minAbandon: return "line.3.horizontal"
        case .wrap:       return "repeat"
        case .fanOut:     return "repeat"   // fallback; fanOut icon is drawn with Canvas
        }
    }
}

struct ConnectAllTypePlan: Identifiable {
    let id               = UUID()
    let portType:         JackPortType
    let outPorts:        [JackPort]
    let inPorts:         [JackPort]
    var mode:             ConnectAllMode
    let alreadyMinConnected: Bool

    var n: Int { outPorts.count }
    var m: Int { inPorts.count }
    var isSymmetric: Bool { n == m }
    var altMode: ConnectAllMode { n >= m ? .wrap : .fanOut }
    var altModeLabel: String {
        n > m ? "Wrap — cycler \(n) sorties sur \(m) entrées"
              : "Fan-out — \(n) sortie\(n > 1 ? "s" : "") vers \(m) entrées"
    }
}

struct ConnectAllRequest: Identifiable {
    let id       = UUID()
    let outNode: PatchbayNode
    let inNode:  PatchbayNode
    var typePlans: [ConnectAllTypePlan]

    /// `true` if the confirmation modal must be shown (at least one asymmetric type plan).
    var needsModal: Bool { typePlans.contains { !$0.isSymmetric } }
    /// `true` if all minimum pairs are already connected (min-abandon mode, all pairs exist).
    var isFullyAlreadyConnected: Bool { typePlans.allSatisfy { $0.alreadyMinConnected } }
}

// MARK: - Tidy — viewport result

struct TidyViewport {
    let scale:  CGFloat
    let offset: CGSize
}

// MARK: - PatchbayNode

/// A node in the patchbay canvas, representing a single Jack client with its ports.
struct PatchbayNode: Identifiable {

    /// Jack client name — used as the stable identifier.
    let id: String
    var position: CGPoint
    var isCollapsed: Bool = false
    var inputs:  [JackPort] = []
    var outputs: [JackPort] = []

    var inputCount:  Int { inputs.count }
    var outputCount: Int { outputs.count }
}

// MARK: - PatchbayManager

@MainActor
final class PatchbayManager: ObservableObject {

    // ── State ────────────────────────────────────────────────────────────────
    @Published var nodes:                [PatchbayNode]   = []
    @Published var connections:          [JackConnection] = []
    @Published var isConnected:          Bool             = false
    @Published var errorMessage:         String?          = nil
    @Published var showSaveStudioDialog: Bool             = false
    @Published var showRepositionToast:  Bool             = false
    @Published var selectedNodeIds:      Set<String>      = []

    // ── Transport ─────────────────────────────────────────────────────────────
    /// Isolated transport observer — only `TransportBarView` subscribes to avoid canvas re-renders.
    let transportObserver = TransportObserver()

    /// `true` when the user wants the transport bar visible (persisted to UserDefaults).
    @Published var showTransportBar: Bool = UserDefaults.standard.bool(forKey: "showTransportBar") {
        didSet { UserDefaults.standard.set(showTransportBar, forKey: "showTransportBar") }
    }
    /// `true` while transport is rolling (updated by `TransportObserver`, infrequent change).
    @Published var isTransportRolling: Bool = false

    /// The transport bar is effectively visible when connected AND (user requested it OR transport is rolling).
    var transportBarVisible: Bool { isConnected && (showTransportBar || isTransportRolling) }

    /// Toggles the selection state of the node with the given ID.
    func toggleSelection(_ id: String) {
        if selectedNodeIds.contains(id) { selectedNodeIds.remove(id) }
        else                            { selectedNodeIds.insert(id) }
    }
    /// Deselects all nodes.
    func clearSelection() { selectedNodeIds.removeAll() }
    /// Selects all nodes.
    func selectAll()      { selectedNodeIds = Set(nodes.map { $0.id }) }

    // Reference to JackManager for logging
    private(set) weak var jackManager: JackManager?

    // Reference to StudioManager for auto-restoring connections when a known client (re)appears
    private weak var studioManager: StudioManager?

    // Expose the bridge so callers can access the xrun counter and other bridge state
    var jackBridge: JackBridgeWrapper { bridge }

    // ── Private ──────────────────────────────────────────────────────────────
    private let bridge = JackBridgeWrapper()
    private var runningObserver: AnyCancellable?

    // Guard against concurrent connect/disconnect races
    private var isConnecting: Bool = false

    // Jack clients present at the last applyPorts call — used to detect new arrivals
    private var previousNodeClientNames: Set<String> = []

    // Debounce for port-registration bursts (e.g. an app registering many ports at once)
    private var refreshDebounceTask: DispatchWorkItem?
    private let refreshDebounceDelay: TimeInterval = 0.25  // 250 ms

    // Retry task when bridge.open() fails (e.g. is_closing still true from previous teardown)
    private var retryConnectTask: DispatchWorkItem?

    // ── Init ─────────────────────────────────────────────────────────────────
    init() {
        setupBridgeCallbacks()
    }
    
    deinit {
        runningObserver?.cancel()
        // bridge.close() is called from JackBridgeWrapper's own deinit
    }

    // MARK: - Configuration (called ONCE from ContentView)

    /// Injects the `StudioManager` used for automatic connection restoration.
    /// Call once from `ContentView` after both `configure` calls.
    func configureStudio(_ studioManager: StudioManager) {
        guard self.studioManager == nil else { return }
        self.studioManager = studioManager
    }

    /// Configures the `PatchbayManager` with the `JackManager`.
    /// Call once at app startup. The bridge opens/closes automatically as Jack starts/stops.
    func configure(with jackManager: JackManager) {
        // Idempotent — only configure once
        guard self.jackManager == nil else { return }

        self.jackManager = jackManager

        // Observe isRunning — open/close the bridge automatically.
        // .removeDuplicates() ensures the sink fires only on a genuine state change,
        // even when @Published publishes on every assignment.
        runningObserver = jackManager.$isRunning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                guard let self else { return }
                
                if running && !self.isConnected && !self.isConnecting {
                    // Jack just started — deferred connection to let it settle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self,
                              !self.isConnected,
                              !self.isConnecting,
                              let jm = self.jackManager,
                              jm.isRunning else { return }
                        self.tryConnect()
                    }
                } else if !running && self.isConnected {
                    // Jack stopped — close the bridge
                    self.handleJackStopped()
                }
            }

        // If Jack is already running, connect now
        if jackManager.isRunning && !isConnected && !isConnecting {
            // Short delay to let the UI settle before connecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.tryConnect()
            }
        }
    }
    
    /// Handles a Jack server stop event: cancels pending tasks, closes the bridge, clears state.
    private func handleJackStopped() {
        // Cancel any pending work items
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        retryConnectTask?.cancel()
        retryConnectTask = nil
        pendingPositions = []
        previousNodeClientNames = []

        // Mark as disconnected BEFORE closing the bridge
        isConnecting = false
        isConnected = false
        isTransportRolling = false
        transportObserver.stop()
        connections = []

        // Close the bridge (synchronous on the Swift side — C teardown runs in background)
        bridge.close()

        // Clear nodes after a brief delay so the canvas doesn't flash
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.nodes = []
        }

        // Edge case: Jack crash + immediate restart (isRunning doesn't change → the Combine
        // sink doesn't fire). Schedule a retry to cover this scenario.
        if let jm = jackManager, jm.isRunning {
            scheduleRetryConnect()
        }
    }

    private func tryConnect() {
        // CRITICAL: NEVER call jack_client_open when Jack is not running —
        // libjack would spawn threads that crash on an invalid socket
        guard !isConnected, !isConnecting else { return }
        guard let jm = jackManager, jm.isRunning else {
            logToJack("⚠️ Patchbay: Jack n'est pas actif, connexion annulée")
            return
        }
        
        // Mark as connecting to prevent concurrent races
        isConnecting = true

        do {
            try bridge.open(clientName: "JackMate-Patchbay")

            // Verify that open() actually succeeded.
            // Typical silent-failure cause: bridge.isClosing is still true
            // (jm_client_close is running in the background from the previous teardown).
            guard bridge.isConnected else {
                logToJack("⚠️ Patchbay: bridge non connecté après open(), nouvel essai dans 2s")
                isConnecting = false
                scheduleRetryConnect()
                return
            }
            
            isConnected = true
            isConnecting = false
            // Start the transport observer (isolated — only TransportBarView subscribes)
            self.transportObserver.onRollingChanged = { [weak self] rolling in
                self?.isTransportRolling = rolling
            }
            self.transportObserver.start(bridge: self.bridge)
            // Re-register callbacks after each open() — bridge.close() destroys the
            // C-level registrations of the previous jack_client_t.
            setupBridgeCallbacks()
            logToJack("→ Patchbay connecté à Jack")

            // Initial load with a short delay to let the client activate
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                // Verify bridge is still connected before loading
                guard self.bridge.isConnected else { return }
                self.initialLoadBackground()
            }
        } catch {
            isConnecting = false
            logToJack("⚠️ Patchbay bridge: \(error.localizedDescription)")
            scheduleRetryConnect()
        }
    }

    /// Planifie une nouvelle tentative de connexion dans 2s si Jack est toujours actif.
    /// Annule toute tentative précédente pour éviter les doublons.
    private func scheduleRetryConnect() {
        retryConnectTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isConnected,
                  !self.isConnecting,
                  let jm = self.jackManager,
                  jm.isRunning else { return }
            self.tryConnect()
        }
        retryConnectTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Chargement initial : ports + connexions en une seule passe
    nonisolated private func initialLoadBackground() {
        let ports = bridge.getPorts()
        let conns = bridge.getConnections()
        
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isConnected else { return }
            self.applyPorts(ports)
            self.connections = conns
            self.logToJack("→ Chargé \(ports.count) ports, \(conns.count) connexions")
        }
    }

    private func setupBridgeCallbacks() {
        // Port-registration callback — just debounce, no immediate update.
        // NOTE: This closure is called from a Jack thread (non-main).
        // Do NOT read self.isConnected here (data race on @MainActor) —
        // the guard runs on the main thread inside the async dispatch.
        bridge.onPortRegistration = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isConnected else { return }
                self.debouncedRefresh()
            }
        }

        // Connection callback — updates only the connections array
        bridge.onPortConnect = { [weak self] connection, connected in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isConnected else { return }
                if connected {
                    if !self.connections.contains(where: {
                        $0.from == connection.from && $0.to == connection.to
                    }) {
                        self.connections.append(connection)
                    }
                } else {
                    self.connections.removeAll {
                        $0.from == connection.from && $0.to == connection.to
                    }
                }
            }
        }

        // Shutdown callback — delegates to handleJackStopped() for a full cleanup
        // (previousNodeClientNames, retryConnectTask, etc.) unified with the Combine path.
        bridge.onShutdown = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isConnected else { return }
                self.logToJack("⚠️ Jack shutdown détecté")
                self.handleJackStopped()
            }
        }
    }

    // MARK: - Debounced Refresh
    
    /// Triggers a debounced refresh — waits for 250 ms of silence before executing
    private func debouncedRefresh() {
        refreshDebounceTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isConnected else { return }
            self.refreshBackground()
        }
        refreshDebounceTask = work
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + refreshDebounceDelay,
            execute: work
        )
    }

    /// Requests a debounced port refresh (no-op if not connected).
    func refresh() {
        debouncedRefresh()
    }

    /// Re-reads ports from Jack and updates the patchbay nodes.
    /// Does NOT overwrite `connections` — those are managed by `onPortConnect` callbacks
    /// or by an explicit `syncConnections()` call.
    func forceRefresh() {
        guard isConnected else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let ports = self.bridge.getPorts()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isConnected else { return }
                self.applyPorts(ports)
            }
        }
    }

    /// Relit les connexions actives depuis Jack et écrase connections[].
    /// À appeler après un load studio (Jack ne fire pas onPortConnect vers le client
    /// initiateur des connexions — lecture directe nécessaire pour la cohérence visuelle).
    func syncConnections() {
        guard isConnected else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let conns = self.bridge.getConnections()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isConnected else { return }
                self.connections = conns
            }
        }
    }

    nonisolated private func refreshBackground() {
        let ports = bridge.getPorts()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isConnected else { return }
            self.applyPorts(ports)
        }
    }

    private func applyPorts(_ ports: [JackPort]) {
        // Group ports by client name
        var byClient: [String: (inputs: [JackPort], outputs: [JackPort])] = [:]

        for port in ports {
            let key = port.clientName
            if byClient[key] == nil { byClient[key] = ([], []) }
            if port.direction == .input {
                byClient[key]!.inputs.append(port)
            } else {
                byClient[key]!.outputs.append(port)
            }
        }

        var updatedNodes: [PatchbayNode] = []
        
        // Use ALL nodes (existing + new) for collision resolution so new nodes
        // don't overlap nodes already placed in this pass
        func allNodesForCollision() -> [PatchbayNode] {
            // Nodes already updated + existing nodes not yet processed in this pass
            var all = updatedNodes
            for existingNode in nodes {
                if !updatedNodes.contains(where: { $0.id == existingNode.id }) {
                    all.append(existingNode)
                }
            }
            return all
        }

        for (clientName, portPair) in byClient {
            let hasInputs  = !portPair.inputs.isEmpty
            let hasOutputs = !portPair.outputs.isEmpty
            let shouldSplit = (clientName == "system") && hasInputs && hasOutputs

            if shouldSplit {
                let captureId  = "\(clientName) (capture)"
                let playbackId = "\(clientName) (playback)"

                if let existing = nodes.first(where: { $0.id == captureId }) {
                    var n = existing; n.inputs = []; n.outputs = portPair.outputs
                    updatedNodes.append(n)
                } else {
                    let pos = autoPosition(for: captureId, inputs: [], outputs: portPair.outputs, existing: allNodesForCollision())
                    updatedNodes.append(PatchbayNode(id: captureId, position: pos,
                                                     inputs: [], outputs: portPair.outputs))
                }

                if let existing = nodes.first(where: { $0.id == playbackId }) {
                    var n = existing; n.inputs = portPair.inputs; n.outputs = []
                    updatedNodes.append(n)
                } else {
                    let pos = autoPosition(for: playbackId, inputs: portPair.inputs, outputs: [], existing: allNodesForCollision())
                    updatedNodes.append(PatchbayNode(id: playbackId, position: pos,
                                                     inputs: portPair.inputs, outputs: []))
                }
            } else {
                let nodeId = clientName
                if let existing = nodes.first(where: { $0.id == nodeId }) {
                    var n = existing
                    n.inputs  = portPair.inputs
                    n.outputs = portPair.outputs
                    updatedNodes.append(n)
                } else {
                    let pos = autoPosition(for: nodeId, inputs: portPair.inputs, outputs: portPair.outputs, existing: allNodesForCollision())
                    updatedNodes.append(PatchbayNode(id: nodeId, position: pos,
                                                     inputs:  portPair.inputs,
                                                     outputs: portPair.outputs))
                }
            }
        }
        nodes = updatedNodes
        flushPendingPositions()

        // Detect newly appeared clients for automatic studio connection restoration
        let currentClientNames = Set(updatedNodes.map {
            $0.id.replacingOccurrences(of: " (capture)", with: "")
               .replacingOccurrences(of: " (playback)", with: "")
        })
        let newClientNames = currentClientNames.subtracting(previousNodeClientNames)
        previousNodeClientNames = currentClientNames
        if !newClientNames.isEmpty {
            handleNewClients(newClientNames)
        }
    }

    /// Called after each `applyPorts` with the Jack client names that just appeared.
    /// If a client is known to the loaded studio, its auto-connections are cancelled
    /// and the saved connections are restored.
    private func handleNewClients(_ names: Set<String>) {
        guard let studio = studioManager?.loadedStudio else { return }
        guard studioManager?.activeStudio == nil else { return }

        let studioClientNames = Set(studio.clients.map { $0.jackName })
        let toRestore = names.intersection(studioClientNames)
        guard !toRestore.isEmpty else { return }

        // Short delay to let the app finish its auto-connect (Jack sends
        // onPortRegistration first; the auto-connections arrive just after)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isConnected else { return }
            for clientName in toRestore {
                self.restoreStudioConnections(for: clientName, studio: studio)
            }
        }
    }

    /// Disconnects all auto-connections for a Jack client, then restores
    /// the connections that were saved in the studio.
    private func restoreStudioConnections(for clientName: String, studio: Studio) {
        let prefix = clientName + ":"

        // 1. Remove existing auto-connections for this client
        let autoConns = connections.filter { $0.from.hasPrefix(prefix) || $0.to.hasPrefix(prefix) }
        for conn in autoConns {
            try? bridge.disconnect(from: conn.from, to: conn.to)
        }
        connections.removeAll { $0.from.hasPrefix(prefix) || $0.to.hasPrefix(prefix) }

        // 2. Restore studio connections for this client
        let allPorts = nodes.flatMap { $0.inputs + $0.outputs }
        let studioConns = studio.connections.filter {
            $0.from.hasPrefix(prefix) || $0.to.hasPrefix(prefix)
        }
        for conn in studioConns {
            if let fromPort = allPorts.first(where: { $0.id == conn.from }),
               let toPort   = allPorts.first(where: { $0.id == conn.to }) {
                connectPorts(from: fromPort, to: toPort)
            }
        }
        logToJack("↺ Auto-connect annulé, \(studioConns.count) connexion(s) restaurée(s) pour « \(clientName) »")
    }

    // Node dimensions — must match exactly those used in PatchbayCanvasNSView
    private let nodeW:   CGFloat = 200
    private let headerH: CGFloat = 46   // was 38 — corrected to match NSView measurement (46)
    private let rowH:    CGFloat = 21

    private func autoPosition(for clientName: String,
                               inputs: [JackPort], outputs: [JackPort],
                               existing: [PatchbayNode]) -> CGPoint {
        let col = existing.count % 4
        let row = existing.count / 4
        let candidate = CGPoint(
            x: CGFloat(60 + col * (Int(nodeW) + 20)),
            y: CGFloat(60 + row * 220))
        var tempNode = PatchbayNode(id: clientName, position: candidate)
        tempNode.inputs  = inputs
        tempNode.outputs = outputs
        return resolveCollisionAmong(existing, for: tempNode, at: candidate)
    }

    private func resolveCollisionAmong(_ nodeList: [PatchbayNode],
                                        for candidate: PatchbayNode,
                                        at pos: CGPoint) -> CGPoint {
        let padding: CGFloat = 10

        func nodeHeight(_ node: PatchbayNode) -> CGFloat {
            let rows = CGFloat(max(node.inputCount, node.outputCount))
            return node.isCollapsed ? headerH : headerH + rows * rowH + 6
        }

        let candH = nodeHeight(candidate)

        func candRect(_ p: CGPoint) -> CGRect {
            CGRect(x: p.x, y: p.y, width: nodeW, height: candH)
                .insetBy(dx: -padding/2, dy: -padding/2)
        }

        func collides(_ p: CGPoint) -> Bool {
            let r = candRect(p)
            return nodeList.contains { n in
                let nh = nodeHeight(n)
                let nr = CGRect(x: n.position.x, y: n.position.y,
                                width: nodeW, height: nh)
                    .insetBy(dx: -padding/2, dy: -padding/2)
                return nr.intersects(r)
            }
        }

        if !collides(pos) { return pos }

        let stepX = nodeW + padding
        let stepY = candH + padding

        for dist in 1...20 {
            let d = CGFloat(dist)
            let candidates: [CGPoint] = [
                CGPoint(x: pos.x + stepX * d,  y: pos.y),
                CGPoint(x: pos.x,               y: pos.y + stepY * d),
                CGPoint(x: pos.x + stepX * d,  y: pos.y + stepY * d),
                CGPoint(x: pos.x - stepX * d,  y: pos.y),
                CGPoint(x: pos.x,               y: pos.y - stepY * d),
            ]
            if let free = candidates.first(where: {
                $0.x >= 0 && $0.y >= 0 && !collides($0)
            }) {
                return free
            }
        }
        return pos
    }

    // MARK: - Connections

    /// Connects two ports. Validates direction and type compatibility before calling the bridge.
    func connectPorts(from: JackPort, to: JackPort) {
        guard from.direction == .output, to.direction == .input else {
            logToJack("⚠️ Connexion refusée : direction invalide")
            return
        }
        guard from.type == to.type else {
            logToJack("⚠️ Connexion refusée : types incompatibles (\(from.type.displayName) → \(to.type.displayName))")
            return
        }
        if connections.contains(where: { $0.from == from.id && $0.to == to.id }) {
            return
        }
        do {
            try bridge.connect(from: from.id, to: to.id,
                               fromType: from.type, toType: to.type)
            connections.append(JackConnection(from: from.id, to: to.id))
            logToJack("→ \(from.id) → \(to.id)")
        } catch {
            logToJack("⚠️ \(error.localizedDescription)")
        }
    }

    /// Disconnects all connections involving the specified port ID.
    func disconnectPort(_ portId: String) {
        let toDisconnect = connections.filter { $0.from == portId || $0.to == portId }
        for conn in toDisconnect {
            try? bridge.disconnect(from: conn.from, to: conn.to)
            logToJack("↛ \(conn.from) ↛ \(conn.to)")
        }
        // Direct update — symmetric with connectPorts (do not rely on the callback)
        connections.removeAll { $0.from == portId || $0.to == portId }
    }

    /// Disconnects all input connections of the given node.
    func disconnectAllInputs(of nodeId: String) {
        guard !nodeId.hasSuffix(" (capture)") else { return }
        let jackPrefix = jackClientPrefix(from: nodeId)
        let toDisconnect = connections.filter { $0.to.hasPrefix(jackPrefix + ":") }
        for conn in toDisconnect {
            try? bridge.disconnect(from: conn.from, to: conn.to)
        }
        connections.removeAll { $0.to.hasPrefix(jackPrefix + ":") }
        logToJack("↛ Toutes les entrées de \(nodeId) déconnectées")
    }

    /// Disconnects all output connections of the given node.
    func disconnectAllOutputs(of nodeId: String) {
        guard !nodeId.hasSuffix(" (playback)") else { return }
        let jackPrefix = jackClientPrefix(from: nodeId)
        let toDisconnect = connections.filter { $0.from.hasPrefix(jackPrefix + ":") }
        for conn in toDisconnect {
            try? bridge.disconnect(from: conn.from, to: conn.to)
        }
        connections.removeAll { $0.from.hasPrefix(jackPrefix + ":") }
        logToJack("↛ Toutes les sorties de \(nodeId) déconnectées")
    }

    /// Disconnects all connections (inputs and outputs) of the given node.
    func disconnectAll(of nodeId: String) {
        let jackPrefix = jackClientPrefix(from: nodeId)
        let toDisconnect: [JackConnection]
        let predicate: (JackConnection) -> Bool
        if nodeId.hasSuffix(" (capture)") {
            predicate = { $0.from.hasPrefix(jackPrefix + ":") }
        } else if nodeId.hasSuffix(" (playback)") {
            predicate = { $0.to.hasPrefix(jackPrefix + ":") }
        } else {
            predicate = { $0.from.hasPrefix(jackPrefix + ":") || $0.to.hasPrefix(jackPrefix + ":") }
        }
        toDisconnect = connections.filter(predicate)
        for conn in toDisconnect {
            try? bridge.disconnect(from: conn.from, to: conn.to)
        }
        connections.removeAll(where: predicate)
        logToJack("↛ Tout déconnecté pour \(nodeId)")
    }

    // MARK: - Connect All API

    private let caTypeOrder: [JackPortType] = [.audio, .midi, .cv, .other]

    /// Builds a bulk connect request from `outNode` to `inNode`. Returns `nil` if there are no shared port types.
    func buildConnectAllRequest(outNode: PatchbayNode, inNode: PatchbayNode) -> ConnectAllRequest? {
        let sharedTypes = Set(outNode.outputs.map { $0.type })
            .intersection(Set(inNode.inputs.map { $0.type }))
        guard !sharedTypes.isEmpty else { return nil }

        let plans: [ConnectAllTypePlan] = caTypeOrder.compactMap { t in
            guard sharedTypes.contains(t) else { return nil }
            let outPorts = outNode.outputs.filter { $0.type == t }
            let inPorts  = inNode.inputs.filter  { $0.type == t }
            guard !outPorts.isEmpty && !inPorts.isEmpty else { return nil }
            let minCount   = min(outPorts.count, inPorts.count)
            let alreadyMin = (0..<minCount).allSatisfy { i in
                connections.contains { $0.from == outPorts[i].id && $0.to == inPorts[i].id }
            }
            return ConnectAllTypePlan(portType: t, outPorts: outPorts, inPorts: inPorts,
                                     mode: .minAbandon, alreadyMinConnected: alreadyMin)
        }
        guard !plans.isEmpty else { return nil }
        return ConnectAllRequest(outNode: outNode, inNode: inNode, typePlans: plans)
    }

    /// Executes a `ConnectAllRequest` using the modes chosen by the user.
    func executeConnectAll(_ request: ConnectAllRequest) {
        for plan in request.typePlans {
            let n = plan.n, m = plan.m
            switch plan.mode {
            case .minAbandon:
                for i in 0..<min(n, m) {
                    connectPorts(from: plan.outPorts[i], to: plan.inPorts[i])
                }
            case .wrap, .fanOut:
                for i in 0..<n {
                    for j in 0..<m where i % m == j || j % n == i {
                        connectPorts(from: plan.outPorts[i], to: plan.inPorts[j])
                    }
                }
            }
        }
    }

    /// Disconnects all connections between `outNode` and `inNode` only.
    func disconnectAllBetween(outNode: PatchbayNode, inNode: PatchbayNode) {
        let outIds = Set(outNode.outputs.map { $0.id })
        let inIds  = Set(inNode.inputs.map  { $0.id })
        let toDisc = connections.filter { outIds.contains($0.from) && inIds.contains($0.to) }
        for conn in toDisc {
            try? bridge.disconnect(from: conn.from, to: conn.to)
            logToJack("↛ \(conn.from) ↛ \(conn.to)")
        }
        connections.removeAll { outIds.contains($0.from) && inIds.contains($0.to) }
    }

    private func jackClientPrefix(from nodeId: String) -> String {
        if nodeId.hasSuffix(" (capture)") {
            return String(nodeId.dropLast(" (capture)".count))
        }
        if nodeId.hasSuffix(" (playback)") {
            return String(nodeId.dropLast(" (playback)".count))
        }
        return nodeId
    }

    // MARK: - Tidy layout

    /// Runs an automatic Sugiyama-style layout on the patchbay nodes.
    /// - Parameters:
    ///   - nodeIds:      Optional subset of node IDs to lay out (`nil` = all nodes).
    ///   - canvasSize:   Visible canvas size, used to compute gap and fit.
    ///   - currentScale: Current zoom level; only de-zooms if content doesn't fit.
    /// - Returns: New `vpScale` and `vpOffset` to apply with animation.
    @discardableResult
    func tidy(nodeIds: [String]? = nil,
              canvasSize: CGSize,
              currentScale: CGFloat = 1.0) -> TidyViewport {

        // ── 0. Subset selection ─────────────────────────────────────────────
        let subset: [PatchbayNode] = nodeIds.map { ids in
            nodes.filter { ids.contains($0.id) }
        } ?? nodes
        guard !subset.isEmpty else { return TidyViewport(scale: currentScale, offset: .zero) }
        let idSet = Set(subset.map(\.id))

        // ── 1. Client adjacency graph (built from port IDs) ──────────────────
        var outEdges: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: subset.map { ($0.id, Set<String>()) })
        var inEdges:  [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: subset.map { ($0.id, Set<String>()) })
        for conn in connections {
            let f = String(conn.from.split(separator: ":").first ?? "")
            let t = String(conn.to.split(separator:  ":").first ?? "")
            guard f != t, idSet.contains(f), idSet.contains(t) else { continue }
            outEdges[f, default: []].insert(t)
            inEdges[t,  default: []].insert(f)
        }

        // ── 2. Connectivity predicates ───────────────────────────────────────
        func hasConnOut(_ n: PatchbayNode) -> Bool {
            n.outputs.contains { p in connections.contains { $0.from == p.id } }
        }
        func hasConnIn(_ n: PatchbayNode) -> Bool {
            n.inputs.contains  { p in connections.contains { $0.to   == p.id } }
        }

        // ── 3. Node classification ───────────────────────────────────────────
        // col0      : no input ports at all              → pure source
        // col1      : unconnected inputs + connected outputs → half-source
        // middle    : both sides connected               → topological rank
        // colLast1  : unconnected outputs + connected inputs → half-sink
        // colLast   : no output ports at all             → pure sink
        // orphan    : ports on both sides, none connected
        enum TidyCat: Equatable {
            case source, halfSource, middle, halfSink, sink, orphan
        }
        var cat:       [String: TidyCat] = [:]
        var middleIds: [String] = []
        var orphanIds: [String] = []

        for node in subset {
            let hasIn  = !node.inputs.isEmpty
            let hasOut = !node.outputs.isEmpty
            let cIn    = hasConnIn(node)
            let cOut   = hasConnOut(node)
            let c: TidyCat
            if      !hasIn  &&  cOut     { c = .source     }  // active source → col 0
            else if !hasOut &&  cIn      { c = .sink       }  // active sink   → col last
            else if !hasIn  && !cOut     { c = .orphan     }  // no connections → bottom-left
            else if !hasOut && !cIn      { c = .orphan     }  // no connections → bottom-right
            else if !cIn    &&  cOut     { c = .halfSource }  // free inputs + connected outputs
            else if !cOut   &&  cIn      { c = .halfSink   }  // free outputs + connected inputs
            else if  cIn    &&  cOut     { c = .middle     }
            else                         { c = .orphan     }
            cat[node.id] = c
            if c == .middle { middleIds.append(node.id) }
            if c == .orphan { orphanIds.append(node.id) }
        }

        // ── 4. Rank assignment for middle nodes (longest path from sources) ──
        var rank: [String: Int] = [:]
        for node in subset {
            switch cat[node.id]! {
            case .source:     rank[node.id] = -2
            case .halfSource: rank[node.id] = -1
            case .middle:     rank[node.id] =  0   // will be propagated
            case .halfSink:   rank[node.id] =  9998 // placeholder, overwritten below
            case .sink:       rank[node.id] =  9999 // placeholder, overwritten below
            case .orphan:     break
            }
        }
        // Iterative propagation (longest path, converges in ≤ N passes)
        for _ in 0..<middleIds.count {
            var changed = false
            for id in middleIds {
                let predMax = (inEdges[id] ?? [])
                    .compactMap { rank[$0] }
                    .filter { $0 < 9998 }   // ignorer les sinks placeholder
                    .max() ?? -1
                let newRank = predMax + 1
                if rank[id] != newRank { rank[id] = newRank; changed = true }
            }
            if !changed { break }
        }
        for id in middleIds { rank[id] = max(0, rank[id] ?? 0) }

        let maxMidRank = middleIds.compactMap { rank[$0] }.max() ?? -1
        let rLast1 = maxMidRank + 1
        let rLast  = maxMidRank + 2
        for node in subset {
            if cat[node.id] == .halfSink { rank[node.id] = rLast1 }
            if cat[node.id] == .sink     { rank[node.id] = rLast  }
        }

        // ── 5. Groups by rank (orphans excluded) ─────────────────────────────
        let orphanSet = Set(orphanIds)
        var colGroups: [Int: [String]] = [:]
        for node in subset where !orphanSet.contains(node.id) {
            guard let r = rank[node.id] else { continue }
            colGroups[r, default: []].append(node.id)
        }

        // ── 6. Crossing reduction — barycentre heuristic, 3 passes ──────────
        let sortedRanks = colGroups.keys.sorted()
        for pass in 0..<3 {
            let forward = pass % 2 == 0
            let seq     = forward ? sortedRanks : Array(sortedRanks.reversed())
            for r in seq {
                let adjR = forward ? r - 1 : r + 1
                guard let adjGroup = colGroups[adjR] else { continue }
                let adjIdx = Dictionary(
                    uniqueKeysWithValues: adjGroup.enumerated().map { ($1, $0) })

                func bary(_ id: String) -> Double {
                    let neighbors = ((forward ? inEdges[id] : outEdges[id]) ?? [])
                    let positions = neighbors.compactMap { adjIdx[$0] }.map { Double($0) }
                    guard !positions.isEmpty else { return Double(adjGroup.count) / 2 }
                    return positions.reduce(0, +) / Double(positions.count)
                }

                // Stable sort: connected nodes first, barycentre as tiebreak
                let indexed = (colGroups[r] ?? []).enumerated().map { ($1, $0) }
                colGroups[r] = indexed.sorted { a, b in
                    let na = subset.first { $0.id == a.0 }!
                    let nb = subset.first { $0.id == b.0 }!
                    let ca = hasConnIn(na) || hasConnOut(na)
                    let cb = hasConnIn(nb) || hasConnOut(nb)
                    if ca != cb { return ca }           // connected nodes first
                    let ba = bary(a.0), bb = bary(b.0)
                    if abs(ba - bb) > 0.001 { return ba < bb }
                    return a.1 < b.1                    // original order (stability)
                }.map(\.0)
            }
        }

        // ── 7. Rank → display column index (compresses empty ranks) ──────────
        let usedRanks = sortedRanks
        let nCols     = usedRanks.count
        let rankToCol = Dictionary(
            uniqueKeysWithValues: usedRanks.enumerated().map { ($1, $0) })

        // ── 8. Horizontal spacing ────────────────────────────────────────────
        let hPad:        CGFloat = 40
        let minGap:      CGFloat = 60
        let maxGap:      CGFloat = 120
        let hGap:        CGFloat
        let needsHDezoom: Bool
        if nCols <= 1 {
            hGap = minGap; needsHDezoom = false
        } else {
            let avail = canvasSize.width - CGFloat(nCols) * nodeW - hPad * 2
            let ideal = avail / CGFloat(nCols - 1)
            if ideal < minGap { hGap = minGap; needsHDezoom = true  }
            else              { hGap = min(ideal, maxGap); needsHDezoom = false }
        }

        func colX(_ r: Int) -> CGFloat {
            hPad + CGFloat(rankToCol[r] ?? 0) * (nodeW + hGap)
        }

        // ── 9. Node height (respects collapsed state) ────────────────────────
        func nodeH(_ node: PatchbayNode) -> CGFloat {
            let rows = CGFloat(max(node.inputCount, node.outputCount))
            return node.isCollapsed ? headerH : headerH + rows * rowH + 6
        }

        // ── 10. Y positions within each column ───────────────────────────────
        let topPad:  CGFloat = 40
        let nodeGap: CGFloat = 20
        var newPos: [String: CGPoint] = [:]
        var maxBottomY: CGFloat = topPad

        for r in usedRanks {
            var y = topPad
            for id in colGroups[r] ?? [] {
                let node = subset.first { $0.id == id }!
                newPos[id] = CGPoint(x: colX(r), y: y)
                y += nodeH(node) + nodeGap
            }
            maxBottomY = max(maxBottomY, y)
        }

        // ── 11. Orphans — below the main layout, grouped left/center/right ───
        let orphanTopY   = usedRanks.isEmpty ? topPad : maxBottomY + 40
        let totalLayoutW = nCols > 0
            ? colX(usedRanks.last!) + nodeW + hPad
            : hPad + nodeW + hPad

        // Orphans with ports on both sides (by construction) are placed at the centre
        func placeOrphans(_ ids: [String], startX: CGFloat) {
            var y = orphanTopY
            for id in ids {
                let node = subset.first { $0.id == id }!
                newPos[id] = CGPoint(x: startX, y: y)
                y += nodeH(node) + nodeGap
            }
        }
        let noInOrphans  = orphanIds.filter { id in subset.first { $0.id == id }!.inputs.isEmpty  }
        let noOutOrphans = orphanIds.filter { id in subset.first { $0.id == id }!.outputs.isEmpty }
        let bothOrphans  = orphanIds.filter { id in
            let n = subset.first { $0.id == id }!
            return !n.inputs.isEmpty && !n.outputs.isEmpty
        }
        placeOrphans(noInOrphans,  startX: hPad)
        placeOrphans(bothOrphans,  startX: max(hPad, totalLayoutW / 2 - nodeW / 2))
        placeOrphans(noOutOrphans, startX: max(hPad, totalLayoutW - hPad - nodeW))

        // ── 12. Apply positions with spring animation ────────────────────────
        var updated = nodes
        for (id, pos) in newPos {
            if let i = updated.firstIndex(where: { $0.id == id }) {
                updated[i].position = pos
            }
        }

        // Partial tidy: push out-of-subset nodes that overlap newly placed nodes
        if nodeIds != nil {
            let subsetIdSet = Set(subset.map(\.id))
            for i in updated.indices where !subsetIdSet.contains(updated[i].id) {
                let others = updated.filter { $0.id != updated[i].id }
                let pushed = resolveCollisionAmong(others, for: updated[i],
                                                   at: updated[i].position)
                if pushed != updated[i].position { updated[i].position = pushed }
            }
        }

        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            nodes = updated
        }

        // ── 13. Fit-to-view ──────────────────────────────────────────────────
        guard !newPos.isEmpty else { return TidyViewport(scale: currentScale, offset: .zero) }

        let allX   = newPos.values.map(\.x)
        let allY   = newPos.values.map(\.y)
        let minX   = allX.min()!
        let minY   = allY.min()!
        let maxX   = newPos.values.map { $0.x + nodeW }.max()!
        let maxOrphanY = orphanIds.isEmpty ? 0 :
            orphanTopY + CGFloat(max(noInOrphans.count, noOutOrphans.count, bothOrphans.count))
                         * (headerH + nodeGap)
        let maxY   = max(maxBottomY, maxOrphanY)

        let contentW = max(1, maxX - minX)
        let contentH = max(1, maxY  - minY)

        let scaleToFit = min(
            (canvasSize.width  - hPad   * 2) / contentW,
            (canvasSize.height - topPad * 2) / contentH
        )
        let contentFits = contentW * currentScale <= canvasSize.width  - hPad   * 2
                       && contentH * currentScale <= canvasSize.height - topPad * 2
        let finalScale: CGFloat = (needsHDezoom || !contentFits)
            ? max(0.3, min(currentScale, scaleToFit * 0.92))
            : currentScale

        let offX = (canvasSize.width  - contentW * finalScale) / 2 - minX * finalScale
        let offY = (canvasSize.height - contentH * finalScale) / 2 - minY * finalScale

        return TidyViewport(scale: finalScale,
                            offset: CGSize(width: offX, height: offY))
    }

    // MARK: - Node position

    // ── Cable geometry helpers ────────────────────────────────────────────────

    /// Test d'intersection entre deux segments [AB] et [CD].
    private func segmentsIntersect(_ a: CGPoint, _ b: CGPoint,
                                   _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ u: CGPoint, _ v: CGPoint) -> CGFloat {
            (u.x - o.x) * (v.y - o.y) - (u.y - o.y) * (v.x - o.x)
        }
        let d1 = cross(c, d, a), d2 = cross(c, d, b)
        let d3 = cross(a, b, c), d4 = cross(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// Point-in-polygon test using ray casting (works for any convex or concave polygon).
    private func pointInPolygon(_ p: CGPoint, poly: [CGPoint]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let vi = poly[i], vj = poly[j]
            if ((vi.y > p.y) != (vj.y > p.y)) &&
               (p.x < (vj.x - vi.x) * (p.y - vi.y) / (vj.y - vi.y) + vi.x) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Tests whether a 4-vertex quadrilateral intersects a `CGRect`.
    private func quadIntersectsRect(_ quad: [CGPoint], _ rect: CGRect) -> Bool {
        let corners = [CGPoint(x: rect.minX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY),
                       CGPoint(x: rect.minX, y: rect.maxY)]
        // A quad vertex inside the rect
        for v in quad where rect.contains(v) { return true }
        // A rect corner inside the quad
        for c in corners where pointInPolygon(c, poly: quad) { return true }
        // Edge intersection
        for i in 0..<4 {
            let qa = quad[i], qb = quad[(i + 1) % 4]
            for j in 0..<4 where segmentsIntersect(qa, qb, corners[j], corners[(j + 1) % 4]) {
                return true
            }
        }
        return false
    }

    /// Tests whether the "cable corridor" between connected nodes intersects `nodeRect`.
    /// For each (srcNode → dstNode) pair, the corridor is the quadrilateral connecting the
    /// extreme ports (min/max Y) on both sides ± rowH/2.
    private func cableZoneIntersects(_ nodeRect: CGRect, excludingNode excludedId: String) -> Bool {
        let prefix = excludedId + ":"
        let half   = rowH / 2

        // Group connections by (srcNodeId → dstNodeId) pair
        struct Bundle {
            let src: PatchbayNode
            let dst: PatchbayNode
            var outYs: [CGFloat]
            var inYs:  [CGFloat]
        }
        var bundles: [String: Bundle] = [:]

        for conn in connections
            where !conn.from.hasPrefix(prefix) && !conn.to.hasPrefix(prefix)
        {
            let fromParts = conn.from.split(separator: ":", maxSplits: 1)
            let toParts   = conn.to.split(separator: ":",   maxSplits: 1)
            guard fromParts.count == 2, toParts.count == 2 else { continue }
            let srcId = String(fromParts[0]), dstId = String(toParts[0])
            guard let src = nodes.first(where: { $0.id == srcId }),
                  let dst = nodes.first(where: { $0.id == dstId }) else { continue }

            let outIdx = src.outputs.firstIndex(where: { $0.id == conn.from }) ?? 0
            let inIdx  = dst.inputs.firstIndex(where:  { $0.id == conn.to  }) ?? 0
            let outY = src.position.y + headerH + 3 + CGFloat(outIdx) * rowH + rowH / 2
            let inY  = dst.position.y + headerH + 3 + CGFloat(inIdx)  * rowH + rowH / 2

            let key = "\(srcId)→\(dstId)"
            if bundles[key] == nil {
                bundles[key] = Bundle(src: src, dst: dst, outYs: [outY], inYs: [inY])
            } else {
                bundles[key]!.outYs.append(outY)
                bundles[key]!.inYs.append(inY)
            }
        }

        for (_, b) in bundles {
            let minOut = (b.outYs.min() ?? 0) - half
            let maxOut = (b.outYs.max() ?? 0) + half
            let minIn  = (b.inYs.min()  ?? 0) - half
            let maxIn  = (b.inYs.max()  ?? 0) + half
            let srcX   = b.src.position.x + nodeW
            let dstX   = b.dst.position.x

            // Quadrilateral: V0(src,top) V1(src,bot) V2(dst,bot) V3(dst,top)
            let quad = [CGPoint(x: srcX, y: minOut),
                        CGPoint(x: srcX, y: maxOut),
                        CGPoint(x: dstX, y: maxIn),
                        CGPoint(x: dstX, y: minIn)]

            if quadIntersectsRect(quad, nodeRect) { return true }
        }
        return false
    }

    // ── Drop collision resolution ──────────────────────────────────────────────

    /// Finds the nearest free position to `pos` using radial scanning.
    /// - `within`:  Canvas rect in which the node must remain (viewport).
    /// - No overlap on drop → `pos` returned unchanged.
    /// - Overlap → concentric rings scanned outward; first free candidate returned.
    /// - Priority: nodes + cables + viewport → nodes + viewport → nodes only.
    func resolveDropCollision(for nodeId: String,
                              at pos: CGPoint,
                              within viewport: CGRect? = nil) -> CGPoint {

        func nh(_ node: PatchbayNode) -> CGFloat {
            let rows = CGFloat(max(node.inputCount, node.outputCount))
            return node.isCollapsed ? headerH : headerH + rows * rowH + 6
        }
        func nodeRect(_ p: CGPoint, _ node: PatchbayNode) -> CGRect {
            CGRect(x: p.x, y: p.y, width: nodeW, height: nh(node))
        }

        guard let dragged = nodes.first(where: { $0.id == nodeId }) else { return pos }
        let others  = nodes.filter { $0.id != nodeId }
        let dragH   = nh(dragged)
        let gap: CGFloat = 8   // espace minimal entre nœuds

        // No overlap — return position unchanged
        guard others.contains(where: { nodeRect(pos, dragged).intersects(nodeRect($0.position, $0)) })
        else { return pos }

        func inViewport(_ p: CGPoint) -> Bool {
            guard let vp = viewport else { return true }
            return p.x >= vp.minX && p.y >= vp.minY
                && p.x + nodeW <= vp.maxX && p.y + dragH <= vp.maxY
        }
        func collidesNodes(_ p: CGPoint) -> Bool {
            // Expand rect by `gap` to enforce minimum spacing between nodes
            let r = nodeRect(p, dragged).insetBy(dx: -gap, dy: -gap)
            return others.contains { r.intersects(nodeRect($0.position, $0)) }
        }
        func collidesCables(_ p: CGPoint) -> Bool {
            cableZoneIntersects(nodeRect(p, dragged), excludingNode: nodeId)
        }

        // Generate candidates in concentric rings around pos
        let step: CGFloat   = 20        // pas en coordonnées canvas
        let maxRadius: CGFloat = nodeW * 4  // ~800 px canvas
        var pts: [CGPoint] = []
        var r = step
        while r <= maxRadius {
            let nAngles = max(8, min(48, Int(2 * .pi * r / step)))
            for i in 0..<nAngles {
                let angle = CGFloat(i) * 2 * .pi / CGFloat(nAngles)
                pts.append(CGPoint(x: pos.x + r * cos(angle),
                                   y: pos.y + r * sin(angle)))
            }
            r += step
        }

        // Pass 1: nodes + cables + viewport
        for c in pts where inViewport(c) && !collidesNodes(c) && !collidesCables(c) { return c }
        // Pass 2: nodes + viewport (cables ignored)
        for c in pts where inViewport(c) && !collidesNodes(c) { return c }
        // Pass 3: nodes only (viewport ignored — last resort)
        for c in pts where !collidesNodes(c) { return c }

        return pos
    }

    /// After a group drag, resolves overlaps for nodes that were NOT part of the drag.
    /// Dragged nodes keep their exact positions; non-dragged nodes are nudged if needed.
    func resolveGroupDropCollisions(movedIds: Set<String>, within viewport: CGRect? = nil) {
        func nh(_ node: PatchbayNode) -> CGFloat {
            let rows = CGFloat(max(node.inputCount, node.outputCount))
            return node.isCollapsed ? headerH : headerH + rows * rowH + 6
        }
        func nodeRect(_ node: PatchbayNode) -> CGRect {
            CGRect(x: node.position.x, y: node.position.y, width: nodeW, height: nh(node))
        }

        let movedNodes = nodes.filter { movedIds.contains($0.id) }
        var anyMoved = false

        for i in nodes.indices where !movedIds.contains(nodes[i].id) {
            let current = nodes[i]
            guard movedNodes.contains(where: { nodeRect(current).intersects(nodeRect($0)) })
            else { continue }
            let resolved = resolveDropCollision(for: current.id,
                                                at: current.position,
                                                within: viewport)
            if resolved != current.position {
                nodes[i].position = resolved
                anyMoved = true
            }
        }

        if anyMoved { triggerRepositionToast() }
    }

    // MARK: - Transport actions

    func transportPlay()  { bridge.transportStart()  }
    func transportPause() { bridge.transportPause()  }
    func transportStop()  { bridge.transportStop()   }   // stop + rewind frame 0
    func transportLocate(frame: UInt32) { bridge.transportLocate(frame: frame) }

    func toggleTimebaseMaster(bpm: Double = 120, beatsPerBar: Float = 4, beatType: Float = 4) {
        if bridge.isTimebaseMaster {
            bridge.releaseTimebase()
        } else {
            bridge.becomeTimebaseMaster(
                bpm: bpm, beatsPerBar: beatsPerBar, beatType: beatType, conditional: true)
        }
        // TransportObserver will update isMaster within 120 ms
    }

    func updateBPM(_ bpm: Double) {
        bridge.updateTimebaseBPM(bpm)
    }

    func triggerRepositionToast() {
        showRepositionToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.showRepositionToast = false }
        }
    }

    /// Moves nodes that are entirely outside the visible viewport to the nearest edge,
    /// then resolves any resulting overlaps.
    func bringOffScreenNodes(visibleRect: CGRect) {
        let margin: CGFloat = 20
        let inner = visibleRect.insetBy(dx: margin, dy: margin)
        guard inner.width > 0, inner.height > 0 else { return }

        func nodeH(_ n: PatchbayNode) -> CGFloat {
            n.isCollapsed ? headerH : headerH + CGFloat(max(n.inputCount, n.outputCount)) * rowH + 6
        }

        var movedIds: [String] = []
        for i in nodes.indices {
            let node = nodes[i]
            let h    = nodeH(node)
            let rect = CGRect(x: node.position.x, y: node.position.y, width: nodeW, height: h)
            guard !inner.intersects(rect) else { continue }

            var x = node.position.x
            var y = node.position.y
            if rect.maxX < inner.minX        { x = inner.minX }
            else if rect.minX > inner.maxX   { x = inner.maxX - nodeW }
            if rect.maxY < inner.minY        { y = inner.minY }
            else if rect.minY > inner.maxY   { y = inner.maxY - h }

            nodes[i].position = CGPoint(x: max(0, x), y: max(0, y))
            movedIds.append(node.id)
        }

        // Resolve overlaps for the nodes that were moved back on screen
        for id in movedIds {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { continue }
            let others   = nodes.filter { $0.id != id }
            let resolved = resolveCollisionAmong(others, for: nodes[idx], at: nodes[idx].position)
            nodes[idx].position = resolved
        }
    }

    /// Updates the canvas position of a node, resolving collisions.
    func updateNodePosition(_ nodeId: String, to position: CGPoint) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeId }) else { return }
        nodes[idx].position = resolveCollision(for: nodeId, at: position)
    }

    private func resolveCollision(for nodeId: String, at pos: CGPoint) -> CGPoint {
        let padding: CGFloat = 10

        func nodeHeight(_ node: PatchbayNode) -> CGFloat {
            let rows = CGFloat(max(node.inputCount, node.outputCount))
            return node.isCollapsed ? headerH : headerH + rows * rowH + 6
        }

        func rect(_ p: CGPoint, _ node: PatchbayNode) -> CGRect {
            CGRect(x: p.x, y: p.y, width: nodeW, height: nodeHeight(node))
        }

        guard let dragged = nodes.first(where: { $0.id == nodeId }) else { return pos }
        let others = nodes.filter { $0.id != nodeId }

        func collides(_ p: CGPoint) -> Bool {
            let r = rect(p, dragged).insetBy(dx: -padding/2, dy: -padding/2)
            return others.contains { rect($0.position, $0).insetBy(dx: -padding/2, dy: -padding/2).intersects(r) }
        }

        if !collides(pos) { return pos }

        let stepX = nodeW   + padding
        let stepY = nodeHeight(dragged) + padding

        for dist in 1...16 {
            let d = CGFloat(dist)
            let candidates: [CGPoint] = [
                CGPoint(x: pos.x + stepX * d,  y: pos.y),
                CGPoint(x: pos.x - stepX * d,  y: pos.y),
                CGPoint(x: pos.x,               y: pos.y + stepY * d),
                CGPoint(x: pos.x,               y: pos.y - stepY * d),
                CGPoint(x: pos.x + stepX * d,  y: pos.y + stepY * d),
                CGPoint(x: pos.x - stepX * d,  y: pos.y + stepY * d),
                CGPoint(x: pos.x + stepX * d,  y: pos.y - stepY * d),
                CGPoint(x: pos.x - stepX * d,  y: pos.y - stepY * d),
            ]
            if let free = candidates.first(where: { $0.x >= 0 && $0.y >= 0 && !collides($0) }) {
                return free
            }
        }
        return pos
    }

    /// Positions queued for application when their nodes haven't been created yet
    private var pendingPositions: [NodePosition] = []

    /// Applies a list of saved node positions, queuing any whose node doesn't exist yet.
    func applyNodePositions(_ positions: [NodePosition]) {
        guard !positions.isEmpty else { return }
        pendingPositions = positions
        flushPendingPositions()
    }

    /// Applique les positions en attente pour les nodes qui existent déjà.
    /// Les positions des nodes pas encore créés restent en attente pour le prochain applyPorts.
    /// Appelé après chaque mise à jour de nodes (initialLoad, refresh).
    private func flushPendingPositions() {
        guard !pendingPositions.isEmpty, !nodes.isEmpty else { return }
        var updated = nodes
        var appliedIds = Set<String>()
        for pos in pendingPositions {
            if let idx = updated.firstIndex(where: { $0.id == pos.id }) {
                updated[idx].position = CGPoint(x: pos.x, y: pos.y)
                appliedIds.insert(pos.id)
            }
        }
        guard !appliedIds.isEmpty else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            nodes = updated
        }
        // Only remove applied positions — others stay pending until their node is created
        pendingPositions.removeAll { appliedIds.contains($0.id) }
    }

    /// Toggles the collapsed state of a single node.
    func toggleCollapse(_ nodeId: String) {
        if let idx = nodes.firstIndex(where: { $0.id == nodeId }) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                nodes[idx].isCollapsed.toggle()
            }
        }
    }

    /// Collapses or expands all selected nodes based on majority state.
    /// Non-collapsed majority (or tie) → collapse all.
    /// Collapsed majority → expand all.
    func toggleCollapseSelected() {
        let selected = nodes.filter { selectedNodeIds.contains($0.id) }
        guard !selected.isEmpty else { return }
        let collapsedCount    = selected.filter { $0.isCollapsed }.count
        let nonCollapsedCount = selected.count - collapsedCount
        let shouldCollapse    = nonCollapsedCount >= collapsedCount
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            for i in nodes.indices where selectedNodeIds.contains(nodes[i].id) {
                nodes[i].isCollapsed = shouldCollapse
            }
        }
    }

    // MARK: - Studios

    // MARK: - Logging

    /// Appends a log message to the Jack log via the `JackManager`.
    func logToJack(_ msg: String) {
        jackManager?.appendLogs([msg])
    }
}
