//
//  Soundcore_UtilitiesTests.swift
//  Soundcore UtilitiesTests
//

import Foundation
import Testing
@testable import Soundcore_Utilities

struct SoundcorePacketTests {
    /// All packets here were captured from the official app in PacketLogger.
    @Test func audioSourcePacketsMatchCapture() {
        #expect(SoundcorePacket.setAudioSource(.local).hexString == "08 EE 00 00 00 01 A9 0B 00 01 AC")
        #expect(SoundcorePacket.setAudioSource(.bluetooth).hexString == "08 EE 00 00 00 01 A9 0B 00 00 AB")
    }

    @Test func noiseCancellingPacketsMatchCapture() {
        #expect(SoundcorePacket.setNoiseCancelling(true).hexString == "08 EE 00 00 00 06 87 0B 00 01 8F")
        #expect(SoundcorePacket.setNoiseCancelling(false).hexString == "08 EE 00 00 00 06 87 0B 00 00 8E")
    }

    @Test func requestStatePacket() {
        #expect(SoundcorePacket.requestState.hexString == "08 EE 00 00 00 01 01 0A 00 02")
    }

    /// Sleep timer packets from "sleep timer.pklg", including the app's short length field.
    @Test func sleepTimerPacketsMatchCapture() {
        #expect(SoundcorePacket.Command.querySleepTimer.data.hexString == "08 EE 00 00 00 15 03 0A 00 18")
        #expect(SoundcorePacket.Command.sleepTimer(enabled: true, minutes: 10, flag: 1).data.hexString == "08 EE 00 00 00 15 85 0E 00 00 01 0A 00 01 AA")
        #expect(SoundcorePacket.Command.sleepTimer(enabled: true, minutes: 90, flag: 1).data.hexString == "08 EE 00 00 00 15 85 0E 00 00 01 5A 00 01 FA")
        #expect(SoundcorePacket.Command.sleepTimer(enabled: false, minutes: 3, flag: 1).data.hexString == "08 EE 00 00 00 15 85 0E 00 00 00 03 00 01 A2")
    }

    /// Auto-switch packets from "auto switch once asleep.pklg".
    @Test func autoSwitchPacketsMatchCapture() {
        #expect(SoundcorePacket.Command.autoSwitch(1).data.hexString == "08 EE 00 00 00 15 8F 0B 00 01 A6")
        #expect(SoundcorePacket.Command.autoSwitch(0).data.hexString == "08 EE 00 00 00 15 8F 0B 00 00 A5")
        #expect(SoundcorePacket.Command.sleepSettingsFlag(1).data.hexString == "08 EE 00 00 00 15 85 0E 00 FF FF FF 01 9C")
    }

    @Test func parsesSleepTimerStatus() throws {
        let running = try #require(SoundcorePacket.parse(Data(hexString: "09 FF 00 00 01 15 03 12 00 01 5A 00 01 18 15 00 00 BC")!))
        let status = try #require(SoundcorePacket.SleepTimerStatus(body: running.body))
        #expect(status.enabled)
        #expect(status.minutes == 90)
        #expect(status.flag == 1)
        #expect(status.remainingSeconds == 5400)
        #expect(running.checksumValid)

        let off = try #require(SoundcorePacket.parse(Data(hexString: "09 FF 00 00 01 15 03 12 00 00 1E 00 00 00 00 00 00 51")!))
        let offStatus = try #require(SoundcorePacket.SleepTimerStatus(body: off.body))
        #expect(!offStatus.enabled)
        #expect(offStatus.minutes == 30)
        #expect(offStatus.flag == 0)
    }

