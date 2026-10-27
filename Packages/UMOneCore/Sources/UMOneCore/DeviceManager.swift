import Foundation
import IOKit
import IOUSBHost
import os

/// Watches IOKit for UM-ONE devices and their interface 0.
///
/// A device that appears unconfigured is configured (SET_CONFIGURATION 1) and released; the
/// interface it then publishes arrives through the second notification and is opened as a
/// `UMOneConnection`. All callbacks run on `queue`.
public final class DeviceManager: @unchecked Sendable {
    public enum Event: Sendable {
        /// A UM-ONE is present at this location (configured or not yet).
        case deviceArrived(locationID: UInt32)
        case deviceRemoved(locationID: UInt32)
        case connected(UMOneConnection)
        case failed(locationID: UInt32, message: String)
    }

    public let queue = DispatchQueue(label: "umone.hotplug")
    private let handler: @Sendable (Event) -> Void
    private let log = Logger(subsystem: Log.subsystem, category: "hotplug")

    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    /// Locations with an open connection, so a re-delivered interface is not opened twice.
    private var openLocations: Set<UInt32> = []

    public init(handler: @escaping @Sendable (Event) -> Void) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() {
        queue.async { [self] in
            guard port == nil else { return }
            let port = IONotificationPortCreate(kIOMainPortDefault)
            IONotificationPortSetDispatchQueue(port, queue)
            self.port = port
            addNotification(kIOFirstMatchNotification, UMOne.deviceMatching()) { $0.devicesArrived($1) }
            addNotification(kIOTerminatedNotification, UMOne.deviceMatching()) { $0.devicesRemoved($1) }
            addNotification(kIOFirstMatchNotification, UMOne.interfaceMatching()) { $0.interfacesArrived($1) }
            log.info("watching for UM-ONE 0582:012A")
        }
    }

    public func stop() {
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators.removeAll()
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    /// Called by the owner when a connection it received has closed.
    public func connectionClosed(locationID: UInt32) {
        queue.async { [self] in openLocations.remove(locationID) }
    }

    private typealias Arrival = (DeviceManager, io_iterator_t) -> Void

    private final class Box {
        let arrival: Arrival
        weak var manager: DeviceManager?
        init(_ arrival: @escaping Arrival, _ manager: DeviceManager) {
            self.arrival = arrival
            self.manager = manager
        }
    }
    private var boxes: [Box] = []

    private func addNotification(_ type: String, _ matching: CFMutableDictionary, _ arrival: @escaping Arrival) {
        let box = Box(arrival, self)
        boxes.append(box)
        var iterator: io_iterator_t = 0
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            let box = Unmanaged<Box>.fromOpaque(refcon!).takeUnretainedValue()
            guard let manager = box.manager else { _ = Registry.drain(iterator).map(IOObjectRelease); return }
            box.arrival(manager, iterator)
        }
        let kr = IOServiceAddMatchingNotification(port, type, matching, callback,
                                                  Unmanaged.passUnretained(box).toOpaque(), &iterator)
        guard kr == KERN_SUCCESS else {
            log.error("IOServiceAddMatchingNotification(\(type, privacy: .public)) failed: \(kr)")
            return
        }
        iterators.append(iterator)
        // Arm the notification and handle what is already present.
        arrival(self, iterator)
    }

    private func devicesArrived(_ iterator: io_iterator_t) {
        for service in Registry.drain(iterator) {
            defer { IOObjectRelease(service) }
            guard let location = Registry.locationID(service) else { continue }
            handler(.deviceArrived(locationID: location))
            if Registry.intProperty(service, "kUSBCurrentConfiguration") == UMOne.configurationValue {
                log.info("\(Self.tag(location), privacy: .public) already configured")
                continue
            }
            configure(service, location: location)
        }
    }

    /// Right after enumeration other user clients may hold the device open for a moment, so
    /// `kIOReturnExclusiveAccess` is retried with backoff.
    private static let configureRetryDelays: [Double] = [0.1, 0.25, 0.5, 1, 2, 4]

    private func configure(_ service: io_service_t, location: UInt32, attempt: Int = 0) {
        do {
            let device = try IOUSBHostDevice(__ioService: service, options: [], queue: queue, interestHandler: nil)
            defer { device.destroy() }
            try device.__configure(withValue: UMOne.configurationValue, matchInterfaces: true)
            log.info("\(Self.tag(location), privacy: .public) configured")
        } catch {
            let status = IOReturn(truncatingIfNeeded: (error as NSError).code)
            if status == kIOReturnExclusiveAccess, attempt < Self.configureRetryDelays.count {
                let delay = Self.configureRetryDelays[attempt]
                log.info("\(Self.tag(location), privacy: .public) busy, retrying configure in \(delay)s")
                IOObjectRetain(service)
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    defer { IOObjectRelease(service) }
                    guard let self, IOObjectConformsTo(service, "IOUSBHostDevice") != 0,
                          Registry.intProperty(service, "kUSBCurrentConfiguration") != UMOne.configurationValue
                    else { return }
                    configure(service, location: location, attempt: attempt + 1)
                }
                return
            }
            let message = "configure failed: \(describeIOError(error))"
            log.error("\(Self.tag(location), privacy: .public) \(message, privacy: .public)")
            handler(.failed(locationID: location, message: message))
        }
    }

    private func devicesRemoved(_ iterator: io_iterator_t) {
        for service in Registry.drain(iterator) {
            defer { IOObjectRelease(service) }
            // The registry may already have dropped the parent link; fall back to the device's own property.
            guard let location = Registry.locationID(service) else { continue }
            log.info("\(Self.tag(location), privacy: .public) removed")
            handler(.deviceRemoved(locationID: location))
        }
    }

    private func interfacesArrived(_ iterator: io_iterator_t) {
        for service in Registry.drain(iterator) {
            defer { IOObjectRelease(service) }
            guard let location = Registry.locationID(service), !openLocations.contains(location) else { continue }
            do {
                let connection = try UMOneConnection(interfaceService: service, locationID: location)
                openLocations.insert(location)
                log.info("\(Self.tag(location), privacy: .public) interface opened")
                handler(.connected(connection))
            } catch {
                let message = "open interface failed: \(describeIOError(error))"
                log.error("\(Self.tag(location), privacy: .public) \(message, privacy: .public)")
                handler(.failed(locationID: location, message: message))
            }
        }
    }

    static func tag(_ location: UInt32) -> String { String(format: "[%08x]", location) }
}

public func describeIOError(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == IOUSBHostErrorDomain || ns.domain == NSMachErrorDomain {
        return ioReturnString(IOReturn(truncatingIfNeeded: ns.code))
    }
    return "\(ns.domain) \(ns.code)"
}
