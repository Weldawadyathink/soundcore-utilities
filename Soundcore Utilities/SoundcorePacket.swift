//
//  SoundcorePacket.swift
//  Soundcore Utilities
//
//  Builder and decoder for the proprietary Soundcore control packet, as seen
//  in PacketLogger captures of the official app talking to a Sleep A30.
//
//  Host -> earbuds:
//      08 EE 00 00 00 | 01 A9 | 0B 00 | 01 | AC
//      prefix          command  length  body  checksum
//
//  Earbuds -> host:
//      09 FF 00 00 01 | 01 A9 | 0A 00 | BD
//
//  * length    total packet length, little endian, including the checksum
//  * checksum  low 8 bits of the sum of every preceding byte
//
//  Commands observed so far:
//      01 A9  set audio source      body 00 = Bluetooth, 01 = Local
//      01 14  audio source state    (pushed by earbuds after a change)
//      06 87  set noise cancelling  body 00 = off, 01 = on
//      06 07  noise cancelling state (pushed by earbuds after a change)
//      01 01  request state         (standard across the Soundcore family; used as a probe;
//                                     answers with a 160-byte state dump, layout not yet mapped)
//      01 13  audio status push     (after a source change; body 00 93 71 40 00 00 00 00 00 [source] 25)
//      15 03  sleep timer status    query with empty body; earbuds answer and also push after changes:
//                                     body = enabled, minutes u16 LE, flag, remaining seconds u32 LE
//      15 85  set sleep settings    body 00, enabled, minutes u16 LE, flag  (the official app declares
//                                     the length one byte short for this command; we mirror it)
//                                     variant FF FF FF xx sets only the flag byte
//      15 8F  auto-switch once asleep  body 01 = on, 00 = off ("Keep Audio")
//                                     with it on, the sleep settings flag picks the action:
//                                     01 = play local audio with ANC off, 00 = pause audio
//
//  State dump (01 01 reply body, 150 bytes) offsets confirmed from labelled snapshots:
//      0      primary earbud (00 left, 01 right)  1      both earbuds connected (01) / one (00)
//      2-3    battery level left, right; FF when that earbud is in the case
//             (07 while the app showed 80 %; scale not yet confirmed)
//      4-8    firmware, left, ASCII "01.91"       9-13   firmware, right
//      14-29  serial number, 16 ASCII chars       30-35  a Bluetooth address, reversed
//      36-40  secondary firmware, ASCII "01.68"
//      58     sleep timer enabled                 59-60  sleep timer minutes, u16 LE
//      61     sleep settings flag                 65     audio source (00 BT, 01 local)
//      70     0x32 = 50 while the case showed 50 %; probably case battery percent (unverified)
//      73     01 while local audio is active      140    noise cancelling
//      145    01 while Bluetooth audio is playing, 00 when paused
//      144, 148 went 00 -> 01 after our auto-switch writes; one is probably 15 8F, unconfirmed
//

import Foundation

