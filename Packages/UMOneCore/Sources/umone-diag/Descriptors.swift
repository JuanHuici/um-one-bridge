import Foundation
import IOKit
import IOUSBHost
import UMOneCore

/// `--descriptors`: open each UM-ONE, print its descriptors, select configuration 1,
/// open interface 0 and its two pipes, then close everything again.
func runDescriptors(location: UInt32?) -> Int32 {
    let devices = Registry.services(matching: UMOne.deviceMatching())
    print("Found \(devices.count) UM-ONE device(s)")
    var failures: Int32 = 0
    for service in devices {
        defer { IOObjectRelease(service) }
        let loc = Registry.locationID(service) ?? 0
        if let location, location != loc { continue }
        print("\n=== UM-ONE @ \(hex32(loc))  registryID \(String(format: "0x%llx", Registry.registryID(service)))")
        if let current = Registry.intProperty(service, "kUSBCurrentConfiguration") {
            print("kUSBCurrentConfiguration = \(current)")
        } else {
            print("kUSBCurrentConfiguration = (none, device unconfigured)")
        }
        do {
            try probe(service)
        } catch {
            failures += 1
            print("FAILED: \(describe(error))")
        }
    }
    return failures == 0 ? 0 : 1
}

private func probe(_ service: io_service_t) throws {
    let queue = DispatchQueue(label: "umone-diag.device")
    print("Opening IOUSBHostDevice (options: none)…")
    let device = try IOUSBHostDevice(__ioService: service, options: [], queue: queue, interestHandler: nil)
    defer { device.destroy() }
    print("  opened, address \(device.deviceAddress)")

    if let dd = device.deviceDescriptor?.pointee {
        print(String(format: "  Device: bcdUSB %04x class %02x/%02x/%02x maxPacket0 %d VID %04x PID %04x bcdDevice %04x configs %d",
                     dd.bcdUSB, dd.bDeviceClass, dd.bDeviceSubClass, dd.bDeviceProtocol, dd.bMaxPacketSize0,
                     dd.idVendor, dd.idProduct, dd.bcdDevice, dd.bNumConfigurations))
        for (label, index) in [("Manufacturer", dd.iManufacturer), ("Product", dd.iProduct), ("Serial", dd.iSerialNumber)] where index != 0 {
            let s = (try? device.__string(with: Int(index), languageID: 0x0409)) as String?
            print("  \(label): \(s ?? "?")")
        }
    }

    let config = try device.configurationDescriptor(withConfigurationValue: UMOne.configurationValue)
    dumpConfiguration(config)

    print("configure(\(UMOne.configurationValue), matchInterfaces: true)…")
    try device.__configure(withValue: UMOne.configurationValue, matchInterfaces: true)
    print("  ok")

    // Diagnostic only: the app waits for a matching notification instead of retrying.
    var interfaceService: io_service_t = 0
    for _ in 0..<40 where interfaceService == 0 {
        let children = Registry.children(of: service, conformingTo: "IOUSBHostInterface")
        for child in children {
            if interfaceService == 0, Registry.intProperty(child, "bInterfaceNumber") == UMOne.interfaceNumber {
                interfaceService = child
            } else {
                IOObjectRelease(child)
            }
        }
        if interfaceService == 0 { Thread.sleep(forTimeInterval: 0.05) }
    }
    guard interfaceService != 0 else {
        print("  interface 0 did not appear")
        throw NSError(domain: IOUSBHostErrorDomain, code: Int(kIOReturnNotFound))
    }
    defer { IOObjectRelease(interfaceService) }

    print("Opening IOUSBHostInterface 0…")
    let interface = try IOUSBHostInterface(__ioService: interfaceService, options: [], queue: queue, interestHandler: nil)
    defer { interface.destroy() }
    let id = interface.interfaceDescriptor.pointee
    print(String(format: "  interface %d alt %d endpoints %d class %02x/%02x/%02x",
                 id.bInterfaceNumber, id.bAlternateSetting, id.bNumEndpoints,
                 id.bInterfaceClass, id.bInterfaceSubClass, id.bInterfaceProtocol))
    for address in [UMOne.bulkInAddress, UMOne.bulkOutAddress] {
        let pipe = try interface.copyPipe(withAddress: address)
        let ep = pipe.descriptors.pointee.descriptor
        print(String(format: "  pipe 0x%02x: attributes %02x wMaxPacketSize %d bInterval %d",
                     ep.bEndpointAddress, ep.bmAttributes, ep.wMaxPacketSize, ep.bInterval))
    }
    print("Closing.")
}

private func dumpConfiguration(_ config: UnsafePointer<IOUSBConfigurationDescriptor>) {
    let total = Int(config.pointee.wTotalLength)
    let bytes = UnsafeRawBufferPointer(start: config, count: total)
    print("  Configuration descriptor (\(total) bytes): \(hexString(Array(bytes)))")
    var offset = 0
    while offset + 2 <= total {
        let length = Int(bytes[offset]), type = bytes[offset + 1]
        guard length >= 2, offset + length <= total else { break }
        let d = Array(bytes[offset..<offset + length])
        switch type {
        case 0x02:
            print(String(format: "    CONFIG value %d interfaces %d attributes %02x maxPower %dmA",
                         d[5], d[4], d[7], Int(d[8]) * 2))
        case 0x04:
            print(String(format: "    INTERFACE %d alt %d endpoints %d class %02x/%02x/%02x",
                         d[2], d[3], d[4], d[5], d[6], d[7]))
        case 0x05:
            let kinds = ["control", "isochronous", "bulk", "interrupt"]
            print(String(format: "    ENDPOINT 0x%02x %@ maxPacket %d interval %d",
                         d[2], kinds[Int(d[3] & 3)], Int(d[4]) | Int(d[5]) << 8, d[6]))
        default:
            print(String(format: "    descriptor type 0x%02x: %@", type, hexString(d)))
        }
        offset += length
    }
}

/// `--reset`: USB-reset the device so it re-enumerates, which exercises the same path as
/// unplugging and replugging it.
func runReset(location: UInt32?) -> Int32 {
    var failures: Int32 = 0
    for service in Registry.services(matching: UMOne.deviceMatching()) {
        defer { IOObjectRelease(service) }
        let loc = Registry.locationID(service) ?? 0
        if let location, location != loc { continue }
        do {
            let device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            try device.reset()
            print("\(hex32(loc)) reset, re-enumerating")
        } catch {
            failures += 1
            print("\(hex32(loc)) reset FAILED: \(describe(error))")
        }
    }
    return failures == 0 ? 0 : 1
}
