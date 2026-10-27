import Foundation
import IOKit
import IOUSBHost
import os

/// `iokit_common_msg(0x010)`; the macro is not imported into Swift.
let kIOMessageServiceIsTerminatedValue: UInt32 = 0xE000_0010

/// An open interface 0 of one UM-ONE with its bulk pipes.
///
/// All state is confined to `queue`, which is also the IOUSBHost I/O queue, so completion
/// handlers run there. `send` may be called from any thread.
public final class UMOneConnection: @unchecked Sendable {
    public enum Direction: Sendable { case input, output }

    public let locationID: UInt32
    public let queue: DispatchQueue

    /// Called on `queue` with the bytes of every completed bulk IN transfer and its host time.
    public var onInput: ((UnsafeRawBufferPointer, UInt64) -> Void)?
    /// Called on `queue` once, when the interface goes away or I/O fails permanently.
    public var onClose: ((String) -> Void)?
    /// Called on `queue` for every completed transfer; used by the verbose/diagnostic mode.
    public var rawObserver: ((Direction, UnsafeRawBufferPointer) -> Void)?

    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    private let maxPacket: Int
    private let log = Logger(subsystem: Log.subsystem, category: "usb")

    private static let readsInFlight = 4
    private static let maxQueuedOutput = 256 * 1024
    private static let writeTimeout: TimeInterval = 2

    private var readBuffers: [NSMutableData] = []
    private var outQueue: [UInt8] = []
    private var writeInFlight = false
    private var writeChunk: NSMutableData?
    private var closed = false

