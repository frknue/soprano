import Foundation
import SopranoAgentsCore

/// Number and date text of the statistics board.
enum StatisticsFormat {
    /// `$0`, `<$0.01`, `$0.09`, `$701.64`, `$12,345`.
    static func cost(_ value: Double) -> String {
        if value <= 0 { return "$0" }
        if value < 0.01 { return "<$0.01" }
        if value < 1000 { return String(format: "$%.2f", value) }
        return "$" + grouped(Int(value.rounded()))
    }

    /// `950`, `62.4k`, `5.1M`, `1.78B`.
    static func tokens(_ count: Int) -> String {
        func scaled(_ value: Double, _ suffix: String, decimals: Int) -> String {
            var text = String(format: "%.\(decimals)f", value)
            while decimals > 0, text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text + suffix
        }
        let value = Double(count)
        if count >= 1_000_000_000 { return scaled(value / 1_000_000_000, "B", decimals: 2) }
        if count >= 1_000_000 { return scaled(value / 1_000_000, "M", decimals: 1) }
        if count >= 1000 { return scaled(value / 1000, "k", decimals: 1) }
        return String(count)
    }

    /// `7,353`.
    static func count(_ value: Int) -> String {
        grouped(value)
    }

    /// `62%`, `99.8%`, `0.4%`: one decimal below 10% and above 99%, else whole percents.
    static func percent(_ fraction: Double) -> String {
        let percent = fraction * 100
        if percent > 0, percent < 10 || (percent > 99 && percent < 100) {
            let text = String(format: "%.1f", percent)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "%"
        }
        return "\(Int(percent.rounded()))%"
    }

    static func value(_ totals: UsageTotals, _ metric: UsageMetric) -> String {
        switch metric {
        case .cost: cost(totals.cost)
        case .tokens: tokens(totals.tokens)
        }
    }

    /// Axis value for the chart: `$0`, `$2.50`, `$5`, `$100`, `$1,500`; tokens compact.
    static func axisValue(_ value: Double, _ metric: UsageMetric) -> String {
        switch metric {
        case .cost:
            value >= 10 || value == value.rounded() ? "$" + grouped(Int(value.rounded())) : String(format: "$%.2f", value)
        case .tokens:
            tokens(Int(value.rounded()))
        }
    }

    /// `14:05`.
    static func time(_ date: Date) -> String {
        formatted(date, template: "Hm")
    }

    /// Axis label under a bar: `14:00`, `Oct 30`, `Oct`.
    static func axisLabel(_ date: Date, unit: UsageBucketUnit) -> String {
        switch unit {
        case .hour: formatted(date, template: "Hm")
        case .day, .week: formatted(date, template: "MMMd")
        case .month: formatted(date, template: "MMM")
        }
    }

    /// The hovered bar's title: `Oct 31, 14:00`, `Fri, Oct 30`, `Week of Oct 27`, `October 2026`.
    static func bucketTitle(_ date: Date, unit: UsageBucketUnit) -> String {
        switch unit {
        case .hour: formatted(date, template: "MMMdHm")
        case .day: formatted(date, template: "EEEMMMd")
        case .week: "Week of " + formatted(date, template: "MMMd")
        case .month: formatted(date, template: "MMMMy")
        }
    }

    /// omp's agent kinds: `main` → Main agent, `subagent` → Subagents, `advisor` → Advisor.
    static func agentTitle(_ agent: String) -> String {
        switch agent {
        case "main": "Main agent"
        case "subagent": "Subagents"
        case "advisor": "Advisor"
        default: agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func formatted(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
