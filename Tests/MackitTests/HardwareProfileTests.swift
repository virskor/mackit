import Foundation
import Testing

@testable import Mackit

/// Collection of hardware information and derived values.
///
/// Same stance as `SystemStatsTests`: specific values are deliberately not
/// asserted here — the CPU model and battery cycle count depend on the
/// machine, so asserting a fixed value would only yield a flaky test.
/// What must be guaranteed is the nature of the interface: sampling
/// succeeds, the breakdown is self-consistent, and failures degrade.
struct HardwareProfileTests {
    // MARK: - Sampling

    /// Sampling must produce this machine's complete static information: the
    /// model name is not a bare identifier, both the system version and the
    /// build number have values, and memory is the physical memory.
    @Test func profileDescribesThisMachine() {
        let profile = HardwareSampler.profile()

        // hw.model is a sysctl present on every Mac; only failing to get the
        // identifier would be a problem
        #expect(!profile.modelIdentifier.isEmpty, "hw.model should be obtainable")
        #expect(!profile.modelName.isEmpty, "model name must not be empty")
        #expect(!profile.modelName.contains(" ("), "the title should only have the series name; size and year should not appear")
        #expect(!profile.osVersion.isEmpty, "kern.osproductversion should be obtainable")
        #expect(!profile.osBuild.isEmpty, "kern.osversion (build number) should be obtainable")
        #expect(!profile.cpuName.isEmpty, "CPU name must not be empty")
        #expect(!profile.gpuName.isEmpty, "GPU name must not be empty (at worst it falls back to the CPU name)")
        #expect(profile.memoryBytes > 0, "physical memory must be greater than 0")
        #expect(profile.memoryBytes == Int64(ProcessInfo.processInfo.physicalMemory),
                "memory must be the physical memory, not some other measure")
        #expect(profile.diskTotal > 0, "the startup volume's total capacity should be obtainable")
        #expect(profile.diskAvailable >= 0 && profile.diskAvailable <= profile.diskTotal,
                "available space cannot exceed the total")

        // Resolution looks like 2880x1864
        #expect(profile.displayResolution.firstMatch(of: /^\d+x\d+$/) != nil,
                "resolution format should be width x height, got: \(profile.displayResolution)")
    }

    /// Machines with a battery (laptops) must report a self-consistent battery
    /// breakdown; desktops do not have this service, so the data is left
    /// entirely empty rather than filled with 0.
    @Test func batteryDataIsSelfConsistent() {
        let profile = HardwareSampler.profile()
        guard profile.hasBattery else { return }

        #expect(profile.batteryLevel >= 0 && profile.batteryLevel <= 1, "battery level must fall within 0...1")
        #expect(profile.batteryCycles >= 0, "cycle count cannot be negative")
        #expect(profile.batteryHealth > 0 && profile.batteryHealth <= 1,
                "health is full charge capacity / design capacity, and must fall within 0...1")
        #expect(profile.batteryHealthStatus == HardwareProfile.healthStatus(profile.batteryHealth),
                "status must be derived from health")
    }

    /// On a desktop (no AppleSmartBattery service) the battery data must be
    /// empty, not something that looks normal such as "0 cycles, 0% health".
    @Test func missingBatteryLeavesDataEmpty() {
        let profile = HardwareSampler.profile()
        guard !profile.hasBattery else { return }

        #expect(profile.batteryCycles == 0)
        #expect(profile.batteryHealth == 0)
    }

    /// Sampling the same machine twice in a row must agree on the static parts
    /// (model, memory, and GPU do not change over time).
    @Test func repeatedSamplingIsStable() {
        let first = HardwareSampler.profile()
        let second = HardwareSampler.profile()

        #expect(first.modelName == second.modelName)
        #expect(first.modelIdentifier == second.modelIdentifier)
        #expect(first.memoryBytes == second.memoryBytes)
        #expect(first.cpuName == second.cpuName)
        #expect(first.cpuCores == second.cpuCores)
        #expect(first.gpuName == second.gpuName)
        #expect(first.displayResolution == second.displayResolution)
    }

    // MARK: - Derived values

    /// The marketing name keeps only the series name: the device tree gives
    /// "MacBook Air (15-inch, M2, 2023)", while the page title should be
    /// "MacBook Air".
    @Test func marketingNameDropsSizeAndYear() {
        #expect(HardwareProfile.baseName(fromProductName: "MacBook Air (15-inch, M2, 2023)") == "MacBook Air")
        #expect(HardwareProfile.baseName(fromProductName: "MacBook Pro (14-inch, M3 Pro, 2023)") == "MacBook Pro")
        // With no parentheses (or an empty string) it returns as-is; it must
        // not cut off half a name
        #expect(HardwareProfile.baseName(fromProductName: "Mac Studio") == "Mac Studio")
        #expect(HardwareProfile.baseName(fromProductName: "") == "")
    }

    /// The health threshold uses the same criterion as the system's "Battery
    /// Health": 80% is the dividing line.
    @Test func batteryHealthThresholdMatchesSystemBatteryHealth() {
        #expect(HardwareProfile.healthStatus(1) == .normal)
        #expect(HardwareProfile.healthStatus(0.87) == .normal)
        #expect(HardwareProfile.healthStatus(0.8) == .normal)
        #expect(HardwareProfile.healthStatus(0.79) == .serviceRecommended)
        #expect(HardwareProfile.healthStatus(0) == .serviceRecommended)
    }

    /// The core description must be the substituted text, with no leftover
    /// placeholder: a mismatched argument count or using the format string
    /// as a value will both show up here.
    @Test func coresDescriptionHasNoUnsubstitutedPlaceholder() {
        let cores = HardwareSampler.profile().cpuCores

        #expect(!cores.isEmpty)
        #expect(!cores.contains("%lld"), "leftover placeholder in the core description: \(cores)")
    }

    /// "Total Cores" is the label and "%lld cores" is the format string for the value: the two must be different keys.
    /// Using the wrong one prints the format string verbatim in the label position (the page shows "%lld cores 8 (4 performance + 4 efficiency)").
    @Test func coresLabelIsNotTheFormatString() {
        let label = L10n.tr("hw.cpu.coresLabel")

        #expect(!label.contains("%lld"), "the label should not carry a placeholder: \(label)")
        #expect(label != L10n.tr("hw.cpu.cores"))
        #expect(L10n.tr("hw.cpu.cores").contains("%lld"), "the value's format string must carry a placeholder")
    }

    // MARK: - Formats specific to the hardware page

    /// Memory is counted in base 1024 but the unit is written as GB: a 16 GiB
    /// machine displays 16 GB, not 17 GB — the system's "About This Mac" uses
    /// this same convention.
    @Test func memoryFormatterUsesBinaryGigabytes() {
        #expect(Formatters.memory(16 * 1024 * 1024 * 1024) == "16 GB")
        #expect(Formatters.memory(24 * 1024 * 1024 * 1024) == "24 GB")
        #expect(Formatters.memory(8 * 1024 * 1024 * 1024) == "8 GB")
        // Below 1 GiB it falls back to the regular format rather than showing "0 GB"
        #expect(Formatters.memory(512 * 1024 * 1024) == "536.9 MB")
    }

    /// Disk capacity rounds to whole GB: 494.38 GB displays 494 GB; two
    /// decimal places are just noise in an overview.
    @Test func capacityFormatterRoundsToWholeGigabytes() {
        #expect(Formatters.capacity(494_384_795_648) == "494 GB")
        #expect(Formatters.capacity(173_052_821_504) == "173 GB")
        #expect(Formatters.capacity(1_500_000_000) == "2 GB")
        // Below 1 GB it falls back to the regular format rather than showing "0 GB"
        #expect(Formatters.capacity(0) == "0 kB")
    }
}

