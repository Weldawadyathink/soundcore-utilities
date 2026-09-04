//
//  BluetoothManager.swift
//  Soundcore Utilities
//
//  CoreBluetooth front end for the Sleep A30. PacketLogger captures show the
//  official app writing Soundcore packets as ATT Write Commands (GATT) over
//  the earbuds' Bluetooth Classic link, so CoreBluetooth with transport
//  bridging is the right API.
//
//  The A30 shows up in CoreBluetooth as two peripherals: the LE identity
//  ("soundcore Sleep A30 LE", random address) and the Classic identity that
//  iOS bridges GATT over BR/EDR for. A capture of both apps side by side
//  showed identical packets on the same ATT handle, but only writes on the
//  Classic link are answered; the LE GATT server accepts them silently.
//  Transport bridging cannot join the two because the LE address is random.
//
//  Nothing device-specific is hard-coded. The manager:
//    1. gathers every peripheral that could be a Sleep A30: the identity that
//       answered last time, system-connected peripherals whose name matches
//       (non-"LE" names first), then LE advertisements,
//    2. connects to each in turn, discovers every service and characteristic,
//       subscribes to anything that can notify, and learns the service UUIDs
//       so the system-connected query can find the Classic identity,
//    3. ranks writable characteristics structurally (write-without-response in
//       a vendor service that also has a notify characteristic scores highest),
//    4. probes each candidate with a harmless "request state" packet; the
//       first peripheral/characteristic pair the earbuds answer wins and is
//       remembered for next time; a peripheral that never answers is dropped
//       and the next identity is tried,
//    5. tracks the earbuds' acknowledgement of every command so the UI can say
//       whether the device actually responded.
//

import CoreBluetooth
import Foundation
import Observation

struct DiscoveredPeripheral: Identifiable {
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var advertisedServices: [CBUUID]
    var manufacturerData: Data?
    var lastSeen: Date

    var id: UUID { peripheral.identifier }
}

struct LogEntry: Identifiable {
    enum Kind {
        case info, tx, rx, error
    }

    let id = UUID()
    let date = Date()
    let kind: Kind
    let message: String
}

enum ConnectionPhase: Equatable {
    case idle
    case bluetoothOff
    case unauthorized
    case searching
    case connecting
    case discovering
    case probing
    case ready
    case notFound
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .bluetoothOff: return "Bluetooth off"
        case .unauthorized: return "Bluetooth access denied"
        case .searching: return "Searching"
        case .connecting: return "Connecting"
        case .discovering: return "Discovering services"
        case .probing: return "Probing characteristics"
        case .ready: return "Ready"
        case .notFound: return "Not found"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

struct A30State: Equatable {
    var audioSource: SoundcorePacket.AudioSource?
    var noiseCancelling: Bool?
    var sleepTimer: SoundcorePacket.SleepTimerStatus?
    /// The sleep-settings flag (1 = local audio + ANC off, 0 = pause) as last reported.
    var sleepSettingsFlag: UInt8?
    /// Whether auto-switch is on. Not yet readable from the state dump, so this is
    /// only known after we set it ourselves.
    var autoSwitchEnabled: Bool?
    var firmwareLeft: String?
    var firmwareRight: String?
    var serialNumber: String?
    var batteryLevelLeft: UInt8?
    var batteryLevelRight: UInt8?
    var caseBatteryPercent: UInt8?
    var bothEarbudsConnected: Bool?
    var bluetoothAudioPlaying: Bool?
    var localAudioActive: Bool?
    /// When the last 15 03 status arrived, so the UI can count down from `remainingSeconds`.
    var sleepTimerReceivedAt: Date?
    var updatedAt: Date?

    var autoSwitch: SoundcorePacket.AutoSwitchOption? {
        guard let autoSwitchEnabled, let sleepSettingsFlag else { return nil }
        return .from(enabled: autoSwitchEnabled, flag: sleepSettingsFlag)
    }
}

/// One labelled capture of the 01 01 state dump, used to map its layout.
struct StateSnapshot: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var label: String
    var body: Data

    /// Body offsets whose value differs from `previous`.
    func changedOffsets(from previous: StateSnapshot?) -> Set<Int> {
        guard let previous else { return [] }
        var changed: Set<Int> = []
        let count = max(body.count, previous.body.count)
        for index in 0..<count {
            let a: UInt8? = index < body.count ? body[index] : nil
            let b: UInt8? = index < previous.body.count ? previous.body[index] : nil
            if a != b { changed.insert(index) }
        }
        return changed
    }
}

struct CommandResult: Equatable {
    enum Status: Equatable {
        case sent, acknowledged, noResponse
    }

    let command: SoundcorePacket.Command
    var status: Status
    var date: Date
}

struct WriteCandidate: Identifiable {
    let characteristic: CBCharacteristic
    let score: Int
    var id: ObjectIdentifier { ObjectIdentifier(characteristic) }
}

/// Errors surfaced to Shortcuts. Each has a sentence a person can act on.
enum A30Error: Error, CustomLocalizedStringResourceConvertible {
    case bluetoothOff
    case unauthorized
    case notFound
    case connectionFailed(String)
    case noResponse(String)
    case timedOut

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .bluetoothOff: return "Bluetooth is off."
        case .unauthorized: return "Soundcore Utilities is not allowed to use Bluetooth. Enable it in Settings."
        case .notFound: return "No Sleep A30 is connected. Connect the earbuds in Settings › Bluetooth first."
        case .connectionFailed(let message): return "Could not connect to the Sleep A30: \(message)"
        case .noResponse(let command): return "The earbuds did not confirm \(command)."
        case .timedOut: return "Timed out waiting for the Sleep A30."
        }
    }
}

