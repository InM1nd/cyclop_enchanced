import SwiftUI

private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct CreditsPane: View {
    @ObservedObject var usage: ClaudeUsageStore
    @ObservedObject var codex: CodexUsageStore
    @ObservedObject var cursor: CursorUsageStore
    @ObservedObject var providers: UsageProviderSettings

    /// Claude's extra-usage line makes it taller than the others; every card
    /// is pinned to that height so the row is even.
    @State private var cardHeight: CGFloat?

    private var enabledProviders: [UsageProvider] { providers.enabled }
    private var columns: Int { UsageGrid.columns(for: enabledProviders.count) }

    var body: some View {
        Group {
            if enabledProviders.isEmpty {
                caption(localized("No usage cards enabled — turn some on in Settings"))
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: UsageGrid.rowSpacing), count: columns),
                    alignment: .leading,
                    spacing: UsageGrid.rowSpacing
                ) {
                    ForEach(enabledProviders) { provider in
                        cell { content(for: provider) }
                            .frame(height: cardHeight)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(CardHeightKey.self) { if $0 > 0 { cardHeight = $0 } }
        .onChange(of: enabledProviders.count) { _, _ in cardHeight = nil }
        .onAppear {
            usage.reload()
            cursor.reload()
            codex.reload()
        }
    }

    @ViewBuilder
    private func content(for provider: UsageProvider) -> some View {
        switch provider {
        case .claude: claudeContent
        case .codex: codexContent
        case .cursor: cursorContent
        }
    }

    private func cell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CardHeightKey.self, value: proxy.size.height)
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
        brand("CLAUDE")
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
        brand("CODEX")
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
        brand("CURSOR")
        if let snapshot = cursor.snapshot {
            row(title: localized("Cursor Models"), percent: snapshot.cursorModelsPercent, resetsAt: snapshot.resetDate)
            row(title: localized("Other Models"), percent: snapshot.otherModelsPercent)
        } else if cursor.noCredentials {
            caption(localized("Not signed in to Cursor"))
        } else {
            caption(localized("Can't reach Cursor"))
        }
    }

    // MARK: - Shared row

    private func brand(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.tertiary)
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
