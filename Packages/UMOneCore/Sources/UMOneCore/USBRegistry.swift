import Foundation
import IOKit
import IOUSBHost

/// Constants and IORegistry helpers for the original Roland UM-ONE.
public enum UMOne {
    public static let vendorID = 0x0582
    public static let productID = 0x012A
    public static let configurationValue = 1
    public static let interfaceNumber = 0
    public static let bulkInAddress = 0x81
    public static let bulkOutAddress = 0x02

    public static func deviceMatching() -> CFMutableDictionary {
        IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: vendorID as NSNumber, productID: productID as NSNumber,
            bcdDevice: nil, deviceClass: nil, deviceSubclass: nil, deviceProtocol: nil,
            speed: nil, productIDArray: nil
        ).takeRetainedValue()
    }

    public static func interfaceMatching() -> CFMutableDictionary {
        IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: vendorID as NSNumber, productID: productID as NSNumber,
            bcdDevice: nil, interfaceNumber: interfaceNumber as NSNumber,
            configurationValue: configurationValue as NSNumber, interfaceClass: nil,
            interfaceSubclass: nil, interfaceProtocol: nil, speed: nil, productIDArray: nil
        ).takeRetainedValue()
    }
}

public enum Registry {
    /// Reads an integer property, searching parents when `recursive` (interfaces inherit
    /// `locationID` from their device).
    public static func intProperty(_ service: io_service_t, _ key: String, recursive: Bool = false) -> Int? {
        let options: IOOptionBits = recursive
            ? IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents) : 0
        let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                                                    kCFAllocatorDefault, options)
        return (value as? NSNumber)?.intValue
    }

    public static func locationID(_ service: io_service_t) -> UInt32? {
        intProperty(service, "locationID", recursive: true).map { UInt32(truncatingIfNeeded: $0) }
    }

    public static func registryID(_ service: io_service_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        return id
    }

    /// All currently registered services matching `dictionary`. Caller releases them.
    public static func services(matching dictionary: CFDictionary) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dictionary, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        return drain(iterator)
    }

    public static func drain(_ iterator: io_iterator_t) -> [io_service_t] {
        var result: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            result.append(service)
        }
        return result
    }

    /// Children of `service` in the service plane whose class conforms to `className`.
    public static func children(of service: io_service_t, conformingTo className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        return drain(iterator).filter { child in
            if IOObjectConformsTo(child, className) != 0 { return true }
            IOObjectRelease(child)
            return false
        }
    }
}

/// `kUSBHostReturnPipeStalled` (IOUSBHostFamilyDefinitions.h); the macro is not imported into Swift.
public let kUSBHostReturnPipeStalledStatus = IOReturn(bitPattern: 0xE000_5000)
/// Legacy `kIOUSBPipeStalled`, `iokit_usb_err(0x4f)`.
public let kIOUSBPipeStalledStatus = IOReturn(bitPattern: 0xE000_404F)

public func ioReturnString(_ status: IOReturn) -> String {
    let known: [IOReturn: String] = [
        kIOReturnSuccess: "success", kIOReturnAborted: "aborted", kIOReturnNoDevice: "no device",
        kIOReturnNotResponding: "not responding", kIOReturnExclusiveAccess: "exclusive access",
        kIOReturnTimeout: "timeout", kIOReturnOverrun: "overrun", kIOReturnNotOpen: "not open",
        kIOReturnOffline: "offline", kIOReturnNotPermitted: "not permitted",
        kIOReturnNotPrivileged: "not privileged", kUSBHostReturnPipeStalledStatus: "pipe stalled", kIOUSBPipeStalledStatus: "pipe stalled (legacy)",
    ]
    let hex = String(format: "0x%08x", UInt32(bitPattern: status))
    return known[status].map { "\($0) (\(hex))" } ?? hex
}
