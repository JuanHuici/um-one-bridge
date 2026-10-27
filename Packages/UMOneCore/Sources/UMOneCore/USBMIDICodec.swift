/// Conversion between USB-MIDI 1.0 event packets (4 bytes: cable/CIN, MIDI_0..2) and
/// Universal MIDI Packets using the MIDI 1.0 protocol (message types 0x1, 0x2, 0x3).
///
/// Code Index Numbers (USB Device Class Definition for MIDI Devices 1.0, table 4-1):
///   0x2  2-byte System Common (F1, F3)          0x3  3-byte System Common (F2)
///   0x4  SysEx starts or continues (3 bytes)     0x5  1-byte System Common (F6) or SysEx ends with 1 byte
///   0x6  SysEx ends with 2 bytes                 0x7  SysEx ends with 3 bytes
///   0x8…0xE  Channel Voice (CIN == status >> 4)  0xF  single byte (Real-Time)
public enum USBMIDI {
    public static func codeIndex(_ header: UInt8) -> UInt8 { header & 0x0F }
    public static func cable(_ header: UInt8) -> UInt8 { header >> 4 }

    /// Number of UMP words for a message type (UMP spec 1.1, table 2).
    public static func umpWordCount(_ firstWord: UInt32) -> Int {
        switch firstWord >> 28 {
        case 0x0, 0x1, 0x2, 0x6, 0x7: 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: 2
        case 0xB, 0xC: 3
        default: 4
        }
    }

    /// Number of MIDI messages in UMP words, counting a SysEx once (on its last packet).
    public static func countMessages<Words: Collection>(_ words: Words) -> UInt64 where Words.Element == UInt32 {
        var count: UInt64 = 0
        var index = words.startIndex
        while index != words.endIndex {
            let w0 = words[index]
            switch w0 >> 28 {
            case 0x1, 0x2, 0x4: count += 1
            case 0x3:
                let status = (w0 >> 20) & 0xF
                if status == 0 || status == 3 { count += 1 }
            default: break
            }
            guard let next = words.index(index, offsetBy: umpWordCount(w0), limitedBy: words.endIndex) else { break }
            index = next
        }
        return count
    }

    /// Human readable form of one USB-MIDI packet, for verbose logging.
    public static func describe(_ p: (UInt8, UInt8, UInt8, UInt8)) -> String {
        let names: [UInt8: String] = [
            0x0: "misc", 0x1: "cable", 0x2: "syscom2", 0x3: "syscom3", 0x4: "sysex+",
            0x5: "end1/syscom1", 0x6: "sysex-end2", 0x7: "sysex-end3", 0x8: "noteoff", 0x9: "noteon",
            0xA: "polyAT", 0xB: "cc", 0xC: "pgm", 0xD: "chanAT", 0xE: "bend", 0xF: "byte",
        ]
        let hex = [p.0, p.1, p.2, p.3].map { byteHex($0) }.joined(separator: " ")
        return "\(hex)  [c\(cable(p.0)) \(names[codeIndex(p.0)]!)]"
    }

    static func byteHex(_ b: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(b >> 4)], digits[Int(b & 0xF)]])
    }
}

private enum UMPSysExStatus: UInt32 {
    case complete = 0, start = 1, `continue` = 2, end = 3
}

/// Device → host: USB-MIDI packets to UMP words (MIDI 1.0 protocol).
public struct USBToUMPConverter {
    public var group: UInt8

    private var inSysEx = false
    private var sentSysExPacket = false
    private var sysExBuffer: [UInt8] = []

    public init(group: UInt8 = 0) {
        self.group = group
        sysExBuffer.reserveCapacity(6)
    }

