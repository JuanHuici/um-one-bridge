import Testing
@testable import UMOneCore

@Suite struct PortSlotsTests {
    @Test func knownLocationKeepsItsSlot() {
        var slots = PortSlots(byLocation: [0xA: 1, 0xB: 2])
        #expect(slots.assign(0xB, busy: []) == (2, nil))
        #expect(slots.byLocation == [0xA: 1, 0xB: 2])
    }

    @Test func movedDeviceTakesTheFreeSlot() {
        var slots = PortSlots(byLocation: [0xA: 1, 0xB: 2])
        #expect(slots.assign(0xC, busy: [0xA, 0xC]) == (2, 0xB))
        #expect(slots.byLocation == [0xA: 1, 0xC: 2])
    }

    @Test func lowestFreeSlotWins() {
        var slots = PortSlots(byLocation: [0xA: 1, 0xB: 2])
        #expect(slots.assign(0xC, busy: [0xC]) == (1, 0xA))
    }

    @Test func extraDeviceGetsANewSlot() {
        var slots = PortSlots(byLocation: [0xA: 1, 0xB: 2])
        #expect(slots.assign(0xC, busy: [0xA, 0xB, 0xC]) == (3, nil))
        #expect(slots.byLocation == [0xA: 1, 0xB: 2, 0xC: 3])
    }

    @Test func firstDevicesCountFromOne() {
        var slots = PortSlots(byLocation: [:])
        #expect(slots.assign(0xB, busy: [0xA, 0xB]) == (1, nil))
        #expect(slots.assign(0xA, busy: [0xA, 0xB]) == (2, nil))
    }
}
