/// Formats byte counts in decimal units (1 GB = 1,000,000,000 bytes), the same
/// units Finder and System Settings use, so numbers match what users see there.
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        let digits = value >= 100 ? 0 : 1
        return String(format: "%.\(digits)f %@", value, units[unit])
    }
}
