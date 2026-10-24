import Charts
import PilothouseKit
import SwiftUI

/// "This week" at the top of the session list: time worked, top project, limits.
struct ThisWeekCard: View {
    let connection: MacConnection
    let open: () -> Void
    @State private var summary: WeeklySummary?
    @State private var limits: [UsageLimits] = []

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This week")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let summary {
                        Text(verbatim: InsightFormat.duration(summary.totalActiveSeconds))
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                        if let top = summary.projects.first {
                            Text("Mostly \(top.name)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("No sessions yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    ForEach(limits.filter { !$0.windows.isEmpty }.prefix(3)) { item in
                        LimitRing(limits: item)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("thisWeekCard")
        .task(id: connection.isConnected) {
            guard connection.isConnected else { return }
            async let summary = try? connection.weeklySummary()
            async let limits = try? connection.usageLimits()
            self.summary = await summary
            self.limits = await limits ?? []
        }
    }
}

/// The fullest window of an agent as a small ring with the agent's symbol.
struct LimitRing: View {
    let limits: UsageLimits

    private var window: LimitWindow? { limits.windows.max { $0.usedPercent < $1.usedPercent } }

    var body: some View {
        let used = (window?.usedPercent ?? 0) / 100
        ZStack {
            Circle().stroke(Design.insetBackground, lineWidth: 4)
            Circle()
                .trim(from: 0, to: used)
                .stroke(InsightFormat.color(for: window?.usedPercent ?? 0, agent: limits.agent), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: limits.agent.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(limits.agent.tint)
        }
        .frame(width: 34, height: 34)
        .accessibilityElement()
        .accessibilityLabel(Text("\(limits.agent.displayName): \(Int((window?.usedPercent ?? 0).rounded())) percent used"))
    }
}

/// Weekly summary and usage limits from the Mac.
struct InsightsView: View {
    enum Tab: Hashable { case summary, limits }

    let connection: MacConnection
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .summary
    @State private var week = Date()
    @State private var summary: WeeklySummary?
    @State private var limits: [UsageLimits] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(selection: $tab) {
                        Text("Summary").tag(Tab.summary)
                        Text("Limits").tag(Tab.limits)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("insightsTabs")

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    switch tab {
                    case .summary: summarySection
                    case .limits: limitsSection
                    }
                }
                .padding()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Text("Insights"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await load(refresh: true) }
            .task(id: week) { await load(refresh: false) }
        }
    }

    // MARK: Summary

    @ViewBuilder private var summarySection: some View {
        HStack {
            Button {
                week = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: week) ?? week
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel(Text("Previous week"))
            Spacer()
            Text(verbatim: weekTitle)
                .font(.headline)
            Spacer()
            Button {
                week = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: week) ?? week
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(isCurrentWeek)
            .accessibilityLabel(Text("Next week"))
        }
        .buttonStyle(.bordered)

        if let summary {
            HStack(spacing: 12) {
                MetricTile(title: "Active time", value: InsightFormat.duration(summary.totalActiveSeconds), symbol: "clock")
                MetricTile(title: "Sessions", value: "\(summary.sessionCount)", symbol: "bubble.left.and.bubble.right")
                MetricTile(
                    title: "Files changed",
                    value: "\(summary.projects.reduce(0) { $0 + $1.filesChanged })",
                    symbol: "doc.badge.plus"
                )
            }
            .fixedSize(horizontal: false, vertical: true)
            Chart(summary.days) { day in
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Hours", Double(day.activeSeconds) / 3_600)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .frame(height: 140)
            .padding()
            .cardBackground()

            narrativeCard(summary)

            ForEach(summary.projects) { project in
                ProjectCard(project: project)
            }
            if summary.projects.isEmpty {
                ContentUnavailableView {
                    Label("No work this week", systemImage: "calendar")
                } description: {
                    Text("Sessions you run from this phone or the Mac show up here.")
                }
            }
        } else if isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Your Mac is summarising the week…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    @ViewBuilder private func narrativeCard(_ summary: WeeklySummary) -> some View {
        if let narrative = summary.narrative {
            VStack(alignment: .leading, spacing: 8) {
                Label("Summary", systemImage: "apple.intelligence")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: narrative.headline)
                    .font(.headline)
                ForEach(narrative.highlights, id: \.self) { line in
                    Label {
                        Text(verbatim: line)
                    } icon: {
                        Image(systemName: "sparkle").foregroundStyle(Color.accentColor)
                    }
                    .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .cardBackground()
            .accessibilityIdentifier("weeklyNarrative")
        } else if let reason = summary.narrativeUnavailableReason {
            Label(reason, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
        }
    }

    // MARK: Limits

    @ViewBuilder private var limitsSection: some View {
        ForEach(limits) { item in
            AgentLimitsCard(limits: item)
        }
        if limits.isEmpty && !isLoading {
            ContentUnavailableView {
                Label("No limits yet", systemImage: "gauge.with.dots.needle.33percent")
            } description: {
                Text("Limits appear after an agent has run on your Mac.")
            }
        }
        Text("Claude reports its limits with every turn, so they are as fresh as the last answer. Codex limits are read from your Mac when you open this screen. Gemini does not report limits.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: Loading

    private var isCurrentWeek: Bool {
        Calendar.current.isDate(week, equalTo: Date(), toGranularity: .weekOfYear)
    }

    private var weekTitle: String {
        guard let interval = Calendar.current.dateInterval(of: .weekOfYear, for: week) else { return "" }
        let end = interval.end.addingTimeInterval(-1)
        return "\(interval.start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private func load(refresh: Bool) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        if !refresh { summary = nil }
        do {
            async let summary = connection.weeklySummary(week: week, refresh: refresh)
            async let limits = connection.usageLimits()
            self.summary = try await summary
            self.limits = try await limits
        } catch {
            self.error = (error as? ErrorPayload)?.message ?? error.localizedDescription
        }
    }
}

struct MetricTile: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .cardBackground(cornerRadius: Design.controlRadius)
    }
}

struct ProjectCard: View {
    let project: ProjectActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(verbatim: project.name).font(.headline)
                } icon: {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text(verbatim: InsightFormat.duration(project.activeSeconds))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                ForEach(project.agents.keys.sorted(), id: \.self) { key in
                    let agent = AgentKind(key)
                    Chip(text: Text(verbatim: "\(agent.displayName) · \(project.agents[key] ?? 0)"), tint: agent.tint, symbol: agent.symbol)
                }
            }
            HStack(spacing: 14) {
                Label(String(project.sessionCount), systemImage: "bubble.left.and.bubble.right")
                Label(String(project.filesChanged), systemImage: "doc")
                Text(verbatim: "+\(project.linesAdded)").foregroundStyle(.green)
                Text(verbatim: "−\(project.linesRemoved)").foregroundStyle(.red)
                Label(String(project.commandsRun), systemImage: "terminal")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            let lines = project.highlights.isEmpty ? Array(project.sessionTitles.prefix(4)) : project.highlights
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Label {
                        Text(verbatim: line).font(.subheadline)
                    } icon: {
                        Image(systemName: project.highlights.isEmpty ? "text.bubble" : "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .cardBackground()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project-\(project.name)")
    }
}

struct AgentLimitsCard: View {
    let limits: UsageLimits

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentAvatar(agent: limits.agent, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: limits.agent.displayName).font(.headline)
                    if let plan = limits.plan {
                        Text(verbatim: plan.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let observed = limits.observedAt {
                    Text(observed, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if limits.windows.isEmpty {
                Group {
                    if limits.source == .unavailable {
                        Text("This CLI does not report usage limits.")
                    } else {
                        Text("No limits reported yet. Run a session to see them.")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            ForEach(limits.windows) { window in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(verbatim: InsightFormat.windowName(window))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(verbatim: "\(Int(window.usedPercent.rounded()))%")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(InsightFormat.color(for: window.usedPercent, agent: limits.agent))
                    }
                    ProgressView(value: min(1, window.usedPercent / 100))
                        .tint(InsightFormat.color(for: window.usedPercent, agent: limits.agent))
                    if let resetsAt = window.resetsAt {
                        Text("Resets \(resetsAt, format: .relative(presentation: .named)) · \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(window.isLimited ? .red : .secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
        .cardBackground()
        .accessibilityIdentifier("limits-\(limits.agent.rawValue)")
    }
}

enum InsightFormat {
    static func duration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, zeroValueUnits: .hide))
            .ifEmpty(Duration.seconds(0).formatted(.units(allowed: [.minutes], width: .abbreviated)))
    }

    static func windowName(_ window: LimitWindow) -> String {
        let base: String = switch window.durationMinutes {
        case 300?: String(localized: "5 hours")
        case 10_080?: String(localized: "Weekly")
        case let minutes? where minutes % 1_440 == 0: String(localized: "\(minutes / 1_440) days")
        case let minutes? where minutes % 60 == 0: String(localized: "\(minutes / 60) hours")
        default: window.key
        }
        return window.model.map { "\(base) · \($0)" } ?? base
    }

    static func color(for usedPercent: Double, agent: AgentKind) -> Color {
        if usedPercent >= 90 { return .red }
        if usedPercent >= 70 { return .orange }
        return agent.tint
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
