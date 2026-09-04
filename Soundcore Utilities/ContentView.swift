//
//  ContentView.swift
//  Soundcore Utilities
//
//  The user-facing screen. It assumes a single Sleep A30, connects to it on
//  its own, and offers plain buttons for the commands we understand. The
//  diagnostic screens live behind developer mode (see SettingsView).
//

import SwiftUI

struct ContentView: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(DeveloperMode.key) private var developerMode = false
    @State private var showSettings = false
    @State private var showDeveloper = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    StatusCard()
                    if bluetooth.phase == .ready {
                        ControlsView()
                    }
                }
                .padding()
            }
            .navigationTitle("Headphone Control")
            .toolbar {
                if developerMode {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showDeveloper = true
                        } label: {
                            Label("Developer", systemImage: "hammer")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(openDeveloperTools: {
                    showSettings = false
                    showDeveloper = true
                })
            }
            .fullScreenCover(isPresented: $showDeveloper) {
                DeveloperView()
            }
            .sensoryFeedback(trigger: bluetooth.lastCommandResult) { _, new in
                switch new?.status {
                case .acknowledged: return .success
                case .noResponse: return .warning
                default: return nil
                }
            }
            .task {
                bluetooth.autoConnect()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active, bluetooth.phase != .ready {
                    bluetooth.autoConnect()
                }
            }
        }
    }
}

// MARK: - Status

struct StatusCard: View {
    @Environment(BluetoothManager.self) private var bluetooth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                icon
                    .font(.title)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if showsRetry {
                Button("Try again") { bluetooth.autoConnect() }
                    .buttonStyle(.bordered)
            }
            if bluetooth.phase == .unauthorized, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var icon: some View {
        switch bluetooth.phase {
        case .searching, .connecting, .discovering, .probing:
            ProgressView()
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .bluetoothOff, .unauthorized, .notFound, .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            Image(systemName: "earbuds").foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch bluetooth.phase {
        case .idle: return "Not connected"
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth access needed"
        case .searching: return "Looking for your Sleep A30…"
        case .connecting: return "Connecting…"
        case .discovering, .probing: return "Getting ready…"
        case .ready: return "Connected"
        case .notFound: return "Sleep A30 not found"
        case .failed: return "Connection failed"
        }
    }

    private var detail: String? {
        switch bluetooth.phase {
        case .ready:
            var parts: [String] = []
            if let name = bluetooth.connectedDeviceName { parts.append(name) }
            if bluetooth.probeConfirmed == false {
                parts.append("The earbuds did not answer a test message, so commands may not take effect.")
            }
            return parts.isEmpty ? nil : parts.joined(separator: ". ")
        case .notFound:
            return "Take the earbuds out of the case and check they are connected in Settings › Bluetooth, then try again."
        case .idle:
            return "Pair your Sleep A30 in Settings › Bluetooth. The app finds it automatically."
        case .bluetoothOff:
            return "Turn on Bluetooth in Control Center or Settings."
        case .unauthorized:
            return "Allow Bluetooth for this app in Settings."
        case .failed(let message):
            return message
        case .connecting, .discovering, .probing:
            return bluetooth.connectedDeviceName
        default:
            return nil
        }
    }

    private var showsRetry: Bool {
        switch bluetooth.phase {
        case .idle, .notFound, .failed, .bluetoothOff: return true
        default: return false
        }
    }
}

// MARK: - Controls

struct ControlsView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    var body: some View {
        VStack(spacing: 16) {
            ControlGroup(title: "Audio source", subtitle: "Local plays sounds stored on the earbuds; Bluetooth streams from this iPhone.") {
                ChoiceButton(
                    title: "Bluetooth",
                    systemImage: "iphone.radiowaves.left.and.right",
                    isCurrent: bluetooth.deviceState.audioSource == .bluetooth
                ) {
                    bluetooth.send(command: .audioSource(.bluetooth))
                }
                ChoiceButton(
                    title: "Local",
                    systemImage: "earbuds",
                    isCurrent: bluetooth.deviceState.audioSource == .local
                ) {
                    bluetooth.send(command: .audioSource(.local))
                }
            }

            ControlGroup(title: "Noise cancelling", subtitle: nil) {
                ChoiceButton(
                    title: "On",
                    systemImage: "ear.and.waveform",
                    isCurrent: bluetooth.deviceState.noiseCancelling == true
                ) {
                    bluetooth.send(command: .noiseCancelling(true))
                }
                ChoiceButton(
                    title: "Off",
                    systemImage: "ear",
                    isCurrent: bluetooth.deviceState.noiseCancelling == false
                ) {
                    bluetooth.send(command: .noiseCancelling(false))
                }
            }

            SleepTimerGroup()

            ControlGroup(title: "Once asleep", subtitle: bluetooth.deviceState.autoSwitch == nil
                         ? "What the earbuds do when they detect you have fallen asleep. The current choice cannot be read back yet, so nothing is highlighted until you pick one."
                         : "What the earbuds do when they detect you have fallen asleep.") {
                ForEach(SoundcorePacket.AutoSwitchOption.allCases) { option in
                    ChoiceButton(
                        title: option.title,
                        systemImage: option == .keepAudio ? "play.circle" : option == .pauseAudio ? "pause.circle" : "moon.zzz",
                        isCurrent: bluetooth.deviceState.autoSwitch == option
                    ) {
                        bluetooth.setAutoSwitch(option)
                    }
                }
            }

            if let result = bluetooth.lastCommandResult {
                ResultBanner(result: result)
            }
        }
    }
}