    /// Whether `close` has run. Read on `queue`.
    public var isClosed: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return closed
    }
    private var consecutiveReadErrors = 0

    /// Opens `interfaceService` (an IOUSBHostInterface, interface 0) and both pipes.
    public init(interfaceService: io_service_t, locationID: UInt32) throws {
        self.locationID = locationID
        queue = DispatchQueue(label: String(format: "umone.usb.%08x", locationID), qos: .userInteractive)

        // The interest handler runs on an internal queue; it only needs a weak hop to ours.
        let owner = WeakBox<UMOneConnection>()
        interface = try IOUSBHostInterface(
            __ioService: interfaceService, options: [], queue: queue,
            interestHandler: { _, messageType, _ in
                guard messageType == kIOMessageServiceIsTerminatedValue, let connection = owner.value else { return }
                connection.queue.async { connection.close(reason: "interface terminated") }
            })
        do {
            inPipe = try interface.copyPipe(withAddress: UMOne.bulkInAddress)
            outPipe = try interface.copyPipe(withAddress: UMOne.bulkOutAddress)
        } catch {
            interface.destroy()
            throw error
        }
        maxPacket = max(4, Int(inPipe.descriptors.pointee.descriptor.wMaxPacketSize))
        owner.value = self
    }

    deinit {
        interface.destroy()
    }

    /// Starts the continuous asynchronous reads on 0x81.
    public func start() {
        queue.async { [self] in
            guard !closed else { return }
            do {
                for index in 0..<Self.readsInFlight {
                    readBuffers.append(try interface.ioData(withCapacity: maxPacket))
                    try enqueueRead(index)
                }
                log.info("\(self.tag, privacy: .public) reading, wMaxPacketSize \(self.maxPacket)")
            } catch {
                close(reason: "could not start reads: \(error.localizedDescription)")
            }
        }
    }

    /// Queues already-encoded USB-MIDI packets for bulk OUT 0x02.
    public func send(_ packets: [UInt8]) {
        guard !packets.isEmpty else { return }
        queue.async { [self] in
            guard !closed else { return }
            if outQueue.count + packets.count > Self.maxQueuedOutput {
                log.error("\(self.tag, privacy: .public) output queue full, dropping \(packets.count) bytes")
                return
            }
            outQueue.append(contentsOf: packets)
            pumpWrites()
        }
    }

    /// Aborts I/O and releases the interface. Safe to call more than once.
    public func close(reason: String = "closed") {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else { return }
        closed = true
        log.info("\(self.tag, privacy: .public) closing: \(reason, privacy: .public)")
        try? inPipe.__abort(with: .asynchronous)
        try? outPipe.__abort(with: .asynchronous)
        outQueue.removeAll()
        interface.destroy()
        onClose?(reason)
        onInput = nil
        onClose = nil
        rawObserver = nil
    }

    private var tag: String { String(format: "[%08x]", locationID) }

    private func enqueueRead(_ index: Int) throws {
        try inPipe.enqueueIORequest(with: readBuffers[index], completionTimeout: 0) { [weak self] status, count in
            // Completion handlers are delivered on `queue`.
            self?.readCompleted(index, status: status, count: count)
        }
    }

    private func readCompleted(_ index: Int, status: IOReturn, count: Int) {
        guard !closed else { return }
        let buffer = readBuffers[index]
        switch status {
        case kIOReturnSuccess:
            consecutiveReadErrors = 0
            let now = mach_absolute_time()
            let bytes = UnsafeRawBufferPointer(start: buffer.bytes, count: min(count, buffer.length))
            if !bytes.isEmpty {
                rawObserver?(.input, bytes)
                onInput?(bytes, now)
            }
        case kIOReturnAborted, kIOReturnNoDevice, kIOReturnNotResponding, kIOReturnOffline, kIOReturnNotOpen:
            close(reason: "read: \(ioReturnString(status))")
            return
        case kUSBHostReturnPipeStalledStatus, kIOUSBPipeStalledStatus:
            log.error("\(self.tag, privacy: .public) IN pipe stalled, clearing")
            try? inPipe.clearStall()
        default:
            consecutiveReadErrors += 1
            log.error("\(self.tag, privacy: .public) read error \(ioReturnString(status), privacy: .public)")
            if consecutiveReadErrors > 20 {
                close(reason: "too many read errors")
                return
            }
        }
        do {
            try enqueueRead(index)
        } catch {
            close(reason: "re-enqueue read: \(error.localizedDescription)")
        }
    }

    private func pumpWrites() {
        guard !writeInFlight, !closed, !outQueue.isEmpty else { return }
        let length = min(outQueue.count, maxPacket) & ~3
        guard length > 0 else { outQueue.removeAll(); return }
        let chunk = NSMutableData(bytes: outQueue, length: length)
        outQueue.removeFirst(length)
        writeInFlight = true
        writeChunk = chunk
        do {
            try outPipe.enqueueIORequest(with: chunk, completionTimeout: Self.writeTimeout) { [weak self] status, sent in
                self?.writeCompleted(status: status, sent: sent)
            }
        } catch {
            writeInFlight = false
            writeChunk = nil
            log.error("\(self.tag, privacy: .public) enqueue write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeCompleted(status: IOReturn, sent: Int) {
        writeInFlight = false
        guard !closed, let chunk = writeChunk else { return }
        writeChunk = nil
        switch status {
        case kIOReturnSuccess:
            rawObserver?(.output, UnsafeRawBufferPointer(start: chunk.bytes, count: sent))
        case kIOReturnAborted, kIOReturnNoDevice, kIOReturnNotResponding, kIOReturnOffline, kIOReturnNotOpen:
            close(reason: "write: \(ioReturnString(status))")
            return
        case kUSBHostReturnPipeStalledStatus, kIOUSBPipeStalledStatus:
            log.error("\(self.tag, privacy: .public) OUT pipe stalled, clearing")
            try? outPipe.clearStall()
        default:
            log.error("\(self.tag, privacy: .public) write error \(ioReturnString(status), privacy: .public), \(chunk.length) bytes dropped")
        }
        pumpWrites()
    }
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}

public enum Log {
    public static let subsystem = "com.juanhuici.umone-bridge"
}
