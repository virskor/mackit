import Foundation
import Testing

@testable import Mackit

/// Tests for the SMC temperature reader.
///
/// The real IOKit path cannot run in a test — and is dead on macOS 27 anyway
/// — so the selection, decoding and filtering logic is driven through the
/// injected key reader, and the real reader's guards are pinned by what it
/// must return on a machine that answers nothing.
struct SMCTemperatureTests {
    /// A key reader over a fixed table: every key the table does not name
    /// fails, as the kext would refuse it.
    private func reader(_ values: [String: SMCTemperature.KeyValue]) -> SMCTemperature.KeyReader {
        { key in values[key] }
    }

    private func sp78(_ bytes: [UInt8]) -> SMCTemperature.KeyValue {
        (2, SMCTemperature.fourcc("sp78"), bytes)
    }

    /// The type the Apple Silicon sensor keys actually answer with (verified
    /// on an M2): a 4-byte native little-endian float. The bits are the
    /// *float* pattern — the double pattern's low bytes are not it.
    private func flt(_ value: Double) -> SMCTemperature.KeyValue {
        let bits = Float(value).bitPattern
        let bytes = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
                     UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
        return (4, SMCTemperature.fourcc("flt "), bytes)
    }

    // MARK: - Fixed-point decoding

    /// sp78 is a signed 16-bit value with 8 fractional bits, big-endian.
    @Test func sp78DecodesSignedSixteenBitFixedPoint() {
        #expect(SMCTemperature.decode(sp78([0x40, 0x00])) == 64)   // 16384 / 256
        #expect(SMCTemperature.decode(sp78([0x1E, 0x00])) == 30)   // 7680 / 256
        #expect(SMCTemperature.decode(sp78([0x19, 0x00])) == 25)
        // Negative is a real sp78 value, not a wrap-around
        #expect(SMCTemperature.decode(sp78([0xFF, 0x00])) == -1)
    }

    /// The other sp variants scale by their fractional-bit count, which the
    /// type's last hex digit carries.
    @Test func spVariantsScaleByTheirFractionBits() {
        #expect(SMCTemperature.decode((2, SMCTemperature.fourcc("sp96"), [0x40, 0x00])) == 256) // /64
        #expect(SMCTemperature.decode((2, SMCTemperature.fourcc("sp5a"), [0x40, 0x00])) == 16) // /1024
        #expect(SMCTemperature.decode((2, SMCTemperature.fourcc("sp87"), [0x40, 0x00])) == 128) // /128
    }

    /// The Apple Silicon sensor keys answer as `flt ` — a 3-character code
    /// padded with a space, native little-endian. Matching the unpadded
    /// "flt" drops every float reading, which is what the M-series tables
    /// return.
    @Test func floatTypeDecodesLittleEndianWithPaddedFourcc() {
        // 25.0 is 0x41C80000; the kext stores it little-endian.
        #expect(SMCTemperature.decode((4, SMCTemperature.fourcc("flt "), [0x00, 0x00, 0xC8, 0x41])) == 25)
        // The M2 reading the probe saw: Tp09 ≈ 85.6°C (a Float32 value, so
        // compared with the suite's tolerance pattern).
        let reading = SMCTemperature.decode((4, SMCTemperature.fourcc("flt "), [89, 69, 171, 66]))
        #expect(reading != nil)
        #expect(abs((reading ?? 0) - 85.6) / 85.6 < 0.001)
        // A padded code must not match a different type that merely starts
        // with the same letters.
        #expect(SMCTemperature.decode((4, SMCTemperature.fourcc("fpXX"), [0x00, 0x00, 0xC8, 0x41])) == nil)
    }

    @Test func integerTypesDecode() {
        #expect(SMCTemperature.decode((2, SMCTemperature.fourcc("ui16"), [0x00, 0x2A])) == 42)
        #expect(SMCTemperature.decode((2, SMCTemperature.fourcc("si16"), [0xFF, 0xD6])) == -42)
        // An unknown type decodes to nothing rather than to a guess
        #expect(SMCTemperature.decode((4, SMCTemperature.fourcc("fpe2"), [0x32, 0x35, 0x2E, 0x30])) == nil)
    }

    @Test func fourccRoundTrips() {
        #expect(SMCTemperature.fourccString(SMCTemperature.fourcc("Tp09")) == "Tp09")
        #expect(SMCTemperature.fourccString(SMCTemperature.fourcc("sp78")) == "sp78")
        #expect(SMCTemperature.fourcc("TC0P") == 0x54433050)
    }

    // MARK: - Intel selection

    /// The first sensor with a plausible value wins, in the declared order:
    /// proximity, then diode, then the rest.
    @Test func intelTakesTheFirstPlausibleSensor() {
        let temperature = SMCTemperature.cpuTemperature(
            isAppleSilicon: false,
            brand: "Intel Core i7",
            readKey: reader([
                "TC0P": sp78([0x2D, 0x00]), // 45°C
                "TC0D": sp78([0x34, 0x00]), // 52°C — never reached
            ])
        )
        #expect(temperature == 45)
    }

