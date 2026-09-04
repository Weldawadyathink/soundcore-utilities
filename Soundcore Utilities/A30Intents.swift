//
//  A30Intents.swift
//  Soundcore Utilities
//
//  App Intents exposing every Sleep A30 command to Shortcuts and Siri. They
//  run inside the app process, launched in the background when needed, and
//  drive the shared BluetoothManager. The bluetooth-central background mode in
//  Info.plist is what lets CoreBluetooth work during that background launch.
//

import AppIntents
import Foundation

// MARK: - Parameter types

enum AudioSourceOption: String, AppEnum {
    case bluetooth
    case local

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Audio Source")
    static let caseDisplayRepresentations: [AudioSourceOption: DisplayRepresentation] = [
        .bluetooth: "Bluetooth",
        .local: "Local",
    ]

    var packetValue: SoundcorePacket.AudioSource {
        self == .local ? .local : .bluetooth
    }

    init(_ source: SoundcorePacket.AudioSource) {
        self = source == .local ? .local : .bluetooth
    }
}

enum OnOffOption: String, AppEnum {
    case on
    case off

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "State")
    static let caseDisplayRepresentations: [OnOffOption: DisplayRepresentation] = [
        .on: "On",
        .off: "Off",
    ]

    var isOn: Bool { self == .on }
}

enum OnceAsleepOption: String, AppEnum {
    case keepAudio
    case pauseAudio
    case localAudioANCOff

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Once Asleep")
    static let caseDisplayRepresentations: [OnceAsleepOption: DisplayRepresentation] = [
        .keepAudio: "Keep Audio",
        .pauseAudio: "Pause Audio",
        .localAudioANCOff: "Play Local Audio, ANC Off",
    ]

    var packetValue: SoundcorePacket.AutoSwitchOption {
        switch self {
        case .keepAudio: return .keepAudio
        case .pauseAudio: return .pauseAudio
        case .localAudioANCOff: return .localAudioANCOff
        }
    }
}

// MARK: - Setting intents

struct SetAudioSourceIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Audio Source"
    static let description = IntentDescription("Switches the Sleep A30 between streaming from this iPhone and playing sounds stored on the earbuds.")

    @Parameter(title: "Source")
    var source: AudioSourceOption

    static var parameterSummary: some ParameterSummary {
        Summary("Set audio source to \(\.$source)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await BluetoothManager.shared.perform(.audioSource(source.packetValue))
        return .result(dialog: "Sleep A30 switched to \(source.packetValue.title) mode.")
    }
}

struct SetNoiseCancellingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Noise Cancelling"
    static let description = IntentDescription("Turns the Sleep A30's noise cancelling on or off.")

    @Parameter(title: "State")
    var state: OnOffOption

    static var parameterSummary: some ParameterSummary {
        Summary("Turn noise cancelling \(\.$state)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await BluetoothManager.shared.perform(.noiseCancelling(state.isOn))
        return .result(dialog: "Noise cancelling \(state.isOn ? "on" : "off").")
    }
}

struct StartSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Sleep Timer"
    static let description = IntentDescription("Starts the Sleep A30's sleep timer so sounds stop after the given number of minutes.")

    @Parameter(title: "Minutes", default: 30, inclusiveRange: (1, 720))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Start sleep timer for \(\.$minutes) minutes")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = BluetoothManager.shared
        try await manager.ensureReady()
        let flag = manager.deviceState.sleepSettingsFlag ?? 0
        try await manager.perform(.sleepTimer(enabled: true, minutes: UInt16(minutes), flag: flag))
        return .result(dialog: "Sleep timer set for \(minutes) minutes.")
    }
}

struct StopSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Sleep Timer"
    static let description = IntentDescription("Turns off the Sleep A30's sleep timer.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = BluetoothManager.shared
        try await manager.ensureReady()
        let flag = manager.deviceState.sleepSettingsFlag ?? 0
        let minutes = manager.deviceState.sleepTimer?.minutes ?? 30
        try await manager.perform(.sleepTimer(enabled: false, minutes: minutes, flag: flag))
        return .result(dialog: "Sleep timer off.")
    }
}

struct SetOnceAsleepIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Once-Asleep Behavior"
    static let description = IntentDescription("Chooses what the Sleep A30 does when it detects you have fallen asleep.")

    @Parameter(title: "Behavior")
    var option: OnceAsleepOption

    static var parameterSummary: some ParameterSummary {
        Summary("Once asleep, \(\.$option)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await BluetoothManager.shared.performAutoSwitch(option.packetValue)
        return .result(dialog: "Once asleep: \(option.packetValue.title).")
    }
}

