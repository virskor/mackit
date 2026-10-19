import CoreGraphics
import Darwin
import Foundation
import IOKit

/// What this machine is: model, system version, disk, processor, graphics
/// card, memory, battery, display.
///
/// Division of labor with `SystemStats`: that one records "the load at
/// this moment", changing continuously with polling; this one is static
/// information that stops changing once set up, so it is sampled once
/// when entering the hardware page. All fields have default values, so
/// when a single item fails to be collected that item displays "—",
/// without dragging the whole page blank.
struct HardwareProfile: Equatable, Sendable {
    /// Marketing name, e.g. "MacBook Air". Degrades to the model
    /// identifier when unavailable.
    var modelName: String = ""
    /// Model identifier, e.g. Mac14,15.
    var modelIdentifier: String = ""
    /// System version, e.g. 27.0.1.
    var osVersion: String = ""
    /// System build number, e.g. 26A434.
    var osBuild: String = ""
    /// Boot volume (data volume) name, e.g. "Macintosh HD".
    var diskName: String = ""
    /// Volume available space, in bytes.
    var diskAvailable: Int64 = 0
    /// Total volume space, in bytes.
    var diskTotal: Int64 = 0
    /// Processor name, e.g. Apple M2.
    var cpuName: String = ""
    /// Core description, e.g. "8 (4 performance + 4 efficiency)".
    var cpuCores: String = ""
    /// Graphics card name, e.g. Apple M2.
    var gpuName: String = ""
    /// Physical memory, in bytes.
    var memoryBytes: Int64 = 0
    /// Display resolution, e.g. "2880x1864".
    var displayResolution: String = ""
    /// Whether there is a battery. Desktops have none, and the page hides
    /// the entire row accordingly.
    var hasBattery: Bool = false
    /// Current charge level, 0...1.
    var batteryLevel: Double = 0
    /// Cycle charge count.
    var batteryCycles: Int = 0
    /// Health: full-charge capacity / design capacity, 0...1.
    var batteryHealth: Double = 0
    /// Whether it is currently charging.
    var batteryCharging: Bool = false

    /// The status corresponding to the health.
    var batteryHealthStatus: BatteryHealthStatus {
        Self.healthStatus(batteryHealth)
    }

    /// Takes the marketing name from product-name in the device tree.
    ///
    /// The registry gives "MacBook Air (15-inch, M2, 2023)", while the
    /// page title only wants "MacBook Air"—the parentheses hold the size
    /// and year, and the same series shares one title across different
    /// configurations, consistent with the display in the system's
    /// "About This Mac".
    static func baseName(fromProductName name: String) -> String {
        guard let range = name.range(of: " (") else { return name }
        return String(name[..<range.lowerBound])
    }

    /// Health → status. The 80% line is the same threshold at which the
    /// system's "Battery Health" advises attention.
    static func healthStatus(_ health: Double) -> BatteryHealthStatus {
        health >= 0.8 ? .normal : .serviceRecommended
    }
}

/// Battery health status.
enum BatteryHealthStatus: String, Sendable {
    case normal
    case serviceRecommended

    var title: String {
        L10n.tr("hw.battery.\(rawValue)")
    }
}

/// Hardware information sampling. All via public interfaces: sysctl,
/// IORegistry, URL resource values.
///
/// Why not something like MobileGestalt: the cost of a private interface
/// breaking with a system version is the entire block of hardware
/// information disappearing, which is not worth gambling on to save one
/// registry read (giving up SMC temperature reads in `SystemStats` is the
/// same judgment).
enum HardwareSampler {
    /// Samples one hardware profile. A failure in any single item only
    /// makes that item display "—".
    static func profile() -> HardwareProfile {
        var profile = HardwareProfile()

        let identifier = sysctlString("hw.model") ?? ""
        profile.modelIdentifier = identifier
        if !identifier.isEmpty {
            profile.modelName = marketingName(identifier: identifier)
                ?? identifier
        }

        profile.osVersion = sysctlString("kern.osproductversion") ?? ""
        profile.osBuild = sysctlString("kern.osversion") ?? ""

        // Physical memory has no sysctl to read; ProcessInfo is the
        // system's own measure (same source as the total memory in
        // `SystemStats`).
        profile.memoryBytes = Int64(ProcessInfo.processInfo.physicalMemory)

        applyDisk(to: &profile)
        applyProcessor(to: &profile)
        applyGraphics(to: &profile)
        applyDisplay(to: &profile)
        applyBattery(to: &profile)

        return profile
    }

