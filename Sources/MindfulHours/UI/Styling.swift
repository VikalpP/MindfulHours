import SwiftUI
import MindfulHoursCore

extension ActivityCategory {
    var color: Color {
        switch self {
        case .coding: .blue
        case .writing: .indigo
        case .communication: .teal
        case .meeting: .orange
        case .research: .purple
        case .design: .pink
        case .planning: .mint
        case .admin: .brown
        case .learning: .green
        case .entertainment: .red
        case .other: .gray
        }
    }
}

enum TimeText {
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func range(_ start: Date, _ end: Date) -> String {
        "\(clock(start)) – \(clock(end))"
    }
}

struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: AppIcons.icon(for: bundleID))
            .resizable()
            .frame(width: size, height: size)
    }
}

struct CategoryBar: View {
    let usage: [CategoryUsage]

    var body: some View {
        let total = max(usage.reduce(0) { $0 + $1.seconds }, 1)
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(usage) { entry in
                    Rectangle()
                        .fill(entry.category.color)
                        .frame(width: max(2, proxy.size.width * entry.seconds / total))
                        .help("\(entry.category.label): \(Timeline.formatDuration(entry.seconds))")
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }
}

struct UsageRow: View {
    let bundleID: String
    let name: String
    let seconds: TimeInterval
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(bundleID: bundleID, size: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(name).lineLimit(1)
                    Spacer()
                    Text(Timeline.formatCompactDuration(seconds)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.callout)
                GeometryReader { proxy in
                    Capsule().fill(.tint.opacity(0.7)).frame(width: max(2, proxy.size.width * fraction))
                }
                .frame(height: 3)
            }
        }
    }
}
