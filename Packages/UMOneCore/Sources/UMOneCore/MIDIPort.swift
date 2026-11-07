import CoreMIDI
import Foundation
import os
import Synchronization

/// One virtual source + destination pair ("UM-ONE n") bound to a USB location, which changes
/// only when another location takes the slot over.
///
/// The endpoints live for the whole process; a `UMOneConnection` is attached while the
/// device is present and detached when it goes away.
public final class MIDIPort: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case waiting            // seen before, not plugged in now
        case configuring
        case connected
        case error(String)
    }

    public let index: Int
    public let name: String
    public var locationID: UInt32 { lock.withLock { _locationID } }
    public let messagesIn = Atomic<UInt64>(0)
    public let messagesOut = Atomic<UInt64>(0)

    let source: MIDIEndpointRef
    let destination: MIDIEndpointRef

    /// Guards `connection`, `outbound`, `_state` and `_locationID`, which the CoreMIDI read thread also touches.
    private let lock = NSLock()
    private var connection: UMOneConnection?
    private var outbound = UMPToUSBConverter()
    private var _state: State = .waiting
    private var _locationID: UInt32
    /// Confined to the attached connection's queue.
    private var inbound = USBToUMPConverter()
    private var inboundWords: [UInt32] = []
    private let options: BridgeOptions
    private let log = Logger(subsystem: Log.subsystem, category: "midi")
    private let rawLog = Logger(subsystem: Log.subsystem, category: "raw")

    init(client: MIDIClientRef, index: Int, locationID: UInt32, options: BridgeOptions) throws {
        self.index = index
        _locationID = locationID
        self.options = options
        name = "UM-ONE \(index)"
        inboundWords.reserveCapacity(64)

        var src = MIDIEndpointRef()
        try check(MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &src), "MIDISourceCreateWithProtocol")
        source = src

        // The read block may be invoked before init finishes; route it through a weak box.
        let owner = WeakBox<MIDIPort>()
        var dst = MIDIEndpointRef()
        let status = MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &dst) { list, _ in
            owner.value?.send(list)
        }
        if status != noErr { MIDIEndpointDispose(src) }
        try check(status, "MIDIDestinationCreateWithProtocol")
        destination = dst
        owner.value = self

        // Stable IDs so DAWs keep their routing across launches and replugs.
        for (endpoint, offset) in [(source, 0), (destination, 1)] {
            MIDIObjectSetStringProperty(endpoint, kMIDIPropertyManufacturer, "Roland" as CFString)
            MIDIObjectSetStringProperty(endpoint, kMIDIPropertyModel, "UM-ONE" as CFString)
            let uniqueID = MIDIUniqueID(bitPattern: 0x554D_3100 | UInt32(index) << 1 | UInt32(offset))
            let result = MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, uniqueID)
            if result != noErr {
                log.error("\(self.name, privacy: .public) uniqueID \(uniqueID) rejected: \(result)")
            }
        }
        setOffline(true)
        log.info("created \(self.name, privacy: .public) for location \(String(format: "0x%08x", locationID), privacy: .public)")
    }

    deinit {
        MIDIEndpointDispose(source)
        MIDIEndpointDispose(destination)
    }

    public var state: State { lock.withLock { _state } }

    func setState(_ state: State) {
        lock.withLock { _state = state }
    }

    func rebind(to location: UInt32) {
        lock.withLock { _locationID = location }
    }

    /// Wires `connection` to this port. Returns false if it already closed.
    func attach(_ connection: UMOneConnection, onClose: @escaping (String) -> Void) -> Bool {
        let alive = connection.queue.sync {
            guard !connection.isClosed else { return false }
            connection.onClose = onClose
            inbound = USBToUMPConverter()
            connection.onInput = { [weak self] bytes, time in self?.receive(bytes, time: time) }
            connection.rawObserver = { [weak self] direction, bytes in self?.logRaw(direction, bytes) }
            return true
        }
        guard alive else { return false }
        lock.withLock {
            self.connection = connection
            outbound = UMPToUSBConverter()
            _state = .connected
        }
        setOffline(false)
        return true
    }

    /// Detaches `connection` if it is still the current one; a replacement may already be attached.
    func detach(_ connection: UMOneConnection, reason: String) {
        let wasCurrent = lock.withLock {
            guard self.connection === connection else { return false }
            self.connection = nil
            if _state == .connected { _state = .waiting }
            return true
        }
        guard wasCurrent else {
            log.notice("\(self.name, privacy: .public) stale connection closed: \(reason, privacy: .public)")
            return
        }
        setOffline(true)
        log.notice("\(self.name, privacy: .public) detached: \(reason, privacy: .public)")
    }

    private func setOffline(_ offline: Bool) {
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyOffline, offline ? 1 : 0)
        MIDIObjectSetIntegerProperty(destination, kMIDIPropertyOffline, offline ? 1 : 0)
    }

    /// USB → virtual source. Runs on the connection queue.
    private func receive(_ bytes: UnsafeRawBufferPointer, time: MIDITimeStamp) {
        inboundWords.removeAll(keepingCapacity: true)
        inbound.convert(bytes, into: &inboundWords)
        guard !inboundWords.isEmpty else { return }
        messagesIn.add(USBMIDI.countMessages(inboundWords), ordering: .relaxed)

        // A 64-byte transfer yields at most 16 UMP words, but stay generic.
        let byteCount = MemoryLayout<MIDIEventList>.size + inboundWords.count * 4 + 64
        withUnsafeTemporaryAllocation(byteCount: byteCount, alignment: MemoryLayout<MIDIEventList>.alignment) { raw in
            let list = raw.baseAddress!.assumingMemoryBound(to: MIDIEventList.self)
            var packet = MIDIEventListInit(list, ._1_0)
            var i = 0
            while i < inboundWords.count {
                let n = USBMIDI.umpWordCount(inboundWords[i])
                packet = inboundWords.withUnsafeBufferPointer {
                    MIDIEventListAdd(list, byteCount, packet, time, n, $0.baseAddress! + i)
                }
                i += n
            }
            let status = MIDIReceivedEventList(source, list)
            if status != noErr { log.error("\(self.name, privacy: .public) MIDIReceivedEventList: \(status)") }
        }
    }

    /// Virtual destination → USB. Runs on a CoreMIDI thread.
    private func send(_ list: UnsafePointer<MIDIEventList>) {
        var bytes: [UInt8] = []
        lock.lock()
        let connection = self.connection
        if connection != nil {
            for packet in list.unsafeSequence() {
                let words = MIDIEventPacket.WordCollection(packet)
                outbound.convert(words, into: &bytes)
                messagesOut.add(USBMIDI.countMessages(words), ordering: .relaxed)
            }
        }
        lock.unlock()
        connection?.send(bytes)
    }

    private func logRaw(_ direction: UMOneConnection.Direction, _ bytes: UnsafeRawBufferPointer) {
        guard options.verbose.load(ordering: .relaxed) else { return }
        let arrow = direction == .input ? "IN " : "OUT"
        var i = 0
        while i + 4 <= bytes.count {
            let p = (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
            if p != (0, 0, 0, 0) {
                rawLog.notice("\(self.name, privacy: .public) \(arrow, privacy: .public) \(USBMIDI.describe(p), privacy: .public)")
            }
            i += 4
        }
    }
}

/// Runtime switches shared by every port.
public final class BridgeOptions: Sendable {
    public let verbose = Atomic<Bool>(false)
    public init() {}
}

struct MIDIError: Error, CustomStringConvertible {
    let function: String
    let status: OSStatus
    var description: String { "\(function) failed: \(status)" }
}

func check(_ status: OSStatus, _ function: String) throws {
    if status != noErr { throw MIDIError(function: function, status: status) }
}
