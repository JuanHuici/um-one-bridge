import Foundation
import UMOneCore

func hex32(_ v: UInt32) -> String { String(format: "0x%08x", v) }

func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func describe(_ error: Error) -> String {
    let ns = error as NSError
    return "\(ns.domain) \(ioReturnString(IOReturn(truncatingIfNeeded: ns.code))) \(ns.localizedDescription)"
}

let usage = """
usage: umone-diag <mode> [--location 0xLOC]
  --descriptors          open, print descriptors, configure(1), open interface 0 and its pipes, close
  --dump [--zero]        print raw USB-MIDI packets (IN and OUT) until Ctrl-C; --zero keeps padding
  --send-note            play middle C (ch 1) on each UM-ONE and print what comes back
  --reset                USB-reset (re-enumerate) the device(s), same as unplug + replug
  --headless [--verbose] run the full bridge with CoreMIDI endpoints, without the menu bar app
"""

var args = Array(CommandLine.arguments.dropFirst())
var location: UInt32?
if let i = args.firstIndex(of: "--location"), i + 1 < args.count {
    location = UInt32(args[i + 1].replacingOccurrences(of: "0x", with: ""), radix: 16)
    args.removeSubrange(i...i + 1)
}

switch args.first {
case "--descriptors":
    exit(runDescriptors(location: location))
case "--dump":
    runDump(location: location, includeZero: args.contains("--zero"))
case "--send-note":
    runSendNote(location: location)
case "--reset":
    exit(runReset(location: location))
case "--headless":
    runHeadless(verbose: args.contains("--verbose"))
default:
    print(usage)
    exit(2)
}