    // MARK: - Model

    /// Marketing name, e.g. "MacBook Air". Returns nil when unavailable;
    /// the caller degrades to the model identifier.
    ///
    /// The source is the product-name attribute of the `product` node in
    /// the device tree—the system itself uses it to fill in "About This
    /// Mac". macOS has no API that directly gives the marketing name;
    /// system_profiler can also get it but takes a few seconds; this
    /// attribute is a single instant registry read. If a future
    /// generation renames the attribute, the page falls back to
    /// displaying "Mac14,15", and nothing else is affected.
    static func marketingName(identifier: String) -> String? {
        var iterator = io_iterator_t(0)
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceNameMatching("product"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        // Each iteration binds a new constant, so defer therefore always
        // releases the current one; writing it as `var service` plus
        // reassignment at the end of the loop would make defer release the
        // next service.
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            // Only accept it when the identifier matches: the registry may
            // contain other product nodes.
            let subType = stringProperty(service, "sub-product-type")
            if identifier.isEmpty || subType == identifier,
               let name = stringProperty(service, "product-name"), !name.isEmpty {
                return HardwareProfile.baseName(fromProductName: name)
            }
        }
        return nil
    }

    // MARK: - Disk

    /// The name and capacity of the boot volume. Same source as the
    /// sidebar storage bar (the volume containing the home directory).
    private static func applyDisk(to profile: inout HardwareProfile) {
        let url = FileSystem.url("~")
        guard let values = try? url.resourceValues(
            forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        ) else { return }
        profile.diskName = values.volumeName ?? ""
        profile.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        profile.diskAvailable = Int64(values.volumeAvailableCapacity ?? 0)
    }

    // MARK: - Processor

    private static func applyProcessor(to profile: inout HardwareProfile) {
        profile.cpuName = sysctlString("machdep.cpu.brand_string") ?? ""
        profile.cpuCores = coresDescription()
    }

    /// Core description. Apple Silicon splits into performance /
    /// efficiency clusters; writing them separately is what makes it
    /// informative; Intel and cases where cluster info is unavailable
    /// report only the total core count.
    private static func coresDescription() -> String {
        let total = sysctlInt("hw.physicalcpu") ?? sysctlInt("hw.ncpu")
        guard let total, total > 0 else { return "" }

        // Only Apple Silicon has perflevel nodes; two clusters
        // (performance + efficiency) are its standard form; when the count
        // does not match (three-cluster new chips) report only the total,
        // without forcing the format.
        let levels = sysctlInt("hw.nperflevels") ?? 0
        if levels == 2,
           sysctlString("hw.perflevel0.name") == "Performance",
           sysctlString("hw.perflevel1.name") == "Efficiency",
           let performance = sysctlInt("hw.perflevel0.physicalcpu"),
           let efficiency = sysctlInt("hw.perflevel1.physicalcpu"),
           performance > 0, efficiency > 0, performance + efficiency == total {
            return L10n.fmt("hw.cpu.coresSplit", total, performance, efficiency)
        }
        return L10n.fmt("hw.cpu.cores", total)
    }

    // MARK: - Graphics

    private static func applyGraphics(to profile: inout HardwareProfile) {
        // The GPU name is in the model attribute of the IOAccelerator
        // service (published by both Apple Silicon and Intel). A machine
        // may have multiple accelerators (discrete + integrated); take the
        // first one with a name; if unavailable, fall back to the processor
        // name—on Apple Silicon the two are the same chip anyway.
        profile.gpuName = acceleratorModel() ?? profile.cpuName
    }