    /// Snapshots 1 and 6 from the user's labelled capture set.
    @Test func parsesStateDump() throws {
        let baseline = "00 01 08 08 30 31 2E 39 31 30 31 2E 39 31 31 33 30 31 37 43 45 39 31 33 32 41 46 43 35 32 60 DA 1D 13 E9 7C 30 31 2E 36 38 00 00 00 00 06 DD 88 11 00 FF FF FF FF FF FF FF FF 00 03 00 00 FF FF FF 00 00 01 00 00 32 25 00 00 06 00 93 71 40 00 00 00 00 00 03 01 00 00 00 00 00 00 00 00 00 02 01 80 00 00 00 00 00 00 04 03 02 80 00 00 00 00 00 00 04 04 03 80 00 00 00 00 00 00 04 05 04 80 00 00 00 00 00 00 04 00 00 00 01 04 01 00 01 00 00 01 01 01 00 00"
        let dump = try #require(SoundcorePacket.StateDump(body: [UInt8](Data(hexString: baseline)!)))
        #expect(dump.firmwareLeft == "01.91")
        #expect(dump.firmwareRight == "01.91")
        #expect(dump.serialNumber == "13017CE9132AFC52")
        #expect(dump.secondaryFirmware == "01.68")
        #expect(!dump.sleepTimerEnabled)
        #expect(dump.sleepTimerMinutes == 3)
        #expect(dump.sleepSettingsFlag == 0)
        #expect(dump.audioSource == .bluetooth)
        #expect(dump.noiseCancelling)

        let local = "00 01 08 08 30 31 2E 39 31 30 31 2E 39 31 31 33 30 31 37 43 45 39 31 33 32 41 46 43 35 32 60 DA 1D 13 E9 7C 30 31 2E 36 38 00 00 00 00 06 DD 88 11 00 FF FF FF FF FF FF FF FF 00 5A 00 00 FF FF FF 01 00 01 00 00 32 25 00 01 06 00 93 71 40 00 00 00 00 00 03 01 00 00 00 00 00 00 00 00 00 02 01 80 00 00 00 00 00 00 04 03 02 80 00 00 00 00 00 00 04 04 03 80 00 00 00 00 00 00 04 05 04 80 00 00 00 00 00 00 04 00 00 00 01 04 01 00 01 00 00 00 01 01 00 00"
        let localDump = try #require(SoundcorePacket.StateDump(body: [UInt8](Data(hexString: local)!)))
        #expect(localDump.audioSource == .local)
        #expect(localDump.sleepTimerMinutes == 90)
        #expect(SoundcorePacket.StateDump(body: [0, 1, 2]) == nil)

        // "In case" snapshot: left earbud docked, right still worn.
        let inCase = "01 00 FF 07 30 31 2E 39 31 30 31 2E 39 31 31 33 30 31 37 43 45 39 31 33 32 41 46 43 35 32 60 DA 1D 13 E9 7C 30 31 2E 36 38 00 00 00 00 06 DD 88 11 00 FF FF FF FF FF FF FF FF 00 5A 00 01 FF FF FF 00 00 01 00 00 32 25 00 00 06 00 93 71 40 00 00 00 00 00 03 01 00 00 00 00 00 00 00 00 00 02 01 80 00 00 00 00 00 00 04 03 02 80 00 00 00 00 00 00 04 04 03 80 00 00 00 00 00 00 04 05 04 80 00 00 00 00 00 00 04 00 00 00 01 04 01 00 01 00 01 01 01 01 01 00"
        let docked = try #require(SoundcorePacket.StateDump(body: [UInt8](Data(hexString: inCase)!)))
        #expect(docked.batteryLevelLeft == nil)
        #expect(docked.batteryLevelRight == 7)
        #expect(docked.primaryIsRight)
        #expect(!docked.bothEarbudsConnected)
        #expect(docked.caseBatteryPercent == 50)
        #expect(docked.bluetoothAudioPlaying)
        #expect(docked.sleepSettingsFlag == 1)
    }

    @Test func autoSwitchOptionMapping() {
        #expect(SoundcorePacket.AutoSwitchOption.from(enabled: false, flag: 1) == .keepAudio)
        #expect(SoundcorePacket.AutoSwitchOption.from(enabled: true, flag: 0) == .pauseAudio)
        #expect(SoundcorePacket.AutoSwitchOption.from(enabled: true, flag: 1) == .localAudioANCOff)
        #expect(SoundcorePacket.AutoSwitchOption.localAudioANCOff.flag == 1)
        #expect(!SoundcorePacket.AutoSwitchOption.keepAudio.enabled)
    }