    /// Converts the packets in a bulk IN transfer, appending complete UMP messages to `out`.
    /// A trailing partial packet is ignored.
    public mutating func convert(_ bytes: UnsafeRawBufferPointer, into out: inout [UInt32]) {
        var i = 0
        while i + 4 <= bytes.count {
            convert((bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]), into: &out)
            i += 4
        }
    }

    public mutating func convert(_ p: (UInt8, UInt8, UInt8, UInt8), into out: inout [UInt32]) {
        switch USBMIDI.codeIndex(p.0) {
        case 0x0, 0x1:
            break // reserved; Roland pads transfers with all-zero packets
        case 0x2:
            system(p.1, p.2, 0, into: &out)
        case 0x3:
            system(p.1, p.2, p.3, into: &out)
        case 0x4:
            sysExBytes([p.1, p.2, p.3], into: &out)
        case 0x5:
            if p.1 == 0xF7 || (p.1 < 0x80 && inSysEx) {
                sysExBytes([p.1], into: &out)
            } else {
                singleByte(p.1, into: &out)
            }
        case 0x6:
            sysExBytes([p.1, p.2], into: &out)
        case 0x7:
            sysExBytes([p.1, p.2, p.3], into: &out)
        case 0x8...0xE:
            guard p.1 >= 0x80, p.1 < 0xF0 else { break }
            let twoByte = (p.1 & 0xF0) == 0xC0 || (p.1 & 0xF0) == 0xD0
            out.append(word(type: 0x2, p.1, p.2 & 0x7F, twoByte ? 0 : p.3 & 0x7F))
        default: // 0xF
            if p.1 < 0x80 {
                if inSysEx { sysExBytes([p.1], into: &out) }
            } else {
                singleByte(p.1, into: &out)
            }
        }
    }

    private mutating func singleByte(_ status: UInt8, into out: inout [UInt32]) {
        switch status {
        case 0xF0, 0xF7:
            sysExBytes([status], into: &out)
        case 0xF1...0xFF:
            system(status, 0, 0, into: &out)
        default:
            break
        }
    }

    private mutating func system(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, into out: inout [UInt32]) {
        guard status >= 0xF1, status != 0xF7, status != 0xF4, status != 0xF5 else { return }
        // A System Common message aborts a SysEx in progress; Real-Time does not.
        if status < 0xF8, inSysEx { finishSysEx(into: &out) }
        out.append(word(type: 0x1, status, d1 & 0x7F, d2 & 0x7F))
    }

    private mutating func sysExBytes(_ bytes: [UInt8], into out: inout [UInt32]) {
        for b in bytes {
            switch b {
            case 0xF0:
                if inSysEx { finishSysEx(into: &out) }
                inSysEx = true
                sentSysExPacket = false
                sysExBuffer.removeAll(keepingCapacity: true)
            case 0xF7:
                if inSysEx { finishSysEx(into: &out) }
            case 0x00...0x7F:
                guard inSysEx else { continue }
                if sysExBuffer.count == 6 {
                    emitSysEx(sentSysExPacket ? .continue : .start, into: &out)
                    sentSysExPacket = true
                }
                sysExBuffer.append(b)
            default:
                break
            }
        }
    }

    private mutating func finishSysEx(into out: inout [UInt32]) {
        emitSysEx(sentSysExPacket ? .end : .complete, into: &out)
        inSysEx = false
        sentSysExPacket = false
    }

    private mutating func emitSysEx(_ status: UMPSysExStatus, into out: inout [UInt32]) {
        var d = [UInt8](repeating: 0, count: 6)
        for (i, b) in sysExBuffer.enumerated() { d[i] = b }
        let w0 = UInt32(0x30 | (group & 0xF)) << 24 | (status.rawValue << 4 | UInt32(sysExBuffer.count)) << 16
            | UInt32(d[0]) << 8 | UInt32(d[1])
        let w1 = UInt32(d[2]) << 24 | UInt32(d[3]) << 16 | UInt32(d[4]) << 8 | UInt32(d[5])
        out.append(w0)
        out.append(w1)
        sysExBuffer.removeAll(keepingCapacity: true)
    }

    private func word(type: UInt32, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> UInt32 {
        (type << 4 | UInt32(group & 0xF)) << 24 | UInt32(b1) << 16 | UInt32(b2) << 8 | UInt32(b3)
    }
}

