import SwiftUI
import MindfulHoursCore

/// The day sideways: a row of task blocks over one lane per app, so switching between apps is visible at a glance.
struct AppLanesView: View {
    let hours: DateInterval
    let blocks: [ActivityBlock]
    let lanes: [AppLane]

    private let labelWidth: CGFloat = 104
    private let rowHeight: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            row(label: Text("Tasks").font(.caption.bold())) { width in
                ForEach(blocks) { block in
                    bar(from: block.start, to: block.end, width: width)
                        .fill(block.category.color.gradient)
                        .help("\(block.task) · \(TimeText.range(block.start, block.end)) · \(Timeline.formatDuration(block.duration))")
                }
            }
            ForEach(lanes) { lane in
                row(label: laneLabel(lane)) { width in
                    ForEach(lane.segments, id: \.start) { segment in
                        bar(from: segment.start, to: segment.end, width: width)
                            .fill(lane.isOther ? AnyShapeStyle(.gray.opacity(0.6)) : AnyShapeStyle(.tint.opacity(0.75)))
                            .help(tooltip(lane, segment))
                    }
                }
            }
            hourAxis
        }
    }

    private func laneLabel(_ lane: AppLane) -> some View {
        HStack(spacing: 5) {
            if lane.isOther {
                Image(systemName: "square.grid.2x2").frame(width: 14)
            } else {
                AppIconView(bundleID: lane.bundleID, size: 14)
            }
            Text(lane.appName).lineLimit(1)
        }
        .font(.caption)
        .help("\(lane.appName): \(Timeline.formatDuration(lane.seconds))")
    }

    private func row<Label: View, Bars: View>(label: Label, @ViewBuilder bars: @escaping (CGFloat) -> Bars) -> some View {
        HStack(spacing: 8) {
            label.frame(width: labelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.35))
                    bars(proxy.size.width)
                }
            }
            .frame(height: rowHeight)
        }
    }

    private func bar(from start: Date, to end: Date, width: CGFloat) -> some Shape {
        let x = position(of: start, in: width)
        let barWidth = max(2, position(of: end, in: width) - x)
        return RoundedRectangle(cornerRadius: 3).path(in: CGRect(x: x, y: 0, width: barWidth, height: rowHeight))
    }

    private func position(of date: Date, in width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(hours.start) / hours.duration) * width
    }

    private var hourAxis: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: labelWidth, height: 1)
            GeometryReader { proxy in
                let hourCount = max(1, Int((hours.duration / 3600).rounded()))
                let step = max(1, Int((CGFloat(hourCount) * 44 / max(proxy.size.width, 1)).rounded(.up)))
                ForEach(Array(stride(from: 0, through: hourCount, by: step)), id: \.self) { hour in
                    let date = hours.start.addingTimeInterval(Double(hour) * 3600)
                    Text(date.formatted(.dateTime.hour()))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: position(of: date, in: proxy.size.width), y: 6)
                }
            }
            .frame(height: 12)
        }
    }

    private func tooltip(_ lane: AppLane, _ segment: LaneSegment) -> String {
        let title = segment.title.map { " · \($0)" } ?? ""
        return "\(lane.appName)\(title) · \(TimeText.range(segment.start, segment.end)) · \(Timeline.formatCompactDuration(segment.duration))"
    }
}
