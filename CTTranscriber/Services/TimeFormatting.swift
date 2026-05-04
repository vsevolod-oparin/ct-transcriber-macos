import Foundation

enum TimeFormatting {
    static func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let fraction = seconds - Double(totalSeconds)
        let tenths = Int(fraction * 10)

        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60

        if h > 0 {
            return String(format: "%d:%02d:%02d.%d", h, m, s, tenths)
        } else if m > 0 {
            return String(format: "%d:%02d.%d", m, s, tenths)
        } else {
            return String(format: "%d.%d", s, tenths)
        }
    }

    static func parseTimestamp(_ str: String) -> TimeInterval? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":")
        if parts.count == 2 {
            guard let min = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
            return min * 60 + sec
        } else if parts.count == 1 {
            return Double(trimmed)
        }
        return nil
    }
}