    /// A key that answers 0 or a wild value carries no usable signal: the
    /// next key is tried, exactly as the index-cycling read does.
    @Test func intelSkipsImplausibleReadings() {
        #expect(
            SMCTemperature.cpuTemperature(
                isAppleSilicon: false,
                brand: "Intel Core i7",
                readKey: reader([
                    "TC0P": sp78([0x00, 0x00]), // 0°C: absent sensor
                    "TC0D": sp78([0x34, 0x00]), // 52°C
                ])
            ) == 52
        )
        #expect(
            SMCTemperature.cpuTemperature(
                isAppleSilicon: false,
                brand: "Intel Core i7",
                readKey: reader([
                    "TC0P": sp78([0x6E, 0x00]), // 110°C: at the filter's edge
                    "TC0D": sp78([0x34, 0x00]),
                ])
            ) == 110
        )
        #expect(
            SMCTemperature.cpuTemperature(
                isAppleSilicon: false,
                brand: "Intel Core i7",
                readKey: reader([
                    "TC0P": sp78([0x80, 0x00]), // 128°C: sensor error
                    "TC0D": sp78([0x34, 0x00]),
                ])
            ) == 52
        )
    }

    /// A key the kext refuses reads as nil and moves the walk on.
    @Test func intelSkipsRefusedKeys() {
        let temperature = SMCTemperature.cpuTemperature(
            isAppleSilicon: false,
            brand: "Intel Core i7",
            readKey: { key in
                key == "TC0F" ? sp78([0x28, 0x00]) : nil // only the fifth key answers
            }
        )
        #expect(temperature == 40)
    }

    @Test func intelWithNoPlausibleSensorReadsNothing() {
        let temperature = SMCTemperature.cpuTemperature(
            isAppleSilicon: false,
            brand: "Intel Core i7",
            readKey: reader(["TC0P": sp78([0x00, 0x00]), "TC0D": sp78([0xFF, 0x00])])
        )
        #expect(temperature == nil)
    }

    // MARK: - Apple Silicon selection

    /// Every family has its own table: the brand string picks it, and the
    /// Pro / Max / Ultra variants of a family share one table.
    @Test func siliconFamilyTablesComeFromTheBrand() {
        // Only the base M1's keys answer
        let baseM1 = SMCTemperature.cpuTemperature(
            isAppleSilicon: true,
            brand: "Apple M1",
            readKey: reader(["Tc0a": flt(40)])
        )
        #expect(baseM1 == 40)

        // The same key answers nothing for an M1 Pro, which uses the M1 table
        let m1Pro = SMCTemperature.cpuTemperature(
            isAppleSilicon: true,
            brand: "Apple M1 Pro",
            readKey: reader(["Tc0a": flt(40), "Tp09": flt(50)])
        )
        #expect(m1Pro == 50)

        let m2Max = SMCTemperature.cpuTemperature(
            isAppleSilicon: true,
            brand: "Apple M2 Max",
            readKey: reader(["Tp1h": flt(50)])
        )
        #expect(m2Max == 50)

        let m5 = SMCTemperature.cpuTemperature(
            isAppleSilicon: true,
            brand: "Apple M5",
            readKey: reader(["Tp00": flt(40)])
        )
        #expect(m5 == 40)
    }

    /// A chip newer than this build has no table: it reads nothing rather
    /// than guessing at keys that may mean something else on it.
    @Test func unknownSiliconFamilyReadsNothing() {
        let temperature = SMCTemperature.cpuTemperature(
            isAppleSilicon: true,
            brand: "Apple M9 Ultra",
            readKey: reader(["Tp09": flt(40)])
        )
        #expect(temperature == nil)

        let unreadable = SMCTemperature.cpuTemperature(
            isAppleSilicon: true,
            brand: "",
            readKey: reader(["Tp09": flt(40)])
        )
        #expect(unreadable == nil)
    }

    /// The value is the average of every sensor in range, the GPU sensors
    /// included.
    @Test func siliconAveragesTheSensorsInRange() {
        let temperature = SMCTemperature.cpuTemperature(
            isAppleSilicon: true,
            brand: "Apple M2",
            readKey: reader([
                "Tp1h": flt(30),
                "Tp1t": flt(50),
            ])
        )
        #expect(temperature == 40)
    }

    /// An unpopulated slot reads near zero and would drag the average down;
    /// so does a sensor error. Both are dropped.
    @Test func siliconDropsOutOfRangeSensors() {
        let temperature = SMCTemperature.cpuTemperature(
            isAppleSilicon: true,
            brand: "Apple M2",
            readKey: reader([
                "Tp1h": flt(0),   // absent slot
                "Tp1t": flt(10),  // below the floor
                "Tp1p": flt(128), // sensor error
                "Tp1l": flt(40),
            ])
        )
        #expect(temperature == 40)
    }

    @Test func siliconWithNoSensorInRangeReadsNothing() {
        let temperature = SMCTemperature.cpuTemperature(
            isAppleSilicon: true,
            brand: "Apple M2",
            readKey: reader(["Tp1h": flt(0), "Tp1t": flt(128)])
        )
        #expect(temperature == nil)
    }
}

/// The display side: the formatting and the fallback the menu surfaces share.
struct TemperatureDisplayTests {
    /// Whole degrees with the unit attached — the status-bar format. A
    /// fractional reading would change width with every sample.
    @Test func degreesTruncatesAndCarriesTheUnit() {
        #expect(Formatters.degrees(45.7) == "45°C")
        #expect(Formatters.degrees(25) == "25°C")
        #expect(Formatters.degrees(100) == "100°C")
        #expect(Formatters.degrees(0.4) == "0°C")
    }

    /// A numeric reading shows as degrees; without one the row keeps the
    /// public thermal-state word — on macOS 27 every SMC read is rejected,
    /// and the word is the signal that always works.
    @Test func temperatureTextFallsBackToTheThermalWord() {
        var stats = SystemStats()
        stats.thermalState = 0 // nominal
        stats.cpuTemperature = 45.7
        #expect(stats.temperatureText == "45°C")
        #expect(!stats.temperatureIsHot)

        stats.cpuTemperature = 70
        #expect(stats.temperatureText == "70°C")
        #expect(stats.temperatureIsHot)

        stats.cpuTemperature = nil
        #expect(stats.temperatureText == L10n.tr("menubar.thermal.nominal"))
        #expect(!stats.temperatureIsHot, "a thermal state is not a temperature")
    }
}
