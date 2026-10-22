import SwiftUI
import MindfulHoursCore

struct TimelineView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: ActivityRecorder
    @State private var day = Date.now
    @State private var activity: DayActivity?
    @State private var isSummarizing = false
    @State private var summaryError: String?

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let activity {
                        summaryCard(activity)
                        if activity.blocks.isEmpty {
                            ContentUnavailableView("Nothing recorded", systemImage: "clock", description: Text("Activity shows up here minute by minute."))
                                .padding(.top, 60)
                        } else {
                            ForEach(activity.blocks.reversed()) { BlockRow(block: $0) }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            if let activity { sidebar(activity) }
        }
        .toolbar { toolbar }
        .navigationTitle(day.formatted(date: .complete, time: .omitted))
        .task(id: TimelineReloadKey(day: Timeline.dayKey(for: day), revision: isToday ? recorder.dataRevision : 0)) {
            activity = await model.activity(for: day)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { shiftDay(by: -1) } label: { Image(systemName: "chevron.left") }
            Button("Today") { day = .now }.disabled(isToday)
            Button { shiftDay(by: 1) } label: { Image(systemName: "chevron.right") }.disabled(isToday)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                guard let activity else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Timeline.markdown(day: activity.dayKey, blocks: activity.blocks, summary: activity.summary), forType: .string)
            } label: { Label("Copy Markdown", systemImage: "doc.on.doc") }
                .help("Copy this day as Markdown")
            Button { summarize() } label: { Label("Summarize Day", systemImage: "sparkles") }
                .disabled(isSummarizing || (activity?.blocks.isEmpty ?? true))
        }
    }

    @ViewBuilder private func summaryCard(_ activity: DayActivity) -> some View {
        if isSummarizing {
            ProgressView("Writing your day summary…").frame(maxWidth: .infinity, alignment: .leading)
        } else if let summaryError {
            Label(summaryError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
        } else if let summary = activity.summary {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.renderedWithoutLinks(summary.text))
                    .textSelection(.enabled)
                Text("Generated \(summary.createdAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func sidebar(_ activity: DayActivity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active time").font(.caption).foregroundStyle(.secondary)
                    Text(Timeline.formatDuration(activity.activeSeconds)).font(.system(size: 30, weight: .semibold, design: .rounded))
                }
                if !activity.categoryUsage.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Categories").font(.headline)
                        CategoryBar(usage: activity.categoryUsage)
                        ForEach(activity.categoryUsage) { usage in
                            HStack {
                                Circle().fill(usage.category.color).frame(width: 8, height: 8)
                                Text(usage.category.label)
                                Spacer()
                                Text(Timeline.formatDuration(usage.seconds)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
                if !activity.appUsage.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Apps").font(.headline)
                        let longest = activity.appUsage.first?.seconds ?? 1
                        ForEach(activity.appUsage.prefix(15)) { usage in
                            UsageRow(bundleID: usage.bundleID, name: usage.appName, seconds: usage.seconds, fraction: usage.seconds / longest)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 280)
    }

    /// Model output can echo window titles or page text, so links in it are never made clickable.
    private static func renderedWithoutLinks(_ markdown: String) -> AttributedString {
        guard var rendered = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(markdown)
        }
        for run in rendered.runs where run.link != nil {
            rendered[run.range].link = nil
        }
        return rendered
    }

    private func shiftDay(by days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
        summaryError = nil
    }

    private func summarize() {
        guard let activity else { return }
        isSummarizing = true
        summaryError = nil
        Task {
            defer { isSummarizing = false }
            do {
                self.activity?.summary = try await model.summarize(activity)
            } catch {
                summaryError = error.localizedDescription
            }
        }
    }
}

private struct TimelineReloadKey: Hashable {
    let day: String
    let revision: Int
}

private struct BlockRow: View {
    let block: ActivityBlock
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(TimeText.clock(block.start)).font(.callout.monospacedDigit())
                Text(Timeline.formatDuration(block.duration)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 72, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2).fill(block.category.color).frame(width: 4)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(block.task).font(.headline)
                    if let project = block.project {
                        Text(project).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(block.category.label).font(.caption).foregroundStyle(block.category.color)
                }
                let visibleSummaries = isExpanded ? block.summaries : Array(block.summaries.prefix(3))
                ForEach(visibleSummaries, id: \.self) { summary in
                    Text(summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if block.summaries.count > 3 {
                    Button(isExpanded ? "Show less" : "+\(block.summaries.count - 3) more") { isExpanded.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
                Text(block.apps.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