@Observable
final class BluetoothManager: NSObject {
    /// One instance for the UI and for App Intents, which run inside the app process.
    static let shared = BluetoothManager()

    private(set) var state: CBManagerState = .unknown
    private(set) var isScanning = false
    var useTransportBridging = true
    var showOnlyNamed = true

    private(set) var discovered: [DiscoveredPeripheral] = []
    private(set) var systemConnected: [CBPeripheral] = []

    private(set) var phase: ConnectionPhase = .idle
    private(set) var connectedPeripheral: CBPeripheral?
    private(set) var services: [CBService] = []
    private(set) var characteristics: [CBCharacteristic] = []
    private(set) var writeCandidates: [WriteCandidate] = []
    private(set) var selectedWriteCharacteristic: CBCharacteristic?
    /// nil = not probed yet, true = earbuds answered the probe, false = no candidate answered.
    private(set) var probeConfirmed: Bool?
    private(set) var deviceState = A30State()
    private(set) var lastCommandResult: CommandResult?
    private(set) var log: [LogEntry] = []
    private(set) var lastStateDump: Data?
    private(set) var snapshots: [StateSnapshot] = []

    /// Service UUIDs seen on any peripheral identified as a Sleep A30. Persisted
    /// so `retrieveConnectedPeripherals` can find the Classic identity on launch.
    private(set) var learnedServiceUUIDs: [CBUUID] = []
    /// Identifier of the peripheral that last answered the probe. Persisted.
    private(set) var knownGoodIdentifier: UUID?
    /// Identities tried during the current auto-connect attempt that did not answer.
    private(set) var triedIdentifiers: Set<UUID> = []

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var pendingServiceDiscovery = 0
    @ObservationIgnored private var inboundFrameCount = 0
    @ObservationIgnored private var pendingCommand: SoundcorePacket.Command?
    @ObservationIgnored private var pendingSnapshotLabel: String?
    @ObservationIgnored private var followUpTask: Task<Void, Never>?
    @ObservationIgnored private var wantsAutoConnect = false
    @ObservationIgnored private var reconnectAttempted = false
    @ObservationIgnored private var continueAfterDisconnect = false
    @ObservationIgnored private var searchTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var connectTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var ackTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    static let searchTimeout: Duration = .seconds(12)
    static let connectTimeout: Duration = .seconds(10)
    static let learnedServicesKey = "learnedServiceUUIDs"
    static let knownGoodIdentifierKey = "knownGoodPeripheralIdentifier"
    static let snapshotsKey = "stateSnapshots"
    static let probeTimeout: Duration = .milliseconds(1500)
    static let ackTimeout: Duration = .milliseconds(2500)

    /// Services to ask the system about for "already connected" peripherals.
    /// CoreBluetooth requires at least one UUID for that query, so this is a
    /// wide net: the standard profiles plus the 16-bit vendor range Soundcore
    /// products have been seen using.
    static let candidateServiceUUIDs: [CBUUID] = [
        CBUUID(string: "1800"), CBUUID(string: "1801"), CBUUID(string: "180A"), CBUUID(string: "180F"),
        CBUUID(string: "FF00"), CBUUID(string: "FF01"), CBUUID(string: "FF10"), CBUUID(string: "FFC0"),
        CBUUID(string: "FFE0"), CBUUID(string: "FFE5"), CBUUID(string: "FFF0"), CBUUID(string: "FEE7"),
        CBUUID(string: "FE2C"), CBUUID(string: "FD2D"), CBUUID(string: "0000FF00-0000-1000-8000-00805F9B34FB"),
    ]

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        learnedServiceUUIDs = (defaults.stringArray(forKey: Self.learnedServicesKey) ?? []).map { CBUUID(string: $0) }
        knownGoodIdentifier = defaults.string(forKey: Self.knownGoodIdentifierKey).flatMap(UUID.init)
        if let data = defaults.data(forKey: Self.snapshotsKey),
           let saved = try? JSONDecoder().decode([StateSnapshot].self, from: data) {
            snapshots = saved
        }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - State snapshots (developer tool)

    /// Requests the state dump and files the reply under `label`.
    func captureSnapshot(label: String) {
        guard canSend else {
            append(.error, "Cannot capture snapshot: not ready")
            return
        }
        pendingSnapshotLabel = label.isEmpty ? "Snapshot \(snapshots.count + 1)" : label
        send(SoundcorePacket.requestState)
    }

    func deleteSnapshots(at offsets: IndexSet) {
        snapshots = snapshots.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        persistSnapshots()
    }

    func clearSnapshots() {
        snapshots.removeAll()
        persistSnapshots()
    }

