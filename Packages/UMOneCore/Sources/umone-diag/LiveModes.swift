import Foundation
import UMOneCore

private let started = Date()

private func stamp() -> String { String(format: "%9.3f", Date().timeIntervalSince(started)) }

private func printPackets(_ prefix: String, _ bytes: UnsafeRawBufferPointer, includeZero: Bool) {
    var i = 0
    while i + 4 <= bytes.count {
        let p = (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        if includeZero || p != (0, 0, 0, 0) {
            print("\(stamp()) \(prefix) \(USBMIDI.describe(p))")
        }
        i += 4
    }
    fflush(stdout)
}

/// Keeps managers and connections alive for the lifetime of the process.
nonisolated(unsafe) private var retained: [AnyObject] = []

private func watch(location: UInt32?, onConnected: @escaping @Sendable (UMOneConnection) -> Void) {
    let box = WeakManager()
    let manager = DeviceManager { event in
        switch event {
        case .deviceArrived(let loc): print("\(stamp()) device \(hex32(loc)) present")
        case .deviceRemoved(let loc): print("\(stamp()) device \(hex32(loc)) removed")
        case .failed(let loc, let message): print("\(stamp()) device \(hex32(loc)) FAILED: \(message)")
        case .connected(let connection):
            if let location, connection.locationID != location {
                connection.queue.async { connection.close(reason: "not selected") }
                return
            }
            connection.queue.sync {
                connection.onClose = { reason in
                    print("\(stamp()) [\(hex32(connection.locationID))] closed: \(reason)")
                    box.manager?.connectionClosed(connection)
                }
            }
            print("\(stamp()) [\(hex32(connection.locationID))] interface open")
            onConnected(connection)
        }
        fflush(stdout)
    }
    box.manager = manager
    retained.append(manager)
    manager.start()
}

private final class WeakManager: @unchecked Sendable {
    weak var manager: DeviceManager?
}

/// `--dump`: print every raw USB-MIDI packet in both directions, including hot-plug events.
func runDump(location: UInt32?, includeZero: Bool) -> Never {
    print("Dumping raw USB-MIDI packets. Ctrl-C to stop.")
    watch(location: location) { connection in
        let tag = hex32(connection.locationID)
        connection.queue.sync {
            connection.rawObserver = { direction, bytes in
                printPackets("[\(tag)] \(direction == .input ? "IN " : "OUT")", bytes, includeZero: includeZero)
            }
        }
        connection.start()
    }
    dispatchMain()
}

/// `--send-note`: play middle C on channel 1 through every (or the selected) UM-ONE, while
/// printing anything that comes back.
func runSendNote(location: UInt32?) -> Never {
    watch(location: location) { connection in
        let tag = hex32(connection.locationID)
        connection.queue.sync {
            connection.rawObserver = { direction, bytes in
                printPackets("[\(tag)] \(direction == .input ? "IN " : "OUT")", bytes, includeZero: false)
            }
        }
        connection.start()
        connection.send([0x09, 0x90, 0x3C, 0x64])
        connection.queue.asyncAfter(deadline: .now() + 0.5) {
            connection.send([0x08, 0x80, 0x3C, 0x00])
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    dispatchMain()
}

/// `--headless`: run the full bridge (CoreMIDI endpoints included) without the menu bar UI.
func runHeadless(verbose: Bool) -> Never {
    let service: BridgeService
    do {
        service = try BridgeService(defaults: UserDefaults(suiteName: "com.juanhuici.umone-bridge")!)
    } catch {
        print("could not start: \(error)")
        exit(1)
    }
    service.options.verbose.store(verbose, ordering: .relaxed)
    retained.append(service)
    service.start()
    print("Bridge running\(verbose ? " (verbose: see `log stream --predicate 'subsystem == \"\(Log.subsystem)\"'`)" : ""). Ctrl-C to stop.")
    let timer = DispatchSource.makeTimerSource(queue: .main)
    nonisolated(unsafe) var last: [BridgeService.PortStatus] = []
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let now = service.snapshot()
        guard now != last else { return }
        last = now
        for p in now {
            print("\(stamp()) \(p.name) @\(hex32(p.locationID)) \(p.state)  in \(p.messagesIn)  out \(p.messagesOut)")
        }
        fflush(stdout)
    }
    timer.resume()
    retained.append(timer as AnyObject)
    dispatchMain()
}
