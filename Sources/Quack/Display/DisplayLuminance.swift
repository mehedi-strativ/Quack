import Foundation
import IOKit

/// Reads a display's rated maximum luminance (nits) from the framebuffer's
/// `DisplayAttributes` in the IORegistry (Apple Silicon: `IOMobileFramebufferShim`
/// nodes carry the EDID/DisplayID HDR metadata, including
/// `Luminance.Max` as a 16.16 fixed-point value).
enum DisplayLuminance {

    /// Max luminance in nits for the display whose EDID product name matches
    /// `name` (the same string `NSScreen.localizedName` reports), or nil when
    /// the display doesn't advertise one.
    static func maxNits(forProductName name: String) -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOMobileFramebufferShim"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard
                let attrs = IORegistryEntryCreateCFProperty(
                    service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? [String: Any],
                let product = attrs["ProductAttributes"] as? [String: Any],
                let productName = product["ProductName"] as? String,
                productName == name,
                let nits = maxNits(fromAttributes: attrs)
            else { continue }
            return nits
        }
        return nil
    }

    /// Extracts `Luminance.Max` (16.16 fixed point → nits) from a
    /// `DisplayAttributes` dictionary.
    static func maxNits(fromAttributes attrs: [String: Any]) -> Double? {
        guard
            let luminance = attrs["Luminance"] as? [String: Any],
            let rawMax = (luminance["Max"] as? NSNumber)?.doubleValue,
            rawMax > 0
        else { return nil }
        return rawMax / 65536.0
    }
}