    private static func acceleratorModel() -> String? {
        var iterator = io_iterator_t(0)
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if let model = stringProperty(service, "model"), !model.isEmpty { return model }
        }
        return nil
    }

    // MARK: - Display

    /// Display resolution. Takes the built-in display's panel native
    /// resolution; desktops have no built-in display, so fall back to the
    /// main display.
    ///
    /// Not the current mode: when the user changes the scaling tier in
    /// System Settings, the rendered resolution becomes twice the panel's
    /// (then downsampled back to the panel); what the page should report
    /// is the panel itself, consistent with "Resolution" in System
    /// Information. The one with the most pixels among the 1× modes is the
    /// native resolution.
    private static func applyDisplay(to profile: inout HardwareProfile) {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return }

        // CGDisplayIsBuiltin returns boolean_t (Int32), not Bool.
        let target = displays.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
        guard let modes = CGDisplayCopyAllDisplayModes(target, nil) as? [CGDisplayMode] else { return }

        // width == pixelWidth means 1× mode; a HiDPI mode has twice as many
        // pixels as points. The one with the most pixels among the 1× modes
        // is the panel's native resolution; only when there are none (in
        // theory a machine with a HiDPI-only display) fall back to the
        // current mode.
        let oneX = modes.filter { $0.width == $0.pixelWidth }
        if let native = oneX.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) {
            profile.displayResolution = "\(native.pixelWidth)x\(native.pixelHeight)"
        } else if let current = CGDisplayCopyDisplayMode(target) {
            profile.displayResolution = "\(current.pixelWidth)x\(current.pixelHeight)"
        }
    }

    // MARK: - Battery

    /// Battery: charge level, cycle count, health.
    ///
    /// Goes through the AppleSmartBattery service in IORegistry rather
    /// than IOPS: cycle count and design capacity exist only in the
    /// registry. Desktops do not have this service, so the entire row of
    /// data is left empty.
    private static func applyBattery(to profile: inout HardwareProfile) {
        var iterator = io_iterator_t(0)
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"), &iterator
        ) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard boolProperty(service, "BatteryInstalled") == true else { continue }

            profile.hasBattery = true
            let level = intProperty(service, "CurrentCapacity") ?? 0
            profile.batteryLevel = min(1, max(0, Double(level) / 100))
            profile.batteryCycles = intProperty(service, "CycleCount") ?? 0
            profile.batteryCharging = boolProperty(service, "IsCharging") ?? false

            // Health = full-charge capacity / design capacity, the same
            // measure as the system's "Battery Health".
            let data = dictionaryProperty(service, "BatteryData")
            let fullCharge = data?["FullChargeCapacity"] as? Int ?? 0
            let design = data?["DesignCapacity"] as? Int ?? 0
            if design > 0 {
                profile.batteryHealth = min(1, max(0, Double(fullCharge) / Double(design)))
            }
            return
        }
    }

    // MARK: - System Interfaces

    /// Reads a string-type sysctl; returns nil when the key does not
    /// exist.
    private static func sysctlString(_ name: String) -> String? {
        var size = size_t(0)
        // The first pass asks only for the length: if the length cannot be
        // obtained, the buffer size is not guessed.
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // The kernel appends \0 at the end of the value; decode as UTF-8 up
        // to the terminator
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads an integer-type sysctl.
    ///
    /// The buffer is given as 8 bytes: sysctl integer values come in both
    /// 4-byte and 8-byte; too small and the kernel rejects it with
    /// ENOMEM; too large and the kernel fills per the actual size and
    /// writes back the real length, so either way it can be read.
    private static func sysctlInt(_ name: String) -> Int? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// Reads a registry string property. Strings in the device tree are
    /// often stored as OSData (null-terminated C strings), so both
    /// carriers must be accepted.
    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        let value = raw.takeRetainedValue()
        if let string = value as? String { return string }
        if let data = value as? Data, !data.isEmpty {
            return data.withUnsafeBytes { pointer in
                guard let base = pointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
                // String properties in the device tree are stored as OSData
                // terminated by \0; decode as UTF-8 up to the terminator
                let bytes = UnsafeBufferPointer(start: base, count: data.count).prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        return nil
    }

    /// Reads a registry integer property.
    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (raw.takeRetainedValue() as? NSNumber)?.intValue
    }

    /// Reads a registry boolean property.
    private static func boolProperty(_ service: io_service_t, _ key: String) -> Bool? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (raw.takeRetainedValue() as? NSNumber)?.boolValue
    }

    /// Reads a registry dictionary property.
    private static func dictionaryProperty(
        _ service: io_service_t, _ key: String
    ) -> [String: Any]? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return raw.takeRetainedValue() as? [String: Any]
    }
}
