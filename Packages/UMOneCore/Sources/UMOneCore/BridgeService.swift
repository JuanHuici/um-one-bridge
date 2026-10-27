import CoreMIDI
import Foundation
import IOKit
import os

/// Owns the CoreMIDI client, one `MIDIPort` per known USB location, and the `DeviceManager`.
public final class BridgeService: @unchecked Sendable {
    public struct PortStatus: Sendable, Identifiable, Equatable {
        public var id: Int { index }
        public let index: Int
        public let name: String
        public let locationID: UInt32
        public let state: MIDIPort.State
        public let messagesIn: UInt64
        public let messagesOut: UInt64
    }

    public let options = BridgeOptions()
    /// Called on an arbitrary queue whenever a port changes state.
    public var onChange: (@Sendable () -> Void)?

    private static let slotsKey = "UMOneSlots"
    private let defaults: UserDefaults
    private let client: MIDIClientRef
    private let lock = NSLock()
    private var ports: [UInt32: MIDIPort] = [:]   // guarded by `lock`
    private var manager: DeviceManager!
    private let log = Logger(subsystem: Log.subsystem, category: "bridge")

    public init(clientName: String = "UM-ONE Bridge", defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        var client = MIDIClientRef()
        try check(MIDIClientCreateWithBlock(clientName as CFString, &client, nil), "MIDIClientCreateWithBlock")
        self.client = client
        manager = DeviceManager { [weak self] event in self?.handle(event) }
    }

    /// Creates the endpoints for every location seen before (offline until plugged in) and
    /// starts watching IOKit.
    public func start() {
        manager.queue.async { [self] in
            // Present devices get slots in locationID order the very first time.
            let present = Registry.services(matching: UMOne.deviceMatching()).compactMap { service in
                defer { IOObjectRelease(service) }
                return Registry.locationID(service)
            }
            for location in slots.keys.sorted() + present.sorted() { _ = port(for: location) }
            manager.start()
        }
    }

    public func snapshot() -> [PortStatus] {
        lock.withLock { Array(ports.values) }
            .sorted { $0.index < $1.index }
            .map {
                PortStatus(index: $0.index, name: $0.name, locationID: $0.locationID, state: $0.state,
                           messagesIn: $0.messagesIn.load(ordering: .relaxed),
                           messagesOut: $0.messagesOut.load(ordering: .relaxed))
            }
    }

    /// Persisted locationID → slot number ("UM-ONE n").
    private var slots: [UInt32: Int] {
        get {
            let stored = defaults.dictionary(forKey: Self.slotsKey) as? [String: Int] ?? [:]
            return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                UInt32(key, radix: 16).map { ($0, value) }
            })
        }
        set {
            defaults.set(Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key, radix: 16), $0.value) }),
                         forKey: Self.slotsKey)
        }
    }

    /// Returns the port for a location, creating its endpoints the first time. Manager queue only.
    private func port(for location: UInt32) -> MIDIPort? {
        if let existing = lock.withLock({ ports[location] }) { return existing }
        var slots = self.slots
        let index = slots[location] ?? (1...).first { !Set(slots.values).contains($0) }!
        slots[location] = index
        self.slots = slots
        do {
            let port = try MIDIPort(client: client, index: index, locationID: location, options: options)
            lock.withLock { ports[location] = port }
            onChange?()
            return port
        } catch {
            log.error("could not create endpoints for slot \(index): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func handle(_ event: DeviceManager.Event) {
        switch event {
        case .deviceArrived(let location):
            if let port = port(for: location), port.state != .connected { port.setState(.configuring) }
        case .deviceRemoved(let location):
            if let port = lock.withLock({ ports[location] }), port.state != .connected { port.setState(.waiting) }
        case .failed(let location, let message):
            port(for: location)?.setState(.error(message))
        case .connected(let connection):
            guard let port = port(for: connection.locationID) else {
                connection.queue.async { connection.close(reason: "no MIDI endpoints") }
                return
            }
            let location = connection.locationID
            let attached = port.attach(connection) { [weak self, weak port] reason in
                port?.detach(reason: reason)
                self?.manager.connectionClosed(locationID: location)
                self?.onChange?()
            }
            guard attached else {
                manager.connectionClosed(locationID: location)
                return
            }
            connection.start()
            log.info("\(port.name, privacy: .public) online")
        }
        onChange?()
    }
}