    private func persistSnapshots() {
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: Self.snapshotsKey)
        }
    }

    /// Plain-text export: every snapshot as an offset-labelled hex dump plus the bytes that changed.
    func exportSnapshots() -> String {
        var lines: [String] = ["Sleep A30 state snapshots (01 01 reply body, offsets from body start)", ""]
        var previous: StateSnapshot?
        for (index, snapshot) in snapshots.enumerated() {
            lines.append("## \(index + 1). \(snapshot.label)  (\(snapshot.date.formatted(date: .abbreviated, time: .standard)), \(snapshot.body.count) bytes)")
            let bytes = [UInt8](snapshot.body)
            for row in stride(from: 0, to: bytes.count, by: 16) {
                let slice = bytes[row..<min(row + 16, bytes.count)]
                lines.append(String(format: "%03d: ", row) + slice.map { String(format: "%02X", $0) }.joined(separator: " "))
            }
            let changed = snapshot.changedOffsets(from: previous).sorted()
            if let previous {
                if changed.isEmpty {
                    lines.append("changed vs previous: none")
                } else {
                    let details = changed.map { offset -> String in
                        let old = offset < previous.body.count ? String(format: "%02X", previous.body[offset]) : "--"
                        let new = offset < snapshot.body.count ? String(format: "%02X", snapshot.body[offset]) : "--"
                        return "\(offset): \(old)->\(new)"
                    }
                    lines.append("changed vs previous: " + details.joined(separator: ", "))
                }
            }
            lines.append("")
            previous = snapshot
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Device identification

    /// Matches "soundcore Sleep A30" and "soundcore Sleep A30 LE" without
    /// depending on a specific unit.
    nonisolated static func looksLikeA30(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name.contains("a30") && (name.contains("soundcore") || name.contains("sleep"))
    }

    /// The LE identity advertises with an " LE" suffix; the Classic identity does not.
    nonisolated static func isLEIdentityName(_ name: String?) -> Bool {
        guard let name = name?.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
        return name.hasSuffix(" le") || name.hasSuffix("-le") || name.hasSuffix("_le")
    }

    var connectedDeviceName: String? {
        connectedPeripheral.map(Self.displayName)
    }

    /// All service UUIDs worth asking the system about: the generic net plus whatever we have learned.
    private var connectedQueryUUIDs: [CBUUID] {
        var set = Self.candidateServiceUUIDs
        for uuid in learnedServiceUUIDs where !set.contains(uuid) { set.append(uuid) }
        return set
    }

    private var vendorLearnedServiceUUIDs: [CBUUID] {
        learnedServiceUUIDs.filter { !Self.isStandardService($0) }
    }

    private func learnServices(_ uuids: [CBUUID]) {
        var merged = learnedServiceUUIDs
        for uuid in uuids where !merged.contains(uuid) { merged.append(uuid) }
        guard merged.count != learnedServiceUUIDs.count else { return }
        learnedServiceUUIDs = merged
        UserDefaults.standard.set(merged.map(\.uuidString), forKey: Self.learnedServicesKey)
        append(.info, "Learned service UUIDs: \(merged.map(\.uuidString).joined(separator: ", "))")
    }

    private func remember(knownGood identifier: UUID?) {
        knownGoodIdentifier = identifier
        UserDefaults.standard.set(identifier?.uuidString, forKey: Self.knownGoodIdentifierKey)
    }

    /// Clears everything learned about the earbuds (developer screen).
    func forgetLearnedDevice() {
        learnedServiceUUIDs = []
        remember(knownGood: nil)
        UserDefaults.standard.removeObject(forKey: Self.learnedServicesKey)
        append(.info, "Forgot learned services and known-good identity")
    }

    /// Whether a GATT table looks like the one we learned from a Sleep A30.
    private func gattMatchesLearned(_ services: [CBService]) -> Bool {
        let present = Set(services.map(\.uuid))
        let vendor = vendorLearnedServiceUUIDs
        if !vendor.isEmpty { return vendor.allSatisfy(present.contains) }
        return !learnedServiceUUIDs.isEmpty && learnedServiceUUIDs.allSatisfy(present.contains)
    }

    // MARK: - Automatic flow

    /// Finds a Sleep A30, connects, discovers, and probes. Safe to call repeatedly.
    func autoConnect() {
        wantsAutoConnect = true
        reconnectTask?.cancel()
        switch state {
        case .poweredOn:
            break
        case .unauthorized:
            phase = .unauthorized
            return
        case .unknown, .resetting:
            // Wait for centralManagerDidUpdateState to call back in.
            return
        default:
            phase = .bluetoothOff
            return
        }
        if let peripheral = connectedPeripheral, peripheral.state == .connected {
            if phase == .ready || phase == .discovering || phase == .probing { return }
        }
        if phase == .connecting || phase == .searching { return }

        triedIdentifiers = []
        append(.info, "Auto-connect: searching for a Sleep A30")
        tryNextCandidate()
    }

    /// Candidate identities in the order worth trying, excluding ones that already failed this attempt.
    private func nextCandidate() -> CBPeripheral? {
        var ordered: [CBPeripheral] = []
        if let identifier = knownGoodIdentifier {
            ordered += central.retrievePeripherals(withIdentifiers: [identifier])
        }
        let named = systemConnected.filter { Self.looksLikeA30($0.name) }
        ordered += named.filter { !Self.isLEIdentityName($0.name) }
        ordered += named.filter { Self.isLEIdentityName($0.name) }
        // Unnamed system peripherals are only worth a look once we know what an A30's GATT table looks like.
        if !learnedServiceUUIDs.isEmpty {
            ordered += systemConnected.filter { $0.name == nil }
        }
        ordered += discovered.filter { Self.looksLikeA30($0.name) }.map(\.peripheral)
        var seen: Set<UUID> = []
        return ordered.first { peripheral in
            guard !triedIdentifiers.contains(peripheral.identifier), !seen.contains(peripheral.identifier) else { return false }
            seen.insert(peripheral.identifier)
            return true
        }
    }

    private func tryNextCandidate() {
        phase = .searching
        refreshSystemConnected()
        if let candidate = nextCandidate() {
            append(.info, "Auto-connect: trying \(Self.displayName(candidate)) (\(candidate.identifier.uuidString))")
            connect(candidate)
            return
        }
        startScan()
        searchTimeoutTask?.cancel()
        searchTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchTimeout)
            guard !Task.isCancelled, let self, self.phase == .searching else { return }
            self.stopScan()
            if self.triedIdentifiers.isEmpty {
                self.phase = .notFound
                self.append(.error, "Auto-connect: no Sleep A30 found within \(Self.searchTimeout)")
            } else {
                self.phase = .failed("Found a Sleep A30 but it did not answer on any connection")
                self.append(.error, "Auto-connect: \(self.triedIdentifiers.count) identit(ies) tried, none answered")
            }
        }
    }

    /// Gives up on the current peripheral and moves on to the next candidate identity.
    private func dropCurrentAndContinue(reason: String) {
        guard let peripheral = connectedPeripheral else {
            tryNextCandidate()
            return
        }
        triedIdentifiers.insert(peripheral.identifier)
        append(.info, "Auto-connect: dropping \(Self.displayName(peripheral)): \(reason)")
        if peripheral.state == .connected || peripheral.state == .connecting {
            continueAfterDisconnect = true
            central.cancelPeripheralConnection(peripheral)
        } else {
            connectedPeripheral = nil
            resetPeripheralState()
            tryNextCandidate()
        }
    }

    func cancelAutoConnect() {
        wantsAutoConnect = false
        searchTimeoutTask?.cancel()
        connectTimeoutTask?.cancel()
        reconnectTask?.cancel()
        if phase == .searching {
            stopScan()
            phase = .idle
        }
    }

    /// Re-runs the characteristic probe on the current connection.
    func probeAgain() {
        guard connectedPeripheral?.state == .connected, !writeCandidates.isEmpty else { return }
        probeTask?.cancel()
        probeTask = Task { [weak self] in await self?.runProbe() }
    }

    // MARK: - Manual actions (developer screen)

    func startScan() {
        guard state == .poweredOn else {
            append(.error, "Cannot scan: Bluetooth is \(Self.describe(state))")
            return
        }
        discovered.removeAll()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        append(.info, "Scanning for LE advertisements")
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    func refreshSystemConnected() {
        guard state == .poweredOn else { return }
        systemConnected = central.retrieveConnectedPeripherals(withServices: connectedQueryUUIDs)
        append(.info, "System reports \(systemConnected.count) connected peripheral(s): \(systemConnected.map(Self.displayName).joined(separator: ", "))")
    }

    func connect(_ peripheral: CBPeripheral) {
        searchTimeoutTask?.cancel()
        if isScanning { stopScan() }
        if let current = connectedPeripheral, current != peripheral {
            central.cancelPeripheralConnection(current)
        }
        resetPeripheralState()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        var options: [String: Any] = [:]
        if useTransportBridging {
            options[CBConnectPeripheralOptionEnableTransportBridgingKey] = true
        }
        phase = .connecting
        append(.info, "Connecting to \(Self.displayName(peripheral)) (\(peripheral.identifier.uuidString)) bridging=\(useTransportBridging)")
        central.connect(peripheral, options: options)
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard !Task.isCancelled, let self, self.phase == .connecting, self.connectedPeripheral == peripheral else { return }
            self.append(.error, "Connect to \(Self.displayName(peripheral)) timed out")
            self.central.cancelPeripheralConnection(peripheral)
            self.connectedPeripheral = nil
            self.resetPeripheralState()
            if self.wantsAutoConnect {
                self.triedIdentifiers.insert(peripheral.identifier)
                self.tryNextCandidate()
            } else {
                self.phase = .failed("Connection timed out")
            }
        }
    }

    func disconnect() {
        wantsAutoConnect = false
        continueAfterDisconnect = false
        guard let peripheral = connectedPeripheral else { return }
        append(.info, "Disconnecting from \(Self.displayName(peripheral))")
        central.cancelPeripheralConnection(peripheral)
    }

    func select(writeCharacteristic characteristic: CBCharacteristic) {
        selectedWriteCharacteristic = characteristic
        append(.info, "Write target: \(characteristic.uuid) in service \(characteristic.service?.uuid.uuidString ?? "?")")
    }

    func toggleNotify(_ characteristic: CBCharacteristic) {
        guard let peripheral = connectedPeripheral else { return }
        peripheral.setNotifyValue(!characteristic.isNotifying, for: characteristic)
    }

    func read(_ characteristic: CBCharacteristic) {
        guard let peripheral = connectedPeripheral else { return }
        peripheral.readValue(for: characteristic)
    }

    var canSend: Bool {
        connectedPeripheral?.state == .connected && selectedWriteCharacteristic != nil
    }

    // MARK: - Sending

    /// Sends a known command and tracks whether the earbuds acknowledge it.
    func send(command: SoundcorePacket.Command) {
        guard canSend else {
            append(.error, "Cannot send \(command.title): not ready")
            return
        }
        ackTask?.cancel()
        pendingCommand = command
        lastCommandResult = CommandResult(command: command, status: .sent, date: Date())
        send(command.data)
        ackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.ackTimeout)
            guard !Task.isCancelled, let self, self.pendingCommand == command else { return }
            self.pendingCommand = nil
            self.lastCommandResult = CommandResult(command: command, status: .noResponse, date: Date())
            self.append(.error, "No acknowledgement for \(command.title) within \(Self.ackTimeout)")
        }
    }

    /// Sets the once-asleep behaviour. The official app writes only the byte that
    /// changed; we write both so the result does not depend on prior state.
    func setAutoSwitch(_ option: SoundcorePacket.AutoSwitchOption) {
        guard canSend else {
            append(.error, "Cannot set auto-switch: not ready")
            return
        }
        followUpTask?.cancel()
        send(command: .sleepSettingsFlag(option.flag))
        followUpTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.canSend else { return }
            self.send(command: .autoSwitch(option.enabled ? 1 : 0))
        }
    }

    // MARK: - Async API (App Intents)

    /// Connects if needed and returns once commands can be sent, or throws with a reason.
    func ensureReady(timeout: Duration = .seconds(15)) async throws {
        if phase == .ready, canSend { return }
        autoConnect()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            switch phase {
            case .ready where canSend: return
            case .bluetoothOff: throw A30Error.bluetoothOff
            case .unauthorized: throw A30Error.unauthorized
            case .notFound: throw A30Error.notFound
            case .failed(let message): throw A30Error.connectionFailed(message)
            default: continue
            }
        }
        throw A30Error.timedOut
    }

    /// Sends a command and waits for the earbuds' acknowledgement.
    @discardableResult
    func perform(_ command: SoundcorePacket.Command) async throws -> CommandResult {
        try await ensureReady()
        send(command: command)
        let deadline = ContinuousClock.now + Self.ackTimeout + .milliseconds(500)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if let result = lastCommandResult, result.command == command {
                switch result.status {
                case .acknowledged: return result
                case .noResponse: throw A30Error.noResponse(command.title)
                case .sent: continue
                }
            }
        }
        throw A30Error.noResponse(command.title)
    }

    /// Sets the once-asleep behaviour and waits for both writes to be acknowledged.
    func performAutoSwitch(_ option: SoundcorePacket.AutoSwitchOption) async throws {
        try await perform(.sleepSettingsFlag(option.flag))
        try await perform(.autoSwitch(option.enabled ? 1 : 0))
    }

    /// Refreshes everything the earbuds report: the state dump and the timer countdown.
    func refreshStatus() async throws {
        try await perform(.requestState)
        try await perform(.querySleepTimer)
    }

    /// Writes raw bytes to the selected characteristic.
    func send(_ data: Data) {
        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            append(.error, "Not connected")
            return
        }
        guard let characteristic = selectedWriteCharacteristic else {
            append(.error, "No write characteristic selected")
            return
        }
        let type: CBCharacteristicWriteType
        if characteristic.properties.contains(.writeWithoutResponse) {
            type = .withoutResponse
        } else if characteristic.properties.contains(.write) {
            type = .withResponse
        } else {
            append(.error, "Characteristic \(characteristic.uuid) is not writable")
            return
        }
        let limit = peripheral.maximumWriteValueLength(for: type)
        if data.count > limit {
            append(.error, "Packet is \(data.count) bytes but the write limit is \(limit)")
            return
        }
        let description = SoundcorePacket.describe(data)
        append(.tx, "\(data.hexString)\(description.isEmpty ? "" : "  [\(description)]") via \(characteristic.uuid) (\(type == .withoutResponse ? "no response" : "with response"))")
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    func clearLog() {
        log.removeAll()
    }

    /// The whole log as plain text, one entry per line.
    func exportLog() -> String {
        log.map { entry in
            let time = entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
            let kind: String
            switch entry.kind {
            case .info: kind = "INFO"
            case .tx: kind = "TX"
            case .rx: kind = "RX"
            case .error: kind = "ERR"
            }
            return "\(time) \(kind) \(entry.message)"
        }.joined(separator: "\n")
    }

    /// Environment and connection facts worth including with a bug report.
    func diagnosticsSummary() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "App: Headphone Control \(version) (\(build))",
            "iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Device: \(Self.deviceModelIdentifier)",
            "Bluetooth: \(Self.describe(state))",
            "Phase: \(phase.label)",
        ]
        if let name = connectedDeviceName { lines.append("Earbuds: \(name)") }
        if let firmware = deviceState.firmwareLeft { lines.append("Firmware: \(firmware) / \(deviceState.firmwareRight ?? "?")") }
        if let probeConfirmed { lines.append("Probe answered: \(probeConfirmed)") }
        if let target = selectedWriteCharacteristic { lines.append("Write target: \(target.uuid.uuidString)") }
        if !learnedServiceUUIDs.isEmpty { lines.append("Learned services: \(learnedServiceUUIDs.map(\.uuidString).joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    nonisolated static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }

    // MARK: - Helpers

    nonisolated static func displayName(_ peripheral: CBPeripheral) -> String {
        peripheral.name ?? "Unnamed"
    }

    static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "powered on"
        case .poweredOff: return "powered off"
        case .resetting: return "resetting"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    static func describe(_ properties: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.writeWithoutResponse) { parts.append("write-no-rsp") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        if properties.contains(.broadcast) { parts.append("broadcast") }
        if properties.contains(.authenticatedSignedWrites) { parts.append("signed-write") }
        if properties.contains(.extendedProperties) { parts.append("ext") }
        return parts.joined(separator: ", ")
    }

    private func append(_ kind: LogEntry.Kind, _ message: String) {
        log.append(LogEntry(kind: kind, message: message))
        if log.count > 500 {
            log.removeFirst(log.count - 500)
        }
    }

    private func resetPeripheralState() {
        probeTask?.cancel()
        ackTask?.cancel()
        followUpTask?.cancel()
        services = []
        characteristics = []
        writeCandidates = []
        selectedWriteCharacteristic = nil
        probeConfirmed = nil
        deviceState = A30State()
        lastCommandResult = nil
        pendingCommand = nil
        pendingSnapshotLabel = nil
        pendingServiceDiscovery = 0
        inboundFrameCount = 0
    }

    private static func isStandardService(_ uuid: CBUUID) -> Bool {
        guard uuid.data.count == 2 else { return false }
        let value = uuid.data.withUnsafeBytes { UInt16(bigEndian: $0.load(as: UInt16.self)) }
        return value < 0xFF00
    }

    /// Ranks writable characteristics by how much they resemble the Soundcore
    /// control channel: write-without-response, inside a vendor service that
    /// also carries a notify characteristic for responses.
    private func rankWriteCandidates() {
        let ranked = characteristics.compactMap { characteristic -> WriteCandidate? in
            var score = 0
            if characteristic.properties.contains(.writeWithoutResponse) { score += 3 }
            if characteristic.properties.contains(.write) { score += 1 }
            guard score > 0 else { return nil }
            if let service = characteristic.service {
                if !Self.isStandardService(service.uuid) { score += 2 }
                let siblings = service.characteristics ?? []
                if siblings.contains(where: { $0 != characteristic && ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) }) {
                    score += 2
                }
            }
            return WriteCandidate(characteristic: characteristic, score: score)
        }
        writeCandidates = ranked.sorted { $0.score > $1.score }
        append(.info, "Write candidates: \(writeCandidates.map { "\($0.characteristic.uuid) (\($0.score))" }.joined(separator: ", "))")
    }

    private func runProbe() async {
        guard !writeCandidates.isEmpty else {
            probeConfirmed = false
            phase = .failed("No writable characteristic found")
            append(.error, "Probe: nothing to probe")
            return
        }
        phase = .probing
        probeConfirmed = nil
        logSubscriptionState()
        for candidate in writeCandidates {
            guard !Task.isCancelled, connectedPeripheral?.state == .connected else { return }
            selectedWriteCharacteristic = candidate.characteristic
            let before = inboundFrameCount
            append(.info, "Probe: trying \(candidate.characteristic.uuid)")
            send(SoundcorePacket.requestState)
            let deadline = ContinuousClock.now + Self.probeTimeout
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                if inboundFrameCount > before {
                    probeConfirmed = true
                    phase = .ready
                    remember(knownGood: connectedPeripheral?.identifier)
                    append(.info, "Probe: earbuds answered on \(candidate.characteristic.uuid)")
                    try? await Task.sleep(for: .milliseconds(200))
                    if !Task.isCancelled, canSend { send(SoundcorePacket.Command.querySleepTimer.data) }
                    return
                }
            }
        }
        probeConfirmed = false
        if wantsAutoConnect, let current = connectedPeripheral {
            // This identity accepts writes but never answers. If iOS knows another
            // A30 identity (typically the Classic one), move on to it.
            triedIdentifiers.insert(current.identifier)
            refreshSystemConnected()
            if nextCandidate() != nil {
                dropCurrentAndContinue(reason: "no answer to probe")
                return
            }
        }
        selectedWriteCharacteristic = writeCandidates.first?.characteristic
        phase = .ready
        append(.error, "Probe: no candidate answered; defaulting to \(writeCandidates.first!.characteristic.uuid)")
    }

    private func scheduleReconnect() {
        guard wantsAutoConnect, !reconnectAttempted else { return }
        reconnectAttempted = true
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.append(.info, "Auto-connect: retrying after disconnect")
            self.autoConnect()
        }
    }

    // MARK: - Delegate handlers (run on the main actor)

    private func handleStateUpdate() {
        state = central.state
        append(.info, "Bluetooth \(Self.describe(state))")
        if state == .poweredOn {
            refreshSystemConnected()
            if wantsAutoConnect { autoConnect() }
        } else {
            isScanning = false
            if wantsAutoConnect {
                phase = state == .unauthorized ? .unauthorized : .bluetoothOff
            }
        }
    }

    private func handleDiscovery(_ peripheral: CBPeripheral, advertisement: [String: Any], rssi: NSNumber) {
        let advertisedName = advertisement[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "Unnamed"
        let servicesAdvertised = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let manufacturerData = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data
        if let index = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            discovered[index].rssi = rssi.intValue
            discovered[index].lastSeen = Date()
            if name != "Unnamed" { discovered[index].name = name }
            if !servicesAdvertised.isEmpty { discovered[index].advertisedServices = servicesAdvertised }
            if manufacturerData != nil { discovered[index].manufacturerData = manufacturerData }
        } else {
            discovered.append(DiscoveredPeripheral(
                peripheral: peripheral,
                name: name,
                rssi: rssi.intValue,
                advertisedServices: servicesAdvertised,
                manufacturerData: manufacturerData,
                lastSeen: Date()
            ))
            if name.localizedCaseInsensitiveContains("soundcore") || name.localizedCaseInsensitiveContains("a30") {
                append(.info, "Found \(name) rssi=\(rssi) services=\(servicesAdvertised.map(\.uuidString).joined(separator: ","))")
            }
        }
        if phase == .searching, Self.looksLikeA30(name), !triedIdentifiers.contains(peripheral.identifier) {
            append(.info, "Auto-connect: found \(name) by advertisement")
            connect(peripheral)
        }
    }

    private func handleConnected(_ peripheral: CBPeripheral) {
        connectTimeoutTask?.cancel()
        phase = .discovering
        reconnectAttempted = false
        append(.info, "Connected to \(Self.displayName(peripheral)); MTU no-rsp=\(peripheral.maximumWriteValueLength(for: .withoutResponse)) rsp=\(peripheral.maximumWriteValueLength(for: .withResponse))")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    private func handleConnectFailure(_ peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "unknown error"
        append(.error, "Failed to connect to \(Self.displayName(peripheral)): \(message)")
        guard connectedPeripheral == peripheral else { return }
        connectTimeoutTask?.cancel()
        connectedPeripheral = nil
        resetPeripheralState()
        if wantsAutoConnect {
            triedIdentifiers.insert(peripheral.identifier)
            tryNextCandidate()
        } else {
            phase = .failed(message)
        }
    }

    private func handleDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        append(error == nil ? .info : .error, "Disconnected from \(Self.displayName(peripheral))\(error.map { ": \($0.localizedDescription)" } ?? "")")
        guard connectedPeripheral == peripheral else { return }
        connectTimeoutTask?.cancel()
        connectedPeripheral = nil
        resetPeripheralState()
        if continueAfterDisconnect {
            continueAfterDisconnect = false
            tryNextCandidate()
        } else {
            phase = .idle
            scheduleReconnect()
        }
    }

    private func handleServices(_ peripheral: CBPeripheral, error: Error?) {
        if let error {
            phase = .failed("Service discovery failed")
            append(.error, "Service discovery failed: \(error.localizedDescription)")
            return
        }
        services = peripheral.services ?? []
        append(.info, "Discovered \(services.count) service(s): \(services.map(\.uuid.uuidString).joined(separator: ", "))")
        pendingServiceDiscovery = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if services.isEmpty {
            phase = .failed("No GATT services found")
        }
    }

    private func handleCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        if let error {
            append(.error, "Characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
        }
        let found = service.characteristics ?? []
        characteristics = services.flatMap { $0.characteristics ?? [] }
        let vendorService = !Self.isStandardService(service.uuid)
        for characteristic in found {
            append(.info, "  \(service.uuid) / \(characteristic.uuid): \(Self.describe(characteristic.properties))")
            // Subscribe to anything that can notify. In vendor services also try
            // characteristics whose declared properties do not admit it: some
            // firmware under-declares, and CoreBluetooth simply reports an error.
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) || vendorService {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if vendorService {
                peripheral.discoverDescriptors(for: characteristic)
            }
        }
        pendingServiceDiscovery -= 1
        if pendingServiceDiscovery <= 0 {
            if Self.looksLikeA30(peripheral.name) {
                learnServices(services.map(\.uuid))
            } else if wantsAutoConnect, !gattMatchesLearned(services) {
                dropCurrentAndContinue(reason: "GATT table does not match a Sleep A30")
                return
            }
            rankWriteCandidates()
            probeTask?.cancel()
            probeTask = Task { [weak self] in
                // Give the notification subscriptions a moment to settle before probing.
                try? await Task.sleep(for: .milliseconds(300))
                await self?.runProbe()
            }
        }
    }

    private func handleValue(_ characteristic: CBCharacteristic, error: Error?) {
        if let error {
            append(.error, "Read/notify error on \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        let data = characteristic.value ?? Data()
        let parsed = SoundcorePacket.parse(data)
        append(.rx, "\(data.hexString)\(parsed.map { "  [\($0.summary)]" } ?? "") from \(characteristic.uuid)")
        guard let parsed, parsed.direction == .inbound else { return }
        inboundFrameCount += 1
        applyState(from: parsed)
        if let pending = pendingCommand, pending.commandID == parsed.command {
            ackTask?.cancel()
            pendingCommand = nil
            lastCommandResult = CommandResult(command: pending, status: .acknowledged, date: Date())
            switch pending {
            case .autoSwitch(let value):
                deviceState.autoSwitchEnabled = value != 0
            case .sleepSettingsFlag(let flag):
                deviceState.sleepSettingsFlag = flag
            default:
                break
            }
        }
    }

    private func applyState(from parsed: SoundcorePacket.Parsed) {
        switch parsed.command {
        case SoundcorePacket.CommandID.audioSourceState, SoundcorePacket.CommandID.setAudioSource:
            if let value = parsed.body.first, let source = SoundcorePacket.AudioSource(rawValue: value) {
                deviceState.audioSource = source
                deviceState.updatedAt = Date()
            }
        case SoundcorePacket.CommandID.noiseCancellingState, SoundcorePacket.CommandID.setNoiseCancelling:
            if let value = parsed.body.first {
                deviceState.noiseCancelling = value != 0
                deviceState.updatedAt = Date()
            }
        case SoundcorePacket.CommandID.sleepTimerStatus:
            if let status = SoundcorePacket.SleepTimerStatus(body: parsed.body) {
                deviceState.sleepTimer = status
                deviceState.sleepSettingsFlag = status.flag
                deviceState.sleepTimerReceivedAt = Date()
                deviceState.updatedAt = Date()
            }
        case SoundcorePacket.CommandID.requestState:
            lastStateDump = Data(parsed.body)
            if let dump = SoundcorePacket.StateDump(body: parsed.body) {
                deviceState.audioSource = dump.audioSource
                deviceState.noiseCancelling = dump.noiseCancelling
                deviceState.sleepSettingsFlag = dump.sleepSettingsFlag
                deviceState.firmwareLeft = dump.firmwareLeft
                deviceState.firmwareRight = dump.firmwareRight
                deviceState.serialNumber = dump.serialNumber
                deviceState.batteryLevelLeft = dump.batteryLevelLeft
                deviceState.batteryLevelRight = dump.batteryLevelRight
                deviceState.caseBatteryPercent = dump.caseBatteryPercent
                deviceState.bothEarbudsConnected = dump.bothEarbudsConnected
                deviceState.bluetoothAudioPlaying = dump.bluetoothAudioPlaying
                deviceState.localAudioActive = dump.localAudioActive
                if deviceState.sleepTimer == nil {
                    // The dump has no remaining-time field; a 15 03 query follows the probe for that.
                    deviceState.sleepTimer = SoundcorePacket.SleepTimerStatus(body: [
                        dump.sleepTimerEnabled ? 1 : 0, UInt8(dump.sleepTimerMinutes & 0xFF), UInt8(dump.sleepTimerMinutes >> 8),
                        dump.sleepSettingsFlag, 0, 0, 0, 0,
                    ])
                }
                deviceState.updatedAt = Date()
                append(.info, "State dump: fw \(dump.firmwareLeft)/\(dump.firmwareRight), serial \(dump.serialNumber), source \(dump.audioSource?.title ?? "?"), ANC \(dump.noiseCancelling ? "on" : "off"), timer \(dump.sleepTimerEnabled ? "on" : "off") \(dump.sleepTimerMinutes) min, flag \(dump.sleepSettingsFlag), battery L \(dump.batteryLevelLeft.map(String.init) ?? "case") R \(dump.batteryLevelRight.map(String.init) ?? "case") case \(dump.caseBatteryPercent)%, bt playing \(dump.bluetoothAudioPlaying), local \(dump.localAudioActive), b144 \(dump.unknown144) b148 \(dump.unknown148)")
            }
            if let label = pendingSnapshotLabel {
                pendingSnapshotLabel = nil
                snapshots.append(StateSnapshot(label: label, body: Data(parsed.body)))
                persistSnapshots()
                append(.info, "Snapshot \"\(label)\" captured (\(parsed.body.count) bytes)")
            }
        default:
            break
        }
    }

    private func handleDescriptors(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        if let error {
            append(.error, "Descriptor discovery failed for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        let descriptors = characteristic.descriptors ?? []
        append(.info, "  \(characteristic.uuid) descriptors: \(descriptors.map(\.uuid.uuidString).joined(separator: ", "))")
        let hasCCCD = descriptors.contains { $0.uuid == CBUUID(string: CBUUIDClientCharacteristicConfigurationString) }
        if hasCCCD, !characteristic.isNotifying {
            append(.info, "  \(characteristic.uuid) has a CCCD; subscribing")
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    /// Developer action: ask for notifications on every characteristic and log what CoreBluetooth says.
    func subscribeToEverything() {
        guard let peripheral = connectedPeripheral, peripheral.state == .connected else { return }
        append(.info, "Subscribing to all \(characteristics.count) characteristic(s)")
        for characteristic in characteristics {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    /// Developer action: dump the subscription state of every characteristic.
    func logSubscriptionState() {
        for characteristic in characteristics {
            append(.info, "  \(characteristic.service?.uuid.uuidString ?? "?") / \(characteristic.uuid): notifying=\(characteristic.isNotifying) props=[\(Self.describe(characteristic.properties))]")
        }
    }

    private func handleWriteResult(_ characteristic: CBCharacteristic, error: Error?) {
        if let error {
            append(.error, "Write to \(characteristic.uuid) failed: \(error.localizedDescription)")
        } else {
            append(.info, "Write to \(characteristic.uuid) acknowledged by GATT")
        }
    }

    private func handleNotifyState(_ characteristic: CBCharacteristic, error: Error?) {
        if let error {
            append(.error, "Notify on \(characteristic.uuid) refused: \(error.localizedDescription) [props: \(Self.describe(characteristic.properties))]")
            return
        }
        append(.info, "Notifications \(characteristic.isNotifying ? "on" : "off") for \(characteristic.uuid)")
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { handleStateUpdate() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { handleDiscovery(peripheral, advertisement: advertisementData, rssi: RSSI) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { handleConnected(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { handleConnectFailure(peripheral, error: error) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { handleDisconnect(peripheral, error: error) }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { handleServices(peripheral, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { handleCharacteristics(peripheral, service: service, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { handleValue(characteristic, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { handleWriteResult(characteristic, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { handleNotifyState(characteristic, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { handleDescriptors(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        MainActor.assumeIsolated {
            append(.info, "Descriptor \(descriptor.uuid) on \(descriptor.characteristic?.uuid.uuidString ?? "?") = \(String(describing: descriptor.value))")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            append(.info, "Peripheral modified services; rediscovering")
            resetPeripheralState()
            phase = .discovering
            peripheral.discoverServices(nil)
        }
    }
}