/// Navigation for the hardware page: entering from the sidebar, entering from
/// the panel, and disk space analysis.
///
/// `@MainActor` matches `AppViewModel`: detail switching and scan start both
/// happen on the main thread.
@MainActor
struct HardwareNavigationTests {
    private func makeVM() -> AppViewModel { AppViewModel(statsPolling: false) }

    /// Entering the hardware page must also leave the settings page — the
    /// detail area shows only one page at a time.
    @Test func showHardwareLeavesSettings() {
        let vm = makeVM()
        vm.showsSettings = true

        vm.showHardware()

        #expect(vm.showsHardware)
        #expect(!vm.showsSettings)
    }

    /// Entering the hardware page must sample immediately: volume available
    /// space changes over time, so it cannot stay at the empty value from
    /// construction time.
    @Test func showHardwareSamplesProfile() {
        let vm = makeVM()
        #expect(vm.hardwareProfile.modelIdentifier.isEmpty, "there should be no data before entering the page")

        vm.showHardware()

        #expect(!vm.hardwareProfile.modelIdentifier.isEmpty)
        #expect(!vm.hardwareProfile.modelName.isEmpty)
    }

    /// "Analyze Disk Space" runs one scan pass and returns to the list page:
    /// the result of the analysis is the list itself.
    @Test func analyzeDiskSpaceStartsScanAndLeavesHardwarePage() {
        let vm = makeVM()
        vm.showHardware()
        vm.selectedCategory = .xcode

        vm.analyzeDiskSpace()

        #expect(!vm.showsHardware)
        #expect(vm.selectedCategory == nil, "returning to the list should not stay on any category")
        #expect(vm.phase == .scanning)
    }
}
