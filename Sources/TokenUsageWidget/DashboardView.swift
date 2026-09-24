import SwiftUI

@MainActor
final class UsageModel: ObservableObject {
    @Published var snapshot: UsageSnapshot
    @Published var isRefreshing = false
    @Published var hasLoaded = false
    // Compact is the default size; the expanded layout adds the detail rows.
    @Published var isCompact = true

    private let collector: UsageCollector
    private let claudeUsageClient: ClaudeUsageClient
    private let deepSeekBalanceClient: DeepSeekBalanceClient
    private var refreshTimer: Timer?

    init(
        collector: UsageCollector = UsageCollector(),
        claudeUsageClient: ClaudeUsageClient = ClaudeUsageClient(),
        deepSeekBalanceClient: DeepSeekBalanceClient = DeepSeekBalanceClient()
    ) {
        self.collector = collector
        self.claudeUsageClient = claudeUsageClient
        self.deepSeekBalanceClient = deepSeekBalanceClient
        self.snapshot = UsageSnapshot(
            claudeToday: 0,
            claudeMonth: 0,
            codexToday: 0,
            codexMonth: 0,
            deepSeekToday: 0,
            deepSeekMonth: 0,
            deepSeekMonthCostUSD: 0,
            codexPlan: nil,
            claudePlan: nil,
            claudePlanWarning: nil,
            deepSeekBalance: nil,
            deepSeekBalanceWarning: nil,
            refreshedAt: Date(),
            warnings: []
        )
    }

    func start() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let collector = collector
        let claudeClient = claudeUsageClient
        let balanceClient = deepSeekBalanceClient

        Task { [weak self] in
            let localTask = Task.detached(priority: .utility) {
                collector.collect()
            }
            async let fetchedClaudePlan = claudeClient.fetch()
            async let fetchedBalance = balanceClient.fetch()

            var result = await localTask.value
            let claudeResult = await fetchedClaudePlan
            let balanceResult = await fetchedBalance
            result.claudePlan = claudeResult.plan
            result.claudePlanWarning = claudeResult.warning
            result.deepSeekBalance = balanceResult.balance
            result.deepSeekBalanceWarning = balanceResult.warning
            self?.snapshot = result
            self?.hasLoaded = true
            self?.isRefreshing = false
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: UsageModel
    let onClose: () -> Void
    let onQuit: () -> Void
    let onToggleSize: () -> Void

    // The two panel sizes AppMain resizes between. Kept here so the layout and
    // the window agree on one number each.
    static let compactSize = CGSize(width: 300, height: 134)
    static let expandedSize = CGSize(width: 438, height: 384)

    private let claudeColor = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let codexColor = Color.white
    private let deepSeekColor = Color(red: 0.30, green: 0.42, blue: 0.98)

    var body: some View {
        Group {
            if model.isCompact {
                compactBody
            } else {
                expandedBody
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: model.isCompact ? 14 : 18, style: .continuous))
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            compactHeader
            VStack(alignment: .leading, spacing: 7) {
                bars(compact: true)
            }
            Spacer(minLength: 0)
            footer(compact: true)
        }
        .padding(12)
        .frame(width: Self.compactSize.width, height: Self.compactSize.height, alignment: .topLeading)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 10) {
                Text("PERCENTAGE USED")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)

