/// Which slot number ("UM-ONE n") each USB location uses.
///
/// The UM-ONE has no serial number, so a device on an unknown location can't be recognized. It
/// takes over the lowest slot whose location has nothing plugged in, which keeps the number of
/// slots equal to the number of devices when one is moved to another USB port.
struct PortSlots {
    var byLocation: [UInt32: Int]

    /// Returns the slot for `location`, and the location that slot was taken from, if any.
    /// `busy` holds the locations that have a device right now.
    mutating func assign(_ location: UInt32, busy: Set<UInt32>) -> (index: Int, replaced: UInt32?) {
        if let index = byLocation[location] { return (index, nil) }
        if let free = byLocation.filter({ !busy.contains($0.key) }).min(by: { $0.value < $1.value }) {
            byLocation[free.key] = nil
            byLocation[location] = free.value
            return (free.value, free.key)
        }
        let used = Set(byLocation.values)
        let index = (1...).first { !used.contains($0) }!
        byLocation[location] = index
        return (index, nil)
    }
}