    @Test func snapshotDiff() {
        let a = StateSnapshot(label: "a", body: Data([0x00, 0x01, 0x02]))
        let b = StateSnapshot(label: "b", body: Data([0x00, 0xFF, 0x02, 0x03]))
        #expect(b.changedOffsets(from: a) == [1, 3])
        #expect(a.changedOffsets(from: nil).isEmpty)
    }

    @Test func checksumValidation() {
        #expect(SoundcorePacket.hasValidChecksum(Data(hexString: "09 FF 00 00 01 01 A9 0A 00 BD")!))
        #expect(SoundcorePacket.hasValidChecksum(Data(hexString: "09 FF 00 00 01 06 87 0B 00 01 A2")!))
        #expect(!SoundcorePacket.hasValidChecksum(Data(hexString: "09 FF 00 00 01 01 14 0B 00 01 2B")!))
    }

    @Test func parsesInboundFrames() throws {
        let ack = try #require(SoundcorePacket.parse(Data(hexString: "09 FF 00 00 01 01 A9 0A 00 BD")!))
        #expect(ack.direction == .inbound)
        #expect(ack.command == SoundcorePacket.CommandID.setAudioSource)
        #expect(ack.body.isEmpty)
        #expect(ack.checksumValid)

        let ancState = try #require(SoundcorePacket.parse(Data(hexString: "09 FF 00 00 01 06 07 0B 00 00 21")!))
        #expect(ancState.command == SoundcorePacket.CommandID.noiseCancellingState)
        #expect(ancState.body == [0x00])
        #expect(ancState.summary == "resp 0607 noise cancelling=off, checksum ok")

        let modeState = try #require(SoundcorePacket.parse(Data(hexString: "09 FF 00 00 01 01 14 0B 00 01 2A")!))
        #expect(modeState.summary == "resp 0114 audio source=Local, checksum ok")

        #expect(SoundcorePacket.parse(Data(hexString: "00 11 22")!) == nil)
        // A reply exactly as CoreBluetooth delivered it from the earbuds.
        let ancAck = try #require(SoundcorePacket.parse(Data(hexString: "09 FF 00 00 01 06 87 0B 00 01 A2")!))
        #expect(ancAck.command == SoundcorePacket.CommandID.setNoiseCancelling)
        #expect(ancAck.declaredLength == 11)
        #expect(ancAck.checksumValid)
    }

    @Test func hexParsing() {
        #expect(Data(hexString: "08ee00")?.hexString == "08 EE 00")
        #expect(Data(hexString: "0x08, 0xEE")?.hexString == "08 EE")
        #expect(Data(hexString: "08E") == nil)
        #expect(Data(hexString: "") == nil)
    }

    @Test func describeDecodesMode() {
        #expect(SoundcorePacket.describe(SoundcorePacket.setAudioSource(.local)) == "cmd 01A9 audio source=Local, checksum ok")
    }
}

struct DeviceIdentificationTests {
    @Test func recognisesA30Names() {
        #expect(BluetoothManager.looksLikeA30("soundcore Sleep A30"))
        #expect(BluetoothManager.looksLikeA30("soundcore Sleep A30 LE"))
        #expect(BluetoothManager.looksLikeA30("Sleep A30"))
        #expect(!BluetoothManager.looksLikeA30("soundcore Liberty 4"))
        #expect(!BluetoothManager.looksLikeA30("Galaxy A30"))
        #expect(!BluetoothManager.looksLikeA30(nil))
    }

    @Test func distinguishesLEIdentity() {
        #expect(BluetoothManager.isLEIdentityName("soundcore Sleep A30 LE"))
        #expect(BluetoothManager.isLEIdentityName("soundcore Sleep A30 le "))
        #expect(!BluetoothManager.isLEIdentityName("soundcore Sleep A30"))
        #expect(!BluetoothManager.isLEIdentityName(nil))
    }
}