/// Host → device: UMP words (MIDI 1.0 protocol) to USB-MIDI packets.
public struct UMPToUSBConverter {
    public var cable: UInt8

    private var inSysEx = false
    private var pending: [UInt8] = []

    public init(cable: UInt8 = 0) {
        self.cable = cable
        pending.reserveCapacity(3)
    }

    /// Converts a sequence of UMP words, appending 4-byte USB-MIDI packets to `out`.
    /// Message types other than System, MIDI 1.0 Channel Voice and 7-bit SysEx are dropped.
    public mutating func convert<Words: Collection>(_ words: Words, into out: inout [UInt8])
    where Words.Element == UInt32 {
        var index = words.startIndex
        while index != words.endIndex {
            let w0 = words[index]
            let count = USBMIDI.umpWordCount(w0)
            guard let end = words.index(index, offsetBy: count, limitedBy: words.endIndex) else { return }
            let w1 = count > 1 ? words[words.index(after: index)] : 0
            convert(w0, w1, into: &out)
            index = end
        }
    }

    private mutating func convert(_ w0: UInt32, _ w1: UInt32, into out: inout [UInt8]) {
        let status = UInt8(truncatingIfNeeded: w0 >> 16)
        let d1 = UInt8(truncatingIfNeeded: w0 >> 8) & 0x7F
        let d2 = UInt8(truncatingIfNeeded: w0) & 0x7F
        switch w0 >> 28 {
        case 0x2:
            guard status >= 0x80, status < 0xF0 else { return }
            let twoByte = (status & 0xF0) == 0xC0 || (status & 0xF0) == 0xD0
            packet(status >> 4, status, d1, twoByte ? 0 : d2, into: &out)
        case 0x1:
            switch status {
            case 0xF8...0xFF: packet(0xF, status, 0, 0, into: &out)
            case 0xF1, 0xF3: packet(0x2, status, d1, 0, into: &out)
            case 0xF2: packet(0x3, status, d1, d2, into: &out)
            case 0xF6: packet(0x5, status, 0, 0, into: &out)
            default: return
            }
        case 0x3:
            let kind = (w0 >> 20) & 0xF
            let n = min(Int((w0 >> 16) & 0xF), 6)
            let data: [UInt8] = [
                UInt8(truncatingIfNeeded: w0 >> 8), UInt8(truncatingIfNeeded: w0),
                UInt8(truncatingIfNeeded: w1 >> 24), UInt8(truncatingIfNeeded: w1 >> 16),
                UInt8(truncatingIfNeeded: w1 >> 8), UInt8(truncatingIfNeeded: w1),
            ]
            if kind == UMPSysExStatus.complete.rawValue || kind == UMPSysExStatus.start.rawValue {
                if inSysEx { sysExByte(0xF7, into: &out) } // previous one never ended
                inSysEx = true
                sysExByte(0xF0, into: &out)
            }
            guard inSysEx else { return } // continue/end without a start
            for b in data.prefix(n) { sysExByte(b & 0x7F, into: &out) }
            if kind == UMPSysExStatus.complete.rawValue || kind == UMPSysExStatus.end.rawValue {
                sysExByte(0xF7, into: &out)
            }
        default:
            return
        }
    }

    private mutating func sysExByte(_ b: UInt8, into out: inout [UInt8]) {
        pending.append(b)
        if b == 0xF7 {
            // CIN 0x5/0x6/0x7: SysEx ends with 1/2/3 bytes.
            let cin = UInt8(0x4 + pending.count)
            packet(cin, pending[0], pending.count > 1 ? pending[1] : 0, pending.count > 2 ? pending[2] : 0, into: &out)
            pending.removeAll(keepingCapacity: true)
            inSysEx = false
        } else if pending.count == 3 {
            packet(0x4, pending[0], pending[1], pending[2], into: &out)
            pending.removeAll(keepingCapacity: true)
        }
    }

    private func packet(_ cin: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8, into out: inout [UInt8]) {
        out.append(cable << 4 | cin)
        out.append(b1)
        out.append(b2)
        out.append(b3)
    }
}
