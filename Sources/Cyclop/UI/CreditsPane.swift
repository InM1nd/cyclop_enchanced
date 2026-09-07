import CyclopLogic
import SwiftUI

private struct RowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct CreditsPane: View {
    @ObservedObject var usage: ClaudeUsageStore
    @ObservedObject var codex: CodexUsageStore
    @ObservedObject var cursor: CursorUsageStore
    @ObservedObject var opencode: OpenCodeUsageStore
    @ObservedObject var sessions: ProcessMonitorStore
    @ObservedObject var providers: UsageProviderSettings

    /// Cards would otherwise hug their own content — Claude's extra-usage
    /// line makes it taller than a plain two-row card — so every card is
    /// pinned to whichever one actually needs the most room, and they all
    /// end up the same size regardless of which has more lines.
    @State private var cardHeight: CGFloat?

    private var enabledProviders: [UsageProvider] { providers.enabled }

    private var columns: Int { UsageGrid.columns(for: enabledProviders.count) }

    var body: some View {
        Group {
            if enabledProviders.isEmpty {
                caption(localized("No usage cards enabled — turn some on in Settings"))
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(enabledProviders) { provider in
                        cell { content(for: provider) }
                            .frame(height: cardHeight)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(RowHeightKey.self) { cardHeight = $0 }
    }

    @ViewBuilder
    private func content(for provider: UsageProvider) -> some View {
        switch provider {
        case .claude: claudeContent
        case .codex: codexContent
        case .cursor: cursorContent
        case .opencode: opencodeContent
        }
    }

    private func cell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: RowHeightKey.self, value: proxy.size.height)
            }
        )
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Claude

    @ViewBuilder
    private var claudeContent: some View {
        brand("CLAUDE", running: sessions.claudeCount)
        if let snapshot = usage.snapshot {
            row(title: localized("5-hour window"), percent: snapshot.fiveHour.utilization, resetsAt: snapshot.fiveHour.resetsAt)
            row(title: localized("7-day window"), percent: snapshot.sevenDay.utilization, resetsAt: snapshot.sevenDay.resetsAt)
            if let extra = snapshot.extraUsage, extra.isEnabled {
                extraRow(extra)
            }
        } else if usage.noCredentials {
            caption(localized("Not signed in to Claude"))
        } else {
            caption(localized("Can't reach Claude"))
        }
    }