// MARK: - Reading intents

struct GetAudioSourceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Audio Source"
    static let description = IntentDescription("Returns whether the Sleep A30 is in Bluetooth or Local mode.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<AudioSourceOption> & ProvidesDialog {
        let manager = BluetoothManager.shared
        try await manager.refreshStatus()
        let source = manager.deviceState.audioSource ?? .bluetooth
        return .result(value: AudioSourceOption(source), dialog: "Audio source is \(source.title).")
    }
}

struct GetNoiseCancellingIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Noise Cancelling State"
    static let description = IntentDescription("Returns whether the Sleep A30's noise cancelling is on.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let manager = BluetoothManager.shared
        try await manager.refreshStatus()
        let on = manager.deviceState.noiseCancelling ?? false
        return .result(value: on, dialog: "Noise cancelling is \(on ? "on" : "off").")
    }
}

struct GetSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Sleep Timer"
    static let description = IntentDescription("Returns the minutes left on the Sleep A30's sleep timer, or 0 when it is off.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let manager = BluetoothManager.shared
        try await manager.perform(.querySleepTimer)
        guard let timer = manager.deviceState.sleepTimer, timer.enabled else {
            return .result(value: 0, dialog: "The sleep timer is off.")
        }
        let minutesLeft = Int((Double(timer.remainingSeconds) / 60).rounded(.up))
        return .result(value: minutesLeft, dialog: "About \(minutesLeft) minutes left on the sleep timer.")
    }
}

struct GetA30StatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Sleep A30 Status"
    static let description = IntentDescription("Returns a summary of the Sleep A30: audio source, noise cancelling, sleep timer, and battery.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let manager = BluetoothManager.shared
        try await manager.refreshStatus()
        let state = manager.deviceState
        var parts: [String] = []
        if let source = state.audioSource { parts.append("Audio source: \(source.title)") }
        if let anc = state.noiseCancelling { parts.append("Noise cancelling: \(anc ? "on" : "off")") }
        if let timer = state.sleepTimer {
            if timer.enabled {
                let minutesLeft = Int((Double(timer.remainingSeconds) / 60).rounded(.up))
                parts.append("Sleep timer: \(timer.minutes) min, about \(minutesLeft) min left")
            } else {
                parts.append("Sleep timer: off")
            }
        }
        let left = state.batteryLevelLeft.map { "level \($0)" } ?? "in case"
        let right = state.batteryLevelRight.map { "level \($0)" } ?? "in case"
        parts.append("Battery: left \(left), right \(right)\(state.caseBatteryPercent.map { ", case \($0)%" } ?? "")")
        if let playing = state.bluetoothAudioPlaying { parts.append("Bluetooth audio: \(playing ? "playing" : "paused")") }
        let summary = parts.joined(separator: "\n")
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

// MARK: - Siri phrases

struct A30Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetAudioSourceIntent(),
            phrases: [
                "Set \(.applicationName) audio source to \(\.$source)",
                "Switch \(.applicationName) to \(\.$source) mode",
            ],
            shortTitle: "Set Audio Source",
            systemImageName: "earbuds"
        )
        AppShortcut(
            intent: SetNoiseCancellingIntent(),
            phrases: [
                "Turn \(.applicationName) noise cancelling \(\.$state)",
            ],
            shortTitle: "Noise Cancelling",
            systemImageName: "ear.and.waveform"
        )
        AppShortcut(
            intent: StartSleepTimerIntent(),
            phrases: [
                "Start \(.applicationName) sleep timer",
            ],
            shortTitle: "Start Sleep Timer",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: StopSleepTimerIntent(),
            phrases: [
                "Stop \(.applicationName) sleep timer",
            ],
            shortTitle: "Stop Sleep Timer",
            systemImageName: "timer.slash"
        )
        AppShortcut(
            intent: SetOnceAsleepIntent(),
            phrases: [
                "Set \(.applicationName) once asleep to \(\.$option)",
            ],
            shortTitle: "Once Asleep",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: GetA30StatusIntent(),
            phrases: [
                "Get \(.applicationName) status",
            ],
            shortTitle: "Status",
            systemImageName: "info.circle"
        )
    }
}
