import Testing
@testable import UMOneCore

private func toUMP(_ bytes: [UInt8]) -> [UInt32] {
    var conv = USBToUMPConverter()
    var out: [UInt32] = []
    bytes.withUnsafeBytes { conv.convert($0, into: &out) }
    return out
}

private func toUSB(_ words: [UInt32]) -> [UInt8] {
    var conv = UMPToUSBConverter()
    var out: [UInt8] = []
    conv.convert(words, into: &out)
    return out
}

/// Splits a raw MIDI 1.0 SysEx (F0 … F7) into the USB-MIDI packets a class-compliant device sends.
private func usbSysEx(_ message: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var i = 0
    while i < message.count {
        let chunk = Array(message[i..<min(i + 3, message.count)])
        let cin: UInt8 = chunk.last == 0xF7 ? UInt8(0x4 + chunk.count) : 0x4
        out += [cin] + chunk + [UInt8](repeating: 0, count: 3 - chunk.count)
        i += 3
    }
    return out
}

/// Payload bytes (without F0/F7) carried by UMP type 3 messages, plus their status nibbles.
private func sysExPayload(_ words: [UInt32]) -> (bytes: [UInt8], statuses: [UInt32]) {
    var bytes: [UInt8] = [], statuses: [UInt32] = []
    var i = 0
    while i + 1 < words.count {
        let w0 = words[i], w1 = words[i + 1]
        #expect(w0 >> 28 == 0x3)
        statuses.append((w0 >> 20) & 0xF)
        let all = [UInt8(w0 >> 8 & 0xFF), UInt8(w0 & 0xFF), UInt8(w1 >> 24), UInt8(w1 >> 16 & 0xFF),
                   UInt8(w1 >> 8 & 0xFF), UInt8(w1 & 0xFF)]
        bytes += all.prefix(Int((w0 >> 16) & 0xF))
        i += 2
    }
    return (bytes, statuses)
}

@Suite struct InboundTests {
    @Test func channelVoice() {
        #expect(toUMP([0x09, 0x90, 0x3C, 0x64]) == [0x2090_3C64])
        #expect(toUMP([0x08, 0x81, 0x3C, 0x00]) == [0x2081_3C00])
        #expect(toUMP([0x0B, 0xB2, 0x07, 0x7F]) == [0x20B2_077F])
        #expect(toUMP([0x0C, 0xC0, 0x05, 0x00]) == [0x20C0_0500])
        #expect(toUMP([0x0E, 0xE0, 0x00, 0x40]) == [0x20E0_0040])
    }

    @Test func zeroPaddingIsIgnored() {
        #expect(toUMP([0, 0, 0, 0, 0x09, 0x90, 0x3C, 0x64, 0, 0, 0, 0]) == [0x2090_3C64])
    }

    @Test func systemCommonAndRealTime() {
        #expect(toUMP([0x0F, 0xF8, 0, 0]) == [0x10F8_0000])
        #expect(toUMP([0x0F, 0xFE, 0, 0]) == [0x10FE_0000])
        #expect(toUMP([0x02, 0xF1, 0x23, 0]) == [0x10F1_2300])
        #expect(toUMP([0x02, 0xF3, 0x05, 0]) == [0x10F3_0500])
        #expect(toUMP([0x03, 0xF2, 0x10, 0x20]) == [0x10F2_1020])
        #expect(toUMP([0x05, 0xF6, 0, 0]) == [0x10F6_0000])
    }

    @Test(arguments: 0...20) func sysExOfEveryLength(payloadLength: Int) {
        let payload = (0..<payloadLength).map { UInt8($0 & 0x7F) }
        let words = toUMP(usbSysEx([0xF0] + payload + [0xF7]))
        let (bytes, statuses) = sysExPayload(words)
        #expect(bytes == payload)
        let packets = max(1, (payloadLength + 5) / 6)
        if packets == 1 {
            #expect(statuses == [0])
        } else {
            #expect(statuses == [1] + Array(repeating: 2, count: packets - 2) + [3])
        }
    }

    @Test func realTimeInsideSysExDoesNotBreakIt() {
        var usb = usbSysEx([0xF0, 1, 2, 3, 4, 5, 6, 7, 8, 0xF7])
        usb.insert(contentsOf: [0x0F, 0xF8, 0, 0], at: 4)
        let words = toUMP(usb)
        #expect(words.contains(0x10F8_0000))
        let (bytes, _) = sysExPayload(words.filter { $0 != 0x10F8_0000 })
        #expect(bytes == [1, 2, 3, 4, 5, 6, 7, 8])
    }
}

@Suite struct OutboundTests {
    @Test func channelVoiceUsesStatusNibble() {
        #expect(toUSB([0x2090_3C64]) == [0x09, 0x90, 0x3C, 0x64])
        #expect(toUSB([0x20C3_0500]) == [0x0C, 0xC3, 0x05, 0x00])
        #expect(toUSB([0x20D0_4000]) == [0x0D, 0xD0, 0x40, 0x00])
    }

    @Test func systemMessagesUseCorrectCIN() {
        #expect(toUSB([0x10F8_0000]) == [0x0F, 0xF8, 0, 0])
        #expect(toUSB([0x10FA_0000]) == [0x0F, 0xFA, 0, 0])
        #expect(toUSB([0x10FF_0000]) == [0x0F, 0xFF, 0, 0])
        #expect(toUSB([0x10F1_2300]) == [0x02, 0xF1, 0x23, 0])
        #expect(toUSB([0x10F3_0500]) == [0x02, 0xF3, 0x05, 0])
        #expect(toUSB([0x10F2_1020]) == [0x03, 0xF2, 0x10, 0x20])
        #expect(toUSB([0x10F6_0000]) == [0x05, 0xF6, 0, 0])
    }

    @Test func utilityAndMIDI2AreDropped() {
        #expect(toUSB([0x0000_0000, 0x4090_3C00, 0xFFFF_0000]) == [])
    }

    @Test(arguments: 0...40) func sysExRoundTrip(payloadLength: Int) {
        let message: [UInt8] = [0xF0] + (0..<payloadLength).map { UInt8(($0 * 7) & 0x7F) } + [0xF7]
        let words = toUMP(usbSysEx(message))
        #expect(toUSB(words) == usbSysEx(message))
    }

    @Test func sysExSplitAcrossCalls() {
        let message: [UInt8] = [0xF0] + (1...30).map { UInt8($0) } + [0xF7]
        let words = toUMP(usbSysEx(message))
        var conv = UMPToUSBConverter()
        var out: [UInt8] = []
        for i in stride(from: 0, to: words.count, by: 2) { conv.convert(words[i..<i + 2], into: &out) }
        #expect(out == usbSysEx(message))
    }

    @Test func cableNumberGoesInHighNibble() {
        var conv = UMPToUSBConverter(cable: 1)
        var out: [UInt8] = []
        conv.convert([0x2090_3C64], into: &out)
        #expect(out == [0x19, 0x90, 0x3C, 0x64])
    }
}