    private func extraRow(_ extra: ClaudeExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(localized("Extra usage"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 4)
                if let used = extra.used, let limit = extra.limit {
                    Text("\(currency(used, extra.currency)) / \(currency(limit, extra.currency))")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
            bar(extra.utilization)
        }
    }

    // MARK: - Codex

    @ViewBuilder
    private var codexContent: some View {
        brand("CODEX", running: sessions.codexCount)
        if let rateLimits = codex.snapshot {
            if let primary = rateLimits.primary {
                row(title: windowLabel(minutes: primary.windowMinutes), percent: primary.usedPercent, resetsAt: primary.resetDate)
            }
            if let secondary = rateLimits.secondary {
                row(title: windowLabel(minutes: secondary.windowMinutes), percent: secondary.usedPercent, resetsAt: secondary.resetDate)
            }
            if let credits = rateLimits.credits, credits.hasCredits, let balance = credits.balance {
                HStack(spacing: 4) {
                    Text(localized("Extra usage"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 4)
                    Text(balance)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
            if let asOf = codex.asOf {
                caption(Self.asOfLabel(for: asOf))
            }
        } else {
            caption(localized("No Codex sessions found yet"))
        }
    }

    private func windowLabel(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return localized("Usage") }
        if minutes % 1440 == 0 { return localized("%d-day window", minutes / 1440) }
        return localized("%d-hour window", max(minutes / 60, 1))
    }

    // MARK: - Cursor

    @ViewBuilder
    private var cursorContent: some View {
        brand("CURSOR", running: sessions.cursorCount)
        if let snapshot = cursor.snapshot {
            row(title: localized("Cursor Models"), percent: snapshot.cursorModelsPercent, resetsAt: snapshot.resetDate)
            row(title: localized("Other Models"), percent: snapshot.otherModelsPercent)
        } else if cursor.noCredentials {
            caption(localized("Not signed in to Cursor"))
        } else {
            caption(localized("Can't reach Cursor"))
        }
    }

    // MARK: - OpenCode

    @ViewBuilder
    private var opencodeContent: some View {
        brand("OPENCODE", running: sessions.opencodeCount)
        if let snapshot = opencode.snapshot {
            row(title: localized("5-hour window"), percent: snapshot.rollingUsage?.usagePercent, resetsAt: snapshot.rollingUsage?.resetDate)
            row(title: localized("Weekly window"), percent: snapshot.weeklyUsage?.usagePercent, resetsAt: snapshot.weeklyUsage?.resetDate)
            row(title: localized("Monthly window"), percent: snapshot.monthlyUsage?.usagePercent, resetsAt: snapshot.monthlyUsage?.resetDate)
        } else if let stats = opencode.local {
            statRow(title: localized("Today"), value: Self.breakdownSummary(stats.today))
            statRow(title: localized("This month"), value: Self.breakdownSummary(stats.month))
            if !stats.modelCosts.isEmpty {
                statRow(title: localized("Cost"), value: Self.costSummary(stats.modelCosts))
            }
            if let asOf = stats.asOf {
                caption(Self.asOfLabel(for: asOf))
            }
        } else if opencode.noCredentials {
            caption(localized("Not signed in to OpenCode"))
        } else if opencode.unreachable {
            caption(localized("Can't reach OpenCode"))
        } else {
            caption(localized("No OpenCode sessions found yet"))
        }
    }

    // MARK: - Shared row

    /// A dot for whether the CLI is running right now, and how many —
    /// separate from the quota above it, since one changes by the minute and
    /// the other by the session.
    private func brand(_ name: String, running: Int) -> some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiary)
            Circle()
                .fill(running > 0 ? Color.white.opacity(0.85) : Theme.hairline)
                .frame(width: 5, height: 5)
            if running > 0 {
                Text("\(running)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(Theme.tertiary)
    }

    private func row(title: String, percent value: Double?, resetsAt: Date? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 4)
                Text(percent(value))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color(for: value))
            }
            bar(value)
            if let resetsAt {
                Text(Self.resetLabel(for: resetsAt))
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func bar(_ utilization: Double?) -> some View {
        let fraction = min(max((utilization ?? 0) / 100, 0), 1)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule()
                    .fill(color(for: utilization))
                    .frame(width: max(proxy.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 4)
    }

    private func percent(_ utilization: Double?) -> String {
        guard let utilization else { return "—" }
        return "\(Int(utilization.rounded()))%"
    }

    private func currency(_ value: Double, _ code: String?) -> String {
        String(format: "%.2f %@", value, code ?? "")
    }

    /// A plain label/value line without a bar — the OpenCode card's local
    /// mirror has no limit to fill a bar against, so raw numbers it is.
    private func statRow(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// 5,567,993 → "5.6M", 1,234 → "1.2K" — tokens, which are otherwise
    /// digits nobody can scan.
    private static func compact(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    /// "203K in · 20K out · 24K rea · 6.8M cache" — the same split `opencode
    /// stats` prints, minus the components the window has nothing of.
    private static func breakdownSummary(_ breakdown: OpenCodeTokenBreakdown) -> String {
        var parts: [String] = []
        if let value = breakdown.input, value > 0 { parts.append("\(compact(value)) in") }
        if let value = breakdown.output, value > 0 { parts.append("\(compact(value)) out") }
        if let value = breakdown.reasoning, value > 0 { parts.append("\(compact(value)) rea") }
        if let value = breakdown.cacheRead, value > 0 { parts.append("\(compact(value)) cache") }
        if let value = breakdown.cacheWrite, value > 0 { parts.append("\(compact(value)) cw") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// "big-pickle $0.00 · haiku-4-5 $0.00" — one line per model, most
    /// expensive first, truncated if the tail runs long.
    private static func costSummary(_ costs: [(model: String, cost: Double)]) -> String {
        costs.map { "\($0.model) $\(String(format: "%.2f", $0.cost))" }
            .joined(separator: " · ")
    }

    /// White past halfway, amber once it starts to matter, red once there is
    /// barely anything left — the same three-stop read as a phone's battery
    /// icon, chosen because nobody has to learn it.
    private func color(for utilization: Double?) -> Color {
        guard let utilization else { return Theme.tertiary }
        if utilization >= 90 { return .red }
        if utilization >= 70 { return .yellow }
        return .white.opacity(0.85)
    }

    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .abbreviated
        formatter.calendar?.locale = Locale(identifier: appLanguage)
        return formatter
    }()

    private static func resetLabel(for date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0, let span = elapsedFormatter.string(from: interval) else {
            return localized("resets any moment")
        }
        return localized("resets in %@", span)
    }

    private static func asOfLabel(for date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        guard interval > 60, let span = elapsedFormatter.string(from: interval) else {
            return localized("as of just now")
        }
        return localized("as of %@ ago", span)
    }
}