struct SleepTimerGroup: View {
    @Environment(BluetoothManager.self) private var bluetooth

    private var timer: SoundcorePacket.SleepTimerStatus? { bluetooth.deviceState.sleepTimer }

    /// The official app echoes the current flag byte in every timer write; do the same.
    private var flag: UInt8 { timer?.flag ?? 0 }

    private func statusText(at now: Date) -> String {
        guard let timer else { return "Sounds stop automatically after the chosen time." }
        if timer.enabled {
            let elapsed = bluetooth.deviceState.sleepTimerReceivedAt.map { now.timeIntervalSince($0) } ?? 0
            let left = max(0, Int(timer.remainingSeconds) - Int(elapsed))
            let formatted = Duration.seconds(left).formatted(.time(pattern: .minuteSecond))
            return "On, \(timer.minutes) min. \(formatted) left."
        }
        return "Off. Last used \(timer.minutes) min."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sleep timer").font(.headline)
                Spacer()
                Button("Refresh") { bluetooth.send(command: .querySleepTimer) }
                    .font(.footnote)
            }
            HStack(spacing: 8) {
                ForEach(SoundcorePacket.sleepTimerPresets, id: \.self) { minutes in
                    let isCurrent = timer?.enabled == true && timer?.minutes == minutes
                    Button {
                        bluetooth.send(command: .sleepTimer(enabled: true, minutes: minutes, flag: flag))
                    } label: {
                        Text("\(minutes)")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isCurrent ? .accentColor : .gray.opacity(0.5))
                    .accessibilityLabel("\(minutes) minutes\(isCurrent ? ", current" : "")")
                }
                Button {
                    bluetooth.send(command: .sleepTimer(enabled: false, minutes: timer?.minutes ?? 30, flag: flag))
                } label: {
                    Text("Off")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(timer?.enabled == false ? .accentColor : .gray.opacity(0.5))
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(statusText(at: context.date))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ControlGroup<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            HStack(spacing: 12) { content }
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ChoiceButton: View {
    let title: String
    let systemImage: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title2)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(isCurrent ? .accentColor : .gray.opacity(0.5))
        .accessibilityLabel(isCurrent ? "\(title), current" : title)
    }
}

struct ResultBanner: View {
    let result: CommandResult

