import Foundation
import CoreFoundation

struct TrafficSample: Identifiable, Equatable {
    let date: Date
    let download: Double
    let upload: Double
    var id: Date { date }
}

struct TrafficCounterReading {
    let date: Date
    let download: Int64
    let upload: Int64
}

enum TrafficCounter {
    /// Preserve missing or invalid counters as unknown; a real zero is valid.
    static func parse(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            if let count = Int64(number.stringValue) {
                return count >= 0 ? count : nil
            }
            let count = number.doubleValue
            guard count.isFinite, count >= 0, count.rounded(.towardZero) == count,
                  count < Double(Int64.max) else { return nil }
            return Int64(count)
        }
        if let text = value as? String,
           let count = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)), count >= 0 {
            return count
        }
        return nil
    }
}

enum TrafficRate {
    static func parse(_ text: String) -> Double? {
        let text = text.uppercased().replacingOccurrences(of: " ", with: "")
        guard let unitStart = text.firstIndex(where: { $0.isLetter }),
              let amount = Double(text[..<unitStart].replacingOccurrences(of: ",", with: ".")),
              amount.isFinite, amount >= 0 else { return nil }
        let unit = String(text[unitStart...]).replacingOccurrences(of: "/S", with: "")
        let units: [String: Double] = ["B": 1, "KB": 1_000, "MB": 1_000_000, "GB": 1_000_000_000,
                                        "KIB": 1_024, "MIB": 1_048_576, "GIB": 1_073_741_824]
        guard let multiplier = units[unit] else { return nil }
        return amount * multiplier
    }

    static func format(_ bytes: Double) -> String {
        let bytes = max(0, bytes)
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytes
        var index = 0
        while value >= 1_000, index < units.count - 1 {
            value /= 1_000
            index += 1
        }
        let number = index == 0 ? String(format: "%.0f", value) : String(format: value < 10 ? "%.2f" : "%.1f", value)
        return "\(number) \(units[index])"
    }
}