                bars(compact: false)
            }

            Divider().opacity(0.55)

            VStack(alignment: .leading, spacing: 11) {
                Text("DETAIL")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)

                if model.hasLoaded {
                    ClaudeUsageRow(snapshot: model.snapshot, color: claudeColor)
                    CodexUsageRow(snapshot: model.snapshot, color: codexColor)
                    DeepSeekUsageRow(snapshot: model.snapshot, color: deepSeekColor)
                } else {
                    Text("Reading local usage and live plan utilization…")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                }
            }

            footer(compact: false)
        }
        .padding(18)
        .frame(width: Self.expandedSize.width, height: Self.expandedSize.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func bars(compact: Bool) -> some View {
        UsageBar(
            label: "Claude",
            percentUsed: model.hasLoaded ? model.snapshot.claudePercentUsed : nil,
            windowTag: windowTag(model.snapshot.claudePlan),
            color: claudeColor,
            compact: compact
        )
        .accessibilityLabel("Claude percentage used")
        .accessibilityValue(model.hasLoaded ? TokenFormatter.percent(model.snapshot.claudePercentUsed) : "Loading")

        UsageBar(
            label: "Codex",
            percentUsed: model.hasLoaded ? model.snapshot.codexPercentUsed : nil,
            windowTag: windowTag(model.snapshot.codexPlan),
            color: codexColor,
            compact: compact
        )
        .accessibilityLabel("Codex percentage used")
        .accessibilityValue(model.hasLoaded ? TokenFormatter.percent(model.snapshot.codexPercentUsed) : "Loading")

        UsageBar(
            label: "DeepSeek",
            percentUsed: model.hasLoaded ? model.snapshot.deepSeekPercentUsed : nil,
            windowTag: model.snapshot.deepSeekPercentUsed == nil ? nil : "bal",
            color: deepSeekColor,
            compact: compact
        )
        .accessibilityLabel("DeepSeek percentage used")
        .accessibilityValue(model.hasLoaded ? TokenFormatter.percent(model.snapshot.deepSeekPercentUsed) : "Loading")
    }

    // Which rolling window the headline bar reflects.
    private func windowTag(_ plan: PlanUsage?) -> String? {
        guard let plan, let headline = plan.headline else { return nil }
        if let session = plan.session, headline == session, plan.weekly != nil { return "5h" }
        if plan.weekly != nil, plan.session != nil { return "wk" }
        guard let minutes = headline.windowMinutes else { return nil }
        return minutes >= 1_440 ? "wk" : "5h"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Token Meter")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("Claude · Codex · DeepSeek")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HeaderButton(
                systemName: "arrow.down.right.and.arrow.up.left",
                help: "Shrink widget",
                action: onToggleSize
            )

            HeaderButton(
                systemName: "arrow.clockwise",
                help: "Refresh usage",
                isSpinning: model.isRefreshing,
                action: model.refresh
            )
            .disabled(model.isRefreshing)

            HeaderButton(systemName: "xmark", help: "Hide widget", action: onClose)
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Token Meter")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))

            Spacer(minLength: 4)

            HeaderButton(
                systemName: "arrow.up.left.and.arrow.down.right",
                help: "Show detail",
                size: 20,
                action: onToggleSize
            )

            HeaderButton(
                systemName: "arrow.clockwise",
                help: "Refresh usage",
                isSpinning: model.isRefreshing,
                size: 20,
                action: model.refresh
            )
            .disabled(model.isRefreshing)

            HeaderButton(systemName: "xmark", help: "Hide widget", size: 20, action: onClose)
        }
    }

    private func footer(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            Circle()
                .fill(firstWarning == nil ? deepSeekColor : .orange)
                .frame(width: 6, height: 6)
            Text(footerText(compact: compact))
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button("Quit", action: onQuit)
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
    }

    // The compact layout drops the detail rows, so a plan/balance warning that
    // would otherwise only show there has to surface in the footer.
    private var firstWarning: String? {
        model.snapshot.warnings.first
            ?? model.snapshot.claudePlanWarning
            ?? model.snapshot.deepSeekBalanceWarning
    }

    private func footerText(compact: Bool) -> String {
        if !model.hasLoaded { return "Refreshing usage…" }
        if let warning = firstWarning {
            return warning
        }
        let time = model.snapshot.refreshedAt.formatted(date: .omitted, time: .shortened)
        return compact ? "Refreshed \(time)" : "Live plan usage · refreshed \(time)"
    }
}