nonisolated enum SoundcorePacket {
    static let outboundPrefix: [UInt8] = [0x08, 0xEE, 0x00, 0x00, 0x00]
    static let inboundPrefix: [UInt8] = [0x09, 0xFF, 0x00, 0x00, 0x01]

    enum CommandID: Equatable {
        static let setAudioSource: [UInt8] = [0x01, 0xA9]
        static let audioSourceState: [UInt8] = [0x01, 0x14]
        static let setNoiseCancelling: [UInt8] = [0x06, 0x87]
        static let noiseCancellingState: [UInt8] = [0x06, 0x07]
        static let requestState: [UInt8] = [0x01, 0x01]
        static let audioStatus: [UInt8] = [0x01, 0x13]
        static let sleepTimerStatus: [UInt8] = [0x15, 0x03]
        static let setSleepSettings: [UInt8] = [0x15, 0x85]
        static let setAutoSwitch: [UInt8] = [0x15, 0x8F]
    }

    /// Decoded body of a 15 03 sleep timer status frame.
    struct SleepTimerStatus: Equatable {
        var enabled: Bool
        var minutes: UInt16
        var flag: UInt8
        var remainingSeconds: UInt32

        init?(body: [UInt8]) {
            guard body.count >= 8 else { return nil }
            enabled = body[0] != 0
            minutes = UInt16(body[1]) | (UInt16(body[2]) << 8)
            flag = body[3]
            remainingSeconds = UInt32(body[4]) | (UInt32(body[5]) << 8) | (UInt32(body[6]) << 16) | (UInt32(body[7]) << 24)
        }

        var summary: String {
            enabled ? "on, \(minutes) min, \(remainingSeconds) s left, flag \(flag)" : "off, preset \(minutes) min, flag \(flag)"
        }
    }

    static let sleepTimerPresets: [UInt16] = [10, 20, 30, 60, 90]

    /// What the earbuds do once they detect the wearer is asleep.
    enum AutoSwitchOption: String, CaseIterable, Identifiable {
        case keepAudio, pauseAudio, localAudioANCOff

        var id: String { rawValue }

        var title: String {
            switch self {
            case .keepAudio: return "Keep audio"
            case .pauseAudio: return "Pause audio"
            case .localAudioANCOff: return "Local audio, ANC off"
            }
        }

        var enabled: Bool { self != .keepAudio }
        var flag: UInt8 { self == .localAudioANCOff ? 1 : 0 }

        static func from(enabled: Bool, flag: UInt8) -> AutoSwitchOption {
            guard enabled else { return .keepAudio }
            return flag == 0 ? .pauseAudio : .localAudioANCOff
        }
    }

    /// Fields of the 01 01 state dump whose offsets have been confirmed.
    struct StateDump: Equatable {
        static let minimumLength = 141
        let body: [UInt8]

        init?(body: [UInt8]) {
            guard body.count >= Self.minimumLength else { return nil }
            self.body = body
        }

        private func ascii(_ range: Range<Int>) -> String {
            String(decoding: body[range].prefix { $0 != 0 }, as: UTF8.self)
        }

        var firmwareLeft: String { ascii(4..<9) }
        var firmwareRight: String { ascii(9..<14) }
        var serialNumber: String { ascii(14..<30) }
        var secondaryFirmware: String { ascii(36..<41) }
        var sleepTimerEnabled: Bool { body[58] != 0 }
        var sleepTimerMinutes: UInt16 { UInt16(body[59]) | (UInt16(body[60]) << 8) }
        var sleepSettingsFlag: UInt8 { body[61] }
        var audioSource: AudioSource? { AudioSource(rawValue: body[65]) }
        var noiseCancelling: Bool { body[140] != 0 }
        var primaryIsRight: Bool { body[0] != 0 }
        var bothEarbudsConnected: Bool { body[1] != 0 }
        /// Raw level as reported; nil when that earbud is in the case (0xFF). Scale unconfirmed.
        var batteryLevelLeft: UInt8? { body[2] == 0xFF ? nil : body[2] }
        var batteryLevelRight: UInt8? { body[3] == 0xFF ? nil : body[3] }
        /// Probably the case battery in percent; matched the app once, unverified.
        var caseBatteryPercent: UInt8 { body[70] }
        var localAudioActive: Bool { body[73] != 0 }
        var bluetoothAudioPlaying: Bool { body[145] != 0 }
        /// Bytes that moved after auto-switch writes; kept raw until their meaning is confirmed.
        var unknown144: UInt8 { body[144] }
        var unknown148: UInt8 { body[148] }
    }

    enum AudioSource: UInt8, CaseIterable, Identifiable {
        case bluetooth = 0x00
        case local = 0x01

        var id: UInt8 { rawValue }

        var title: String {
            switch self {
            case .bluetooth: return "Bluetooth"
            case .local: return "Local"
            }
        }
    }

    /// A user-level action, with the exact bytes it sends.
    enum Command: Hashable, CaseIterable, Identifiable {
        case audioSource(AudioSource)
        case noiseCancelling(Bool)
        case requestState
        case querySleepTimer
        /// `flag` is the fourth body byte; the official app echoes the current auto-switch flag here.
        case sleepTimer(enabled: Bool, minutes: UInt16, flag: UInt8)
        /// The 15 85 FF FF FF xx variant: changes only the flag byte of the sleep settings.
        case sleepSettingsFlag(UInt8)
        /// 15 8F with a single byte; which auto-switch option this is has not been confirmed.
        case autoSwitch(UInt8)

        static var allCases: [Command] {
            [
                .audioSource(.bluetooth), .audioSource(.local),
                .noiseCancelling(true), .noiseCancelling(false),
                .requestState, .querySleepTimer,
                .sleepTimer(enabled: true, minutes: 10, flag: 1), .sleepTimer(enabled: false, minutes: 10, flag: 1),
                .autoSwitch(1), .sleepSettingsFlag(1), .autoSwitch(0), .sleepSettingsFlag(0),
            ]
        }

        var id: String { title }

        var title: String {
            switch self {
            case .audioSource(let source): return "\(source.title) mode"
            case .noiseCancelling(let on): return on ? "Noise cancelling on" : "Noise cancelling off"
            case .requestState: return "Request state"
            case .querySleepTimer: return "Query sleep timer"
            case .sleepTimer(let enabled, let minutes, _): return enabled ? "Sleep timer \(minutes) min" : "Sleep timer off"
            case .sleepSettingsFlag(let flag): return "Sleep settings flag = \(flag) (15 85 FF FF FF)"
            case .autoSwitch(let value): return "Auto-switch 15 8F = \(value)"
            }
        }

        var commandID: [UInt8] {
            switch self {
            case .audioSource: return CommandID.setAudioSource
            case .noiseCancelling: return CommandID.setNoiseCancelling
            case .requestState: return CommandID.requestState
            case .querySleepTimer: return CommandID.sleepTimerStatus
            case .sleepTimer, .sleepSettingsFlag: return CommandID.setSleepSettings
            case .autoSwitch: return CommandID.setAutoSwitch
            }
        }

        var body: [UInt8] {
            switch self {
            case .audioSource(let source): return [source.rawValue]
            case .noiseCancelling(let on): return [on ? 0x01 : 0x00]
            case .requestState, .querySleepTimer: return []
            case .sleepTimer(let enabled, let minutes, let flag):
                return [0x00, enabled ? 0x01 : 0x00, UInt8(minutes & 0xFF), UInt8(minutes >> 8), flag]
            case .sleepSettingsFlag(let flag): return [0xFF, 0xFF, 0xFF, flag]
            case .autoSwitch(let value): return [value]
            }
        }

        var data: Data {
            switch self {
            case .sleepTimer:
                // Mirror the official app byte for byte: it declares 14 while sending 15.
                return SoundcorePacket.build(command: commandID, body: body, declaredLengthAdjustment: -1)
            default:
                return SoundcorePacket.build(command: commandID, body: body)
            }
        }
    }

    /// A decoded frame in either direction.
    struct Parsed: Equatable {
        enum Direction { case outbound, inbound }

        let direction: Direction
        let command: [UInt8]
        let declaredLength: Int
        let body: [UInt8]
        let checksumValid: Bool

        var commandHex: String { String(format: "%02X%02X", command[0], command[1]) }

        var summary: String {
            let dir = direction == .outbound ? "cmd" : "resp"
            let check = checksumValid ? "checksum ok" : "checksum BAD"
            switch command {
            case CommandID.setAudioSource, CommandID.audioSourceState:
                if let value = body.first {
                    let source = AudioSource(rawValue: value)?.title ?? String(format: "%02X", value)
                    return "\(dir) \(commandHex) audio source=\(source), \(check)"
                }
                return "\(dir) \(commandHex) audio source ack, \(check)"
            case CommandID.setNoiseCancelling, CommandID.noiseCancellingState:
                if let value = body.first {
                    return "\(dir) \(commandHex) noise cancelling=\(value == 0 ? "off" : "on"), \(check)"
                }
                return "\(dir) \(commandHex) noise cancelling ack, \(check)"
            case CommandID.requestState:
                return direction == .inbound
                    ? "\(dir) \(commandHex) state dump (\(body.count) bytes), \(check)"
                    : "\(dir) \(commandHex) state request, \(check)"
            case CommandID.sleepTimerStatus:
                if let status = SleepTimerStatus(body: body) {
                    return "\(dir) \(commandHex) sleep timer \(status.summary), \(check)"
                }
                return "\(dir) \(commandHex) sleep timer query, \(check)"
            case CommandID.setSleepSettings:
                return "\(dir) \(commandHex) sleep settings \(body.isEmpty ? "ack" : body.map { String(format: "%02X", $0) }.joined(separator: " ")), \(check)"
            case CommandID.setAutoSwitch:
                return "\(dir) \(commandHex) auto-switch \(body.isEmpty ? "ack" : "= \(body[0])"), \(check)"
            case CommandID.audioStatus:
                return "\(dir) \(commandHex) audio status, \(check)"
            default:
                return "\(dir) \(commandHex), \(check)"
            }
        }
    }

    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 + Int($1) })
    }

    /// Frames an arbitrary command and body into a complete outbound packet.
    /// `declaredLengthAdjustment` reproduces firmware quirks where the official
    /// app's length field does not match the bytes it sends.
    static func build(command: [UInt8], body: [UInt8], declaredLengthAdjustment: Int = 0) -> Data {
        var bytes = outboundPrefix + command
        let total = bytes.count + 2 + body.count + 1 + declaredLengthAdjustment
        bytes += [UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF)]
        bytes += body
        bytes.append(checksum(bytes))
        return Data(bytes)
    }

    static func setAudioSource(_ source: AudioSource) -> Data {
        Command.audioSource(source).data
    }

    static func setNoiseCancelling(_ on: Bool) -> Data {
        Command.noiseCancelling(on).data
    }

    static var requestState: Data { Command.requestState.data }

    /// Checks that the final byte is the additive checksum of everything before it.
    static func hasValidChecksum(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let bytes = [UInt8](data)
        return checksum(Array(bytes.dropLast())) == bytes.last
    }

    /// Decodes a frame if it carries either known prefix. Returns nil for anything else.
    static func parse(_ data: Data) -> Parsed? {
        let bytes = [UInt8](data)
        let direction: Parsed.Direction
        let prefix: [UInt8]
        if bytes.starts(with: outboundPrefix) {
            direction = .outbound
            prefix = outboundPrefix
        } else if bytes.starts(with: inboundPrefix) {
            direction = .inbound
            prefix = inboundPrefix
        } else {
            return nil
        }
        // prefix | command(2) | length(2) | body | checksum
        guard bytes.count >= prefix.count + 5 else { return nil }
        let command = Array(bytes[prefix.count..<(prefix.count + 2)])
        let declaredLength = Int(bytes[prefix.count + 2]) | (Int(bytes[prefix.count + 3]) << 8)
        let body = Array(bytes[(prefix.count + 4)..<(bytes.count - 1)])
        return Parsed(direction: direction, command: command, declaredLength: declaredLength, body: body, checksumValid: hasValidChecksum(data))
    }

    /// A short human description of a packet, used in the log.
    static func describe(_ data: Data) -> String {
        parse(data)?.summary ?? ""
    }
}

nonisolated extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Parses "08 EE 00" / "08ee00" / "0x08,0xEE" style strings.
    init?(hexString: String) {
        let cleaned = hexString
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")
            .filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0, !cleaned.isEmpty else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