    var body: some View {
        HStack(spacing: 8) {
            switch result.status {
            case .sent:
                ProgressView()
                Text("Sending \(result.command.title)…")
            case .acknowledged:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Earbuds confirmed: \(result.command.title)")
            case .noResponse:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("Sent \(result.command.title), but the earbuds did not confirm")
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .animation(.default, value: result)
    }
}

// MARK: - Settings and developer-mode unlock

enum DeveloperMode {
    static let key = "developerModeEnabled"
    static let tapsToUnlock = 7
}

struct SettingsView: View {
    let openDeveloperTools: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(BluetoothManager.self) private var bluetooth
    @AppStorage(DeveloperMode.key) private var developerMode = false
    @State private var versionTaps = 0
    @State private var justUnlocked = false
    @State private var showMailComposer = false
    @State private var showForgetConfirmation = false
    @State private var showMailUnavailable = false

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        if Feedback.canComposeInApp {
                            showMailComposer = true
                        } else if let url = Feedback.mailtoURL(body: Feedback.body(diagnostics: bluetooth.diagnosticsSummary())) {
                            showMailUnavailable = true
                            openURL(url)
                        }
                    } label: {
                        Label("Send feedback", systemImage: "envelope")
                    }
                    Button(role: .destructive) {
                        showForgetConfirmation = true
                    } label: {
                        Label("Forget earbuds", systemImage: "xmark.circle")
                    }
                } header: {
                    Text("Support")
                } footer: {
                    Text("Feedback opens an email to \(Feedback.address) with the diagnostic log attached. Forget earbuds clears what the app has learned about your Sleep A30 so it searches from scratch next time.")
                }

                Section("About") {
                    LabeledContent("Version", value: versionString)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: handleVersionTap)
                    if justUnlocked {
                        Label("Developer mode enabled", systemImage: "hammer.fill")
                            .foregroundStyle(.tint)
                    } else if !developerMode, versionTaps >= 3 {
                        Text("\(DeveloperMode.tapsToUnlock - versionTaps) more taps to enable developer mode")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Headphone Control is an independent project. Soundcore and Sleep A30 are trademarks of Anker Innovations; this app is not affiliated with, endorsed by, or supported by Anker.")
                    Text("The app stores nothing outside your device and collects no data. Bluetooth is used only to talk to your earbuds. A feedback email is composed in your mail app and sent only if you choose to send it.")
                } header: {
                    Text("Legal and privacy")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if developerMode {
                    Section {
                        Toggle("Developer mode", isOn: $developerMode)
                        Button("Open developer tools") { openDeveloperTools() }
                    } footer: {
                        Text("Shows the raw Bluetooth diagnostics: GATT table, packet log, and state snapshots.")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showMailComposer) {
                FeedbackMailView(
                    diagnostics: bluetooth.diagnosticsSummary(),
                    log: bluetooth.exportLog(),
                    snapshots: bluetooth.snapshots.isEmpty ? nil : bluetooth.exportSnapshots()
                )
                .ignoresSafeArea()
            }
            .confirmationDialog("Forget the learned earbuds?", isPresented: $showForgetConfirmation, titleVisibility: .visible) {
                Button("Forget earbuds", role: .destructive) {
                    bluetooth.disconnect()
                    bluetooth.forgetLearnedDevice()
                    bluetooth.autoConnect()
                }
            } message: {
                Text("The app will search for the earbuds again from scratch. Nothing on the earbuds changes.")
            }
            .alert("Mail is not set up", isPresented: $showMailUnavailable) {
                Button("OK") {}
            } message: {
                Text("A draft was handed to your default email app without the log attached. To include the log, enable developer mode and use Share on the Log tab.")
            }
        }
    }

    private func handleVersionTap() {
        guard !developerMode else { return }
        versionTaps += 1
        if versionTaps >= DeveloperMode.tapsToUnlock {
            developerMode = true
            justUnlocked = true
        }
    }
}

#Preview {
    ContentView()
        .environment(BluetoothManager.shared)
}