private struct HeaderButton: View {
    let systemName: String
    let help: String
    var isSpinning = false
    var size: CGFloat = 26
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .semibold))
                .rotationEffect(isSpinning ? .degrees(360) : .zero)
                .animation(
                    isSpinning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                    value: isSpinning
                )
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .fill(.primary.opacity(isHovering ? 0.12 : 0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct UsageBar: View {
    let label: String
    let percentUsed: Double?
    let windowTag: String?
    let color: Color
    var compact = false

    private var fraction: Double {
        min(1, max(0, (percentUsed ?? 0) / 100))
    }

    private var fillColor: Color {
        guard let percentUsed else { return color }
        if percentUsed >= 90 { return .red }
        if percentUsed >= 75 { return .orange }
        return color
    }

    var body: some View {
        HStack(spacing: compact ? 7 : 10) {
            Text(label)
                .font(.system(size: compact ? 10.5 : 12, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .frame(width: compact ? 52 : 62, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.08))
                        .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 1))
                    Capsule()
                        .fill(fillColor.gradient)
                        .frame(width: max(fraction > 0 ? 4 : 0, proxy.size.width * fraction))
                        .shadow(color: .black.opacity(fillColor == .white ? 0.18 : 0), radius: 1)
                }
            }
            .frame(height: compact ? 9 : 12)

            Text(TokenFormatter.percent(percentUsed))
                .font(.system(size: compact ? 10.5 : 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(fillColor)
                .frame(width: compact ? 40 : 44, alignment: .trailing)

            Text(windowTag ?? "")
                .font(.system(size: compact ? 8 : 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: compact ? 14 : 16, alignment: .leading)
        }
    }
}

private struct StatusTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(color)
    }
}

private func windowSummary(_ plan: PlanUsage) -> String {
    var parts: [String] = []
    if let session = plan.session {
        parts.append("5h \(TokenFormatter.percent(session.usedPercent))")
    }
    if let weekly = plan.weekly {
        var text = "wk \(TokenFormatter.percent(weekly.usedPercent))"
        if let resetsAt = weekly.resetsAt {
            text += " (resets \(resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())))"
        }
        parts.append(text)
    }
    return parts.joined(separator: " · ")
}

private struct ClaudeUsageRow: View {
    let snapshot: UsageSnapshot
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Claude · subscription plan")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                Spacer()
                StatusTag(
                    text: snapshot.claudePlan == nil ? "OFFLINE" : "LIVE",
                    color: snapshot.claudePlan == nil ? .orange : color
                )
            }

            Text(detail)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var detail: String {
        let tokens = "\(TokenFormatter.compact(snapshot.claudeMonth)) tokens this month"
        guard let plan = snapshot.claudePlan else {
            return "\(snapshot.claudePlanWarning ?? "Plan usage unavailable") · \(tokens)"
        }
        return "\(windowSummary(plan)) · \(tokens)"
    }
}

private struct CodexUsageRow: View {
    let snapshot: UsageSnapshot
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Codex · plan windows")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                Spacer()
                StatusTag(text: freshness, color: snapshot.codexPlan == nil ? .orange : color)
            }

            Text(detail)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // Codex quota comes from its local session log, so it is only as fresh
    // as the last Codex run.
    private var freshness: String {
        guard let observedAt = snapshot.codexPlan?.observedAt else { return "NO DATA" }
        let age = snapshot.refreshedAt.timeIntervalSince(observedAt)
        if age < 30 * 60 { return "LIVE" }
        if age < 48 * 3_600 {
            return "SEEN " + observedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()).uppercased()
        }
        return "STALE"
    }

    private var detail: String {
        let tokens = "\(TokenFormatter.compact(snapshot.codexMonth)) tokens this month"
        guard let plan = snapshot.codexPlan else {
            return "Run Codex once to record its quota · \(tokens)"
        }
        return "\(windowSummary(plan)) · \(tokens)"
    }
}

private struct DeepSeekUsageRow: View {
    let snapshot: UsageSnapshot
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("DeepSeek · live API balance")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                Spacer()
                StatusTag(
                    text: snapshot.deepSeekBalance == nil ? "OFFLINE" : "LIVE",
                    color: snapshot.deepSeekBalance == nil ? .orange : color
                )
            }

            Text(detail)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var detail: String {
        guard let balance = snapshot.deepSeekBalance else {
            return snapshot.deepSeekBalanceWarning ?? "Balance unavailable"
        }
        let balanceText = TokenFormatter.currency(balance.total, code: balance.currency)
        let costText = TokenFormatter.currency(snapshot.deepSeekMonthCostUSD, code: "USD")
        return "\(balanceText) left · \(costText) spent this month · \(TokenFormatter.compact(snapshot.deepSeekMonth)) tokens"
    }
}
