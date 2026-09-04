//
//  DeveloperViews.swift
//  Soundcore Utilities
//
//  Diagnostic screens, reachable only with developer mode enabled: the raw
//  CoreBluetooth view (scan, connect, GATT table, arbitrary packets), the
//  packet log, and state-dump snapshots.
//

import CoreBluetooth
import SwiftUI

struct DeveloperView: View {
    var body: some View {
        TabView {
            Tab("Bluetooth", systemImage: "antenna.radiowaves.left.and.right") {
                DeveloperBluetoothView()
            }
            Tab("Log", systemImage: "list.bullet.rectangle") {
                LogView()
            }
            Tab("Snapshots", systemImage: "camera.viewfinder") {
                SnapshotsView()
            }
        }
    }
}

private struct DoneButton: ToolbarContent {
    @Environment(\.dismiss) private var dismiss

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") { dismiss() }
        }
    }
}

// MARK: - Bluetooth tab

struct DeveloperBluetoothView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    var body: some View {
        @Bindable var bluetooth = bluetooth
        NavigationStack {
            List {
                Section("Adapter") {
                    LabeledContent("State", value: BluetoothManager.describe(bluetooth.state))
                    LabeledContent("Phase", value: bluetooth.phase.label)
                    Toggle("Transport bridging (use Classic link)", isOn: $bluetooth.useTransportBridging)
                    Toggle("Hide unnamed peripherals", isOn: $bluetooth.showOnlyNamed)
                    HStack {
                        Button(bluetooth.isScanning ? "Stop scan" : "Scan") {
                            bluetooth.isScanning ? bluetooth.stopScan() : bluetooth.startScan()
                        }
                        Spacer()
                        Button("Refresh connected") { bluetooth.refreshSystemConnected() }
                        Spacer()
                        Button("Auto-connect") { bluetooth.autoConnect() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(bluetooth.state != .poweredOn)
                }

                Section {
                    LabeledContent("Known-good identity", value: bluetooth.knownGoodIdentifier?.uuidString ?? "none")
                        .font(.caption.monospaced())
                    Text(bluetooth.learnedServiceUUIDs.isEmpty
                         ? "No services learned yet"
                         : "Services: " + bluetooth.learnedServiceUUIDs.map(\.uuidString).joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if !bluetooth.triedIdentifiers.isEmpty {
                        Text("Tried this attempt: \(bluetooth.triedIdentifiers.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Forget learned device", role: .destructive) { bluetooth.forgetLearnedDevice() }
                } header: {
                    Text("Learned")
                } footer: {
                    Text("The A30 appears as two peripherals. Only the Classic-linked identity answers commands, so the app remembers whichever one passed the probe and the service UUIDs needed to find it again.")
                }

                if let peripheral = bluetooth.connectedPeripheral {
                    Section("Connection") {
                        LabeledContent("Peripheral", value: BluetoothManager.displayName(peripheral))
                        Text(peripheral.identifier.uuidString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let target = bluetooth.selectedWriteCharacteristic {
                            LabeledContent("Write target", value: target.uuid.uuidString)
                        }
                        LabeledContent("Probe", value: probeLabel)
                        LabeledContent("Firmware", value: [bluetooth.deviceState.firmwareLeft, bluetooth.deviceState.firmwareRight].compactMap { $0 }.joined(separator: " / ").nilIfEmpty ?? "unknown")
                        LabeledContent("Serial", value: bluetooth.deviceState.serialNumber ?? "unknown")
                        LabeledContent("Audio source", value: bluetooth.deviceState.audioSource?.title ?? "unknown")
                        LabeledContent("Sleep timer", value: bluetooth.deviceState.sleepTimer?.summary ?? "unknown")
                        LabeledContent("Battery raw L / R / case", value: "\(bluetooth.deviceState.batteryLevelLeft.map(String.init) ?? "case") / \(bluetooth.deviceState.batteryLevelRight.map(String.init) ?? "case") / \(bluetooth.deviceState.caseBatteryPercent.map { "\($0)%" } ?? "?")")
                        LabeledContent("Playback", value: "BT \(bluetooth.deviceState.bluetoothAudioPlaying.map { $0 ? "playing" : "paused" } ?? "?"), local \(bluetooth.deviceState.localAudioActive.map { $0 ? "active" : "idle" } ?? "?")")
                        LabeledContent("Once asleep", value: bluetooth.deviceState.autoSwitch?.title ?? "flag \(bluetooth.deviceState.sleepSettingsFlag.map(String.init) ?? "?"), on/off unknown")
                        LabeledContent("Noise cancelling", value: bluetooth.deviceState.noiseCancelling.map { $0 ? "on" : "off" } ?? "unknown")
                        HStack {
                            Button("Probe again") { bluetooth.probeAgain() }
                                .disabled(bluetooth.writeCandidates.isEmpty || bluetooth.phase == .probing)
                            Spacer()
                            Button("Disconnect", role: .destructive) { bluetooth.disconnect() }
                        }
                        .buttonStyle(.bordered)
                        HStack {
                            Button("Subscribe to all") { bluetooth.subscribeToEverything() }
                            Spacer()
                            Button("Log subscriptions") { bluetooth.logSubscriptionState() }
                        }
                        .buttonStyle(.bordered)
                    }

                    if !bluetooth.writeCandidates.isEmpty {
                        Section("Write candidates (ranked)") {
                            ForEach(bluetooth.writeCandidates) { candidate in
                                HStack {
                                    Text(candidate.characteristic.uuid.uuidString)
                                        .font(.caption.monospaced())
                                    Spacer()
                                    Text("score \(candidate.score)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if bluetooth.selectedWriteCharacteristic == candidate.characteristic {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { bluetooth.select(writeCharacteristic: candidate.characteristic) }
                            }
                        }
                    }

                    CommandSection()

                    ForEach(bluetooth.services, id: \.self) { service in
                        Section("Service \(service.uuid.uuidString)\(service.isPrimary ? "" : " (secondary)")") {
                            let characteristics = bluetooth.characteristics.filter { $0.service == service }
                            if characteristics.isEmpty {
                                Text("No characteristics").foregroundStyle(.secondary)
                            }
                            ForEach(characteristics, id: \.self) { characteristic in
                                CharacteristicRow(characteristic: characteristic)
                            }
                        }
                    }
                }

                Section {
                    if bluetooth.systemConnected.isEmpty {
                        Text("None matching the candidate service list. Tap Refresh connected after the A30 is paired and connected.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(bluetooth.systemConnected, id: \.identifier) { peripheral in
                        Button {
                            bluetooth.connect(peripheral)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(BluetoothManager.displayName(peripheral))
                                Text(peripheral.identifier.uuidString)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Connected to system")
                } footer: {
                    Text("Peripherals iOS already has a GATT link to. A dual-mode A30 that is connected for audio may show up here without scanning.")
                }

                Section {
                    let visible = bluetooth.discovered
                        .filter { !bluetooth.showOnlyNamed || $0.name != "Unnamed" }
                        .sorted { $0.rssi > $1.rssi }
                    if visible.isEmpty {
                        Text(bluetooth.isScanning ? "Listening…" : "Tap Scan to look for “soundcore Sleep A30 LE”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visible) { item in
                        Button {
                            bluetooth.connect(item.peripheral)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                    if !item.advertisedServices.isEmpty {
                                        Text(item.advertisedServices.map(\.uuidString).joined(separator: ", "))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    if let manufacturerData = item.manufacturerData {
                                        Text("mfr: \(manufacturerData.hexString)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(item.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Scanned (LE advertisements)")
                }
            }
            .navigationTitle("Bluetooth")
            .toolbar { DoneButton() }
        }
    }

    private var probeLabel: String {
        switch bluetooth.probeConfirmed {
        case nil: return bluetooth.phase == .probing ? "running" : "not run"
        case true?: return "earbuds answered"
        case false?: return "no answer"
        }
    }
}

struct CharacteristicRow: View {
    @Environment(BluetoothManager.self) private var bluetooth
    let characteristic: CBCharacteristic

    private var isSelected: Bool {
        bluetooth.selectedWriteCharacteristic == characteristic
    }

    private var isWritable: Bool {
        characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse)
    }

    private var canNotify: Bool {
        characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(characteristic.uuid.uuidString)
                    .font(.caption.monospaced())
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
                Spacer()
                if canNotify {
                    Image(systemName: characteristic.isNotifying ? "bell.fill" : "bell.slash")
                        .foregroundStyle(characteristic.isNotifying ? .green : .secondary)
                }
            }
            Text(BluetoothManager.describe(characteristic.properties))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let value = characteristic.value, !value.isEmpty {
                Text(value.hexString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isWritable { bluetooth.select(writeCharacteristic: characteristic) }
        }
        .contextMenu {
            if isWritable {
                Button("Use as write target") { bluetooth.select(writeCharacteristic: characteristic) }
            }
            if characteristic.properties.contains(.read) {
                Button("Read value") { bluetooth.read(characteristic) }
            }
            if canNotify {
                Button(characteristic.isNotifying ? "Stop notifications" : "Start notifications") {
                    bluetooth.toggleNotify(characteristic)
                }
            }
        }
    }
}

struct CommandSection: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @State private var commandHex = "01A9"
    @State private var bodyHex = "01"
    @State private var rawHex = ""
    @State private var parseError: String?

    private var framedPacket: Data? {
        guard let command = Data(hexString: commandHex), command.count == 2 else { return nil }
        let body = bodyHex.trimmingCharacters(in: .whitespaces).isEmpty ? Data() : Data(hexString: bodyHex)
        guard let body else { return nil }
        return SoundcorePacket.build(command: [UInt8](command), body: [UInt8](body))
    }

    var body: some View {
        Section {
            ForEach(SoundcorePacket.Command.allCases) { command in
                Button {
                    bluetooth.send(command: command)
                } label: {
                    HStack {
                        Text(command.title)
                        Spacer()
                        Text(command.data.hexString)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!bluetooth.canSend)

            if let result = bluetooth.lastCommandResult {
                ResultBanner(result: result)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Custom framed command").font(.subheadline)
                HStack {
                    TextField("Command (2 bytes)", text: $commandHex)
                    TextField("Body hex", text: $bodyHex)
                }
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                if let packet = framedPacket {
                    Text(packet.hexString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Invalid hex").font(.caption).foregroundStyle(.red)
                }
                Button("Send framed") {
                    if let packet = framedPacket { bluetooth.send(packet) }
                }
                .buttonStyle(.bordered)
                .disabled(!bluetooth.canSend || framedPacket == nil)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Raw bytes (sent exactly as typed)").font(.subheadline)
                TextField("08 EE 00 00 00 01 A9 0B 00 00 AB", text: $rawHex)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                if let parseError {
                    Text(parseError).font(.caption).foregroundStyle(.red)
                }
                Button("Send raw") {
                    if let data = Data(hexString: rawHex) {
                        parseError = nil
                        bluetooth.send(data)
                    } else {
                        parseError = "Could not parse hex"
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!bluetooth.canSend || rawHex.isEmpty)
            }
        } header: {
            Text("Commands")
        } footer: {
            Text(bluetooth.canSend
                 ? "Writes go to the checked characteristic. Tap a different writable characteristic to change it."
                 : "Connect and pick a writable characteristic to enable sending.")
        }
    }
}

// MARK: - Log tab

struct LogView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    var body: some View {
        NavigationStack {
            List(bluetooth.log.reversed()) { entry in
                LogRow(entry: entry)
            }
            .listStyle(.plain)
            .navigationTitle("Log")
            .toolbar {
                DoneButton()
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: bluetooth.exportLog()) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(bluetooth.log.isEmpty)
                    Button("Clear") { bluetooth.clearLog() }
                }
            }
        }
    }
}

struct LogRow: View {
    let entry: LogEntry

    static func label(for kind: LogEntry.Kind) -> (String, Color) {
        switch kind {
        case .info: return ("INFO", .secondary)
        case .tx: return ("TX", .blue)
        case .rx: return ("RX", .green)
        case .error: return ("ERR", .red)
        }
    }

    var body: some View {
        let label = Self.label(for: entry.kind)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label.0)
                    .font(.caption2.bold())
                    .foregroundStyle(label.1)
                Text(entry.date, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Snapshots tab

struct SnapshotsView: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @State private var label = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Label, e.g. \"ANC off\"", text: $label)
                    Button("Capture state") {
                        bluetooth.captureSnapshot(label: label)
                        label = ""
                    }
                    .disabled(!bluetooth.canSend)
                } header: {
                    Text("Capture")
                } footer: {
                    Text("Change one setting in the Soundcore app, then capture with a label describing it. Bytes that differ from the previous snapshot are highlighted.")
                }

                ForEach(snapshotRows) { row in
                    Section {
                        SnapshotHexView(snapshot: row.snapshot, changed: row.changed)
                    } header: {
                        Text("\(row.number). \(row.snapshot.label)")
                    } footer: {
                        if row.hasPrevious {
                            let changed = row.changed.sorted()
                            Text(changed.isEmpty ? "No change from previous" : "Changed offsets: " + changed.map(String.init).joined(separator: ", "))
                        }
                    }
                }
                .onDelete { bluetooth.deleteSnapshots(at: $0) }
            }
            .navigationTitle("Snapshots")
            .toolbar {
                DoneButton()
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: bluetooth.exportSnapshots()) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(bluetooth.snapshots.isEmpty)
                    Button("Clear", role: .destructive) { bluetooth.clearSnapshots() }
                        .disabled(bluetooth.snapshots.isEmpty)
                }
            }
        }
    }
}

private struct SnapshotRow: Identifiable {
    let number: Int
    let snapshot: StateSnapshot
    let hasPrevious: Bool
    let changed: Set<Int>
    var id: UUID { snapshot.id }
}

private extension SnapshotsView {
    /// Built from one read of the array so a clear or delete mid-render cannot index past the end.
    var snapshotRows: [SnapshotRow] {
        let snapshots = bluetooth.snapshots
        var previous: StateSnapshot?
        return snapshots.enumerated().map { index, snapshot in
            defer { previous = snapshot }
            return SnapshotRow(number: index + 1, snapshot: snapshot, hasPrevious: previous != nil, changed: snapshot.changedOffsets(from: previous))
        }
    }
}

struct SnapshotHexView: View {
    let snapshot: StateSnapshot
    let changed: Set<Int>

    var body: some View {
        let bytes = [UInt8](snapshot.body)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(stride(from: 0, to: bytes.count, by: 16)), id: \.self) { row in
                Text(line(for: row, bytes: bytes))
                    .font(.caption2.monospaced())
            }
            Text(snapshot.date, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }

    private func line(for row: Int, bytes: [UInt8]) -> AttributedString {
        var line = AttributedString(String(format: "%03d: ", row))
        line.foregroundColor = .secondary
        for index in row..<min(row + 16, bytes.count) {
            var piece = AttributedString(String(format: "%02X ", bytes[index]))
            if changed.contains(index) {
                piece.foregroundColor = .red
                piece.font = .caption2.monospaced().bold()
            }
            line += piece
        }
        return line
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
